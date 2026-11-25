//! The TV guide (EPG): XMLTV import, channel matching, and the queries every screen uses (now/next in lists, the
//! guide grid's window, programme details, programme search).
//!
//! - Parser: streaming over a `BufRead` (quick-xml), gzip and xz detected by their magic bytes; a 300 MB guide never
//!   sits in memory. Times are XMLTV's `YYYYMMDDhhmmss ±hhmm`, stored as UTC seconds; the profile's EPG offset is
//!   added for providers that send local time as UTC. Malformed programmes are counted and skipped.
//! - Import: one transaction per source (the provider's built-in guide, then each extra XMLTV URL); a source replaces
//!   its own rows, and a channel that already has programmes from an earlier source keeps them. Only the window
//!   (`days_back` … `days_ahead`) is stored; older rows are pruned.
//! - Matching (rebuilt after every import and sync): the user's manual mapping (`epg_map`) wins, then the item's EPG id
//!   exactly, then case-insensitively, then the normalised channel name (cleaned of prefixes and quality tags,
//!   lower-case, letters and digits only) against every XMLTV display name.
//!
//! Debug hints: `select count(*) from item_epg` = matched channels; `select * from epg_sources` shows each source's
//! last import, counts and error; a channel shows "No guide" when it has no row in item_epg.

use crate::db::clean_name;
use quick_xml::events::Event;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};

pub type Result<T> = rusqlite::Result<T>;

/// One XMLTV channel.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct XmlChannel {
    pub id: String,
    pub names: Vec<String>,
    pub icon: String,
}

/// One XMLTV programme.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct XmlProgramme {
    pub channel: String,
    pub start: i64,
    pub stop: i64,
    pub title: String,
    pub sub_title: String,
    pub desc: String,
    pub category: String,
    pub episode: String,
    pub icon: String,
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ParseStats {
    pub channels: usize,
    pub programmes: usize,
    pub skipped: usize,
}

/// `20251121170000 +0100` (or without seconds / offset) → UTC seconds.
pub fn parse_time(s: &str) -> Option<i64> {
    let s = s.trim();
    let (dt, off) = s
        .split_once(' ')
        .map(|(a, b)| (a, b.trim()))
        .unwrap_or((s, ""));
    if dt.len() < 12 || !dt[..12].bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n = |a: usize, b: usize| dt[a..b].parse::<i64>().ok();
    let (y, mo, d, h, mi) = (n(0, 4)?, n(4, 6)?, n(6, 8)?, n(8, 10)?, n(10, 12)?);
    let sec = if dt.len() >= 14 { n(12, 14)? } else { 0 };
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    // days_from_civil (Howard Hinnant), no date crate needed.
    let (y2, m2) = if mo <= 2 {
        (y - 1, mo + 9)
    } else {
        (y, mo - 3)
    };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * m2 + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let local = days * 86_400 + h * 3600 + mi * 60 + sec;
    let offset = if off.len() == 5 && (off.starts_with('+') || off.starts_with('-')) {
        let sign = if off.starts_with('-') { -1 } else { 1 };
        let hh: i64 = off[1..3].parse().ok()?;
        let mm: i64 = off[3..5].parse().ok()?;
        sign * (hh * 3600 + mm * 60)
    } else {
        0
    };
    Some(local - offset)
}

/// Wraps a reader in a gzip or xz decoder when it starts with their magic bytes.
pub fn maybe_unpack<'a>(mut r: impl BufRead + 'a) -> std::io::Result<Box<dyn BufRead + 'a>> {
    let magic = r.fill_buf()?;
    if magic.starts_with(&[0x1f, 0x8b]) {
        return Ok(Box::new(BufReader::new(flate2::bufread::GzDecoder::new(r))));
    }
    if magic.starts_with(b"\xfd7zXZ\0") {
        // Rytec's files. The limit caps the dictionary a (broken or hostile) file can ask for; xz's own presets need
        // at most 64 MB.
        let xz = lzma_rust2::XzReader::new_mem_limit(r, true, 65 * 1024);
        return Ok(Box::new(BufReader::new(xz)));
    }
    Ok(Box::new(r))
}

/// Streams an XMLTV document, calling back per channel and per programme.
pub fn parse(
    input: impl BufRead,
    mut on_channel: impl FnMut(XmlChannel),
    mut on_programme: impl FnMut(XmlProgramme),
) -> std::result::Result<ParseStats, quick_xml::Error> {
    let mut reader = quick_xml::Reader::from_reader(input);
    // No trim_text: quick-xml splits text at entity references, and trimming each piece would turn
    // "Tagesschau &amp; Wetter" into "Tagesschau&Wetter". The finished field is trimmed instead.
    let mut buf = Vec::new();
    let mut stats = ParseStats::default();
    let mut channel: Option<XmlChannel> = None;
    let mut prog: Option<(XmlProgramme, bool)> = None; // (programme, start/stop valid)
    let mut field: Option<&'static str> = None; // the text element being read
    let mut text = String::new();
    let attr = |e: &quick_xml::events::BytesStart, name: &str| -> String {
        e.attributes()
            .flatten()
            .find(|a| a.key.as_ref() == name)
            .and_then(|a| {
                a.normalized_value(quick_xml::XmlVersion::Implicit1_0)
                    .ok()
                    .map(|v| v.into_owned())
            })
            .unwrap_or_default()
    };
    loop {
        match reader.read_event_into(&mut buf)? {
            Event::Start(e) | Event::Empty(e) if e.name().as_ref() == "channel" => {
                channel = Some(XmlChannel {
                    id: attr(&e, "id"),
                    ..Default::default()
                });
            }
            Event::Start(e) | Event::Empty(e) if e.name().as_ref() == "programme" => {
                let start = parse_time(&attr(&e, "start"));
                let stop = parse_time(&attr(&e, "stop"));
                let ok = start.is_some();
                let start = start.unwrap_or(0);
                prog = Some((
                    XmlProgramme {
                        channel: attr(&e, "channel"),
                        start,
                        // A missing stop: half an hour (the grid needs an end; most guides always send one).
                        stop: stop.filter(|&s| s > start).unwrap_or(start + 1800),
                        ..Default::default()
                    },
                    ok,
                ));
            }
            Event::Empty(e) | Event::Start(e) if e.name().as_ref() == "icon" => {
                let src = attr(&e, "src");
                if let Some((p, _)) = &mut prog {
                    p.icon = src;
                } else if let Some(c) = &mut channel {
                    c.icon = src;
                }
            }
            Event::Start(e) => {
                field = match e.name().as_ref() {
                    "display-name" if channel.is_some() => Some("name"),
                    "title" if prog.is_some() => Some("title"),
                    "sub-title" if prog.is_some() => Some("sub"),
                    "desc" if prog.is_some() => Some("desc"),
                    "category" if prog.is_some() => Some("cat"),
                    "episode-num" if prog.is_some() => Some("ep"),
                    _ => None,
                };
                text.clear();
            }
            Event::Text(t) if field.is_some() => text.push_str(&t.xml10_content()),
            Event::CData(t) if field.is_some() => text.push_str(&t.xml10_content()),
            Event::GeneralRef(r) if field.is_some() => {
                // quick-xml hands entity references over separately: &amp; &#228; …
                if let Ok(Some(c)) = r.resolve_char_ref() {
                    text.push(c);
                } else if let Some(s) = quick_xml::escape::resolve_predefined_entity(&r) {
                    text.push_str(s);
                }
            }
            Event::End(e) => match e.name().as_ref() {
                "channel" => {
                    if let Some(c) = channel.take().filter(|c| !c.id.is_empty()) {
                        stats.channels += 1;
                        on_channel(c);
                    }
                }
                "programme" => match prog.take() {
                    Some((p, true)) if !p.channel.is_empty() && !p.title.is_empty() => {
                        stats.programmes += 1;
                        on_programme(p);
                    }
                    Some(_) => stats.skipped += 1,
                    None => {}
                },
                _ => {
                    let t = std::mem::take(&mut text).trim().to_string();
                    match (field.take(), &mut channel, &mut prog) {
                        (Some("name"), Some(c), _) => c.names.push(t),
                        (Some("title"), _, Some((p, _))) if p.title.is_empty() => p.title = t,
                        (Some("sub"), _, Some((p, _))) => p.sub_title = t,
                        (Some("desc"), _, Some((p, _))) if p.desc.is_empty() => p.desc = t,
                        (Some("cat"), _, Some((p, _))) if p.category.is_empty() => p.category = t,
                        (Some("ep"), _, Some((p, _))) if p.episode.is_empty() => p.episode = t,
                        _ => {}
                    }
                }
            },
            Event::Eof => break,
            _ => {}
        }
        buf.clear();
    }
    Ok(stats)
}

/// Country codes providers and guide files put on channel names (the ones seen in both; "TV" or "FM" must stay out).
/// LAM, ARB: regions some providers use like a country.
const COUNTRIES: &[&str] = &[
    "AE", "AL", "AM", "AR", "ARB", "AT", "AU", "AZ", "BA", "BE", "BG", "BH", "BO", "BR", "CA",
    "CH", "CL", "CN", "CO", "CY", "CZ", "DE", "DK", "DZ", "EC", "EE", "EG", "ES", "FI", "FR", "GB",
    "GR", "HR", "HU", "IE", "IL", "IN", "IQ", "IR", "IS", "IT", "JO", "JP", "KW", "LAM", "LB",
    "LT", "LU", "LV", "LY", "MA", "ME", "MK", "MT", "MX", "MY", "NL", "NO", "NZ", "PE", "PL", "PT",
    "QA", "RO", "RS", "RU", "SA", "SE", "SI", "SK", "SY", "TN", "TR", "UA", "UK", "US", "UY", "VE",
    "XK", "YE", "ZA",
];

/// A known country code (any case), in one spelling per country.
fn code(s: &str) -> Option<String> {
    let c = s.trim().to_ascii_uppercase();
    COUNTRIES.contains(&c.as_str()).then(|| match c.as_str() {
        "GB" => "UK".into(),
        "BH" => "BA".into(), // a community file's code for Bosnia and Herzegovina
        _ => c,
    })
}

/// Splits a channel name into what is left without its country code, and the code: "AT - Name", "[DE] Name",
/// "DE: Name", "|DE| Name", "Name (RS)", "Name FHD DE". Codes are upper case, so "Nova it" keeps its last word.
fn split_country(name: &str) -> (&str, Option<String>) {
    let upper = |c: &str| {
        if c.chars().any(|ch| ch.is_lowercase()) {
            None
        } else {
            code(c)
        }
    };
    let s = name.trim().trim_start_matches(['|', '[']).trim();
    if let Some((head, rest)) = s
        .split_once(['|', ':', ']'])
        .or_else(|| s.split_once(" - "))
        && let Some(c) = upper(head)
        && !rest.trim().is_empty()
    {
        return (rest.trim(), Some(c));
    }
    if let Some((rest, tail)) = name.trim().rsplit_once(char::is_whitespace)
        && let Some(c) = upper(tail.trim_matches(['(', ')', '[', ']']))
    {
        return (rest.trim(), Some(c));
    }
    (name, None)
}

/// The country a channel name says it is from.
pub fn country(name: &str) -> Option<String> {
    split_country(name).1
}

/// The country of a community guide file, from its URL (epgshare01, free-epg); None for any other.
pub fn source_country(url: &str) -> Option<String> {
    let file = url.rsplit('/').next()?.split('.').next()?;
    if let Some(f) = file.strip_prefix("epg_ripper_") {
        // beIN's file is its Middle East line-up.
        return if f.starts_with("BEIN") {
            Some("QA".into())
        } else {
            code(f.get(..2)?)
        };
    }
    url.contains("free-epg.de/api/epg/")
        .then(|| code(file))
        .flatten()
}

/// The matching key of a channel name: without its country code and quality tags, lower-case, accents folded, letters
/// and digits only. A plus is spelled out: "3+" isn't "3", and "+1" is another schedule.
pub fn norm(name: &str) -> String {
    let bein = bein_name(name);
    let name = bein.as_deref().unwrap_or(name);
    let plus = clean_name(split_country(name).0).replace('+', "plus");
    crate::db::fold(&plus)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// beIN's community file names its channels after logo files: "beIN_SPORTS1_DIGITAL_Mono_EN" is beIN SPORTS 1,
/// "NEW_beIN-SPORTS-MAX-05_AR" MAX 5. None for every other name.
fn bein_name(name: &str) -> Option<String> {
    let low = name.to_ascii_lowercase();
    let base = low
        .strip_suffix("_en")
        .or_else(|| low.strip_suffix("_ar"))?;
    if !(base.contains("bein") && base.contains("sports")) {
        return None;
    }
    let base = base.split("_digital_mono").next()?.replace("bein.com", "");
    let words = base
        .split(['_', '-', ' '])
        .filter(|w| !["", "new", "logos", "digital"].contains(w))
        // "05" is 5.
        .map(|w| w.trim_start_matches('0'));
    Some(words.collect())
}

/// How well a guide channel's country fits an item's, best first; None: a different country, no match. Austria,
/// Switzerland and Germany share channels; a side that names no country fits any.
fn fit(item: Option<&str>, guide: Option<&str>) -> Option<u8> {
    const DACH: [&str; 3] = ["DE", "AT", "CH"];
    match (item, guide) {
        (Some(a), Some(b)) if a == b => Some(0),
        (Some(a), Some(b)) if DACH.contains(&a) && DACH.contains(&b) => Some(1),
        (Some(_), Some(_)) => None,
        (None, _) => Some(0), // any country: the sources' order decides
        (Some(_), None) => Some(2),
    }
}

/// SQL for a source's rank (`col` holds a source id): the provider's guide first, then extra sources in the order
/// they were added (owner decision: when sources overlap, the provider's data wins). A source without a row (tests)
/// ranks by its id after every listed one.
fn rank(col: &str) -> String {
    format!(
        "coalesce((SELECT (1 - builtin) * 1000000000 + id FROM epg_sources WHERE id = {col}), 2000000000 + {col})"
    )
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ImportStats {
    pub channels: usize,
    pub programmes: usize,
    pub skipped: usize,
    /// Programmes left out: outside the window, for a channel an earlier source already covers, or for a channel no
    /// item can take.
    pub outside: usize,
}

/// What the profile's live items can take: their guide ids and manual mappings (lower case), and the countries per
/// name key. A channel [takes] refuses can never match ([match_open]).
struct Wanted {
    ids: std::collections::HashSet<String>,
    names: HashMap<String, Vec<Option<String>>>,
}

impl Wanted {
    fn load(conn: &Connection) -> Result<Wanted> {
        let mut st = conn.prepare("SELECT epg_id, name FROM items WHERE kind = 0")?;
        let mut w = Wanted {
            ids: Default::default(),
            names: HashMap::new(),
        };
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let (id, name): (String, String) = (r.get(0)?, r.get(1)?);
            w.ids.insert(id.to_lowercase());
            w.names.entry(norm(&name)).or_default().push(country(&name));
        }
        let mut st = conn.prepare("SELECT channel FROM epg_map")?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            w.ids.insert(r.get::<_, String>(0)?.to_lowercase());
        }
        Ok(w)
    }

    fn takes(&self, c: &XmlChannel, file: Option<&str>) -> bool {
        if self.names.is_empty() || self.ids.contains(&c.id.to_lowercase()) {
            return true;
        }
        let from = channel_country(&c.id, c.names.first().map_or(&c.id, |n| n), file);
        c.names
            .iter()
            .filter_map(|n| self.names.get(&norm(n)))
            .flatten()
            .any(|own| fit(own.as_deref(), from.as_deref()).is_some())
    }
}

/// A guide channel's country: its name's, its id's ending ("Name.de"), or its file's.
fn channel_country(id: &str, name: &str, file: Option<&str>) -> Option<String> {
    country(name)
        .or_else(|| id.rsplit_once('.').and_then(|(_, c)| code(c)))
        .or_else(|| file.map(str::to_string))
}

/// Imports one source's XMLTV into the guide tables (one transaction; the source's old rows are replaced).
/// `now`: UTC seconds; the window is now − `days_back` … now + `days_ahead`; `offset_secs` corrects provider times.
pub fn import(
    conn: &mut Connection,
    source: i64,
    input: impl Read,
    now: i64,
    days_back: i64,
    days_ahead: i64,
    offset_secs: i64,
) -> std::io::Result<ImportStats> {
    let io = std::io::Error::other;
    let input = maybe_unpack(BufReader::new(input))?;
    let tx = conn.transaction().map_err(io)?;
    tx.execute(
        "DELETE FROM programmes_fts WHERE rowid IN (SELECT id FROM programmes WHERE source = ?1)",
        [source],
    )
    .map_err(io)?;
    tx.execute("DELETE FROM programmes WHERE source = ?1", [source])
        .map_err(io)?;
    tx.execute(
        "DELETE FROM epg_names WHERE channel IN (SELECT id FROM epg_channels WHERE source = ?1)",
        [source],
    )
    .map_err(io)?;
    tx.execute("DELETE FROM epg_channels WHERE source = ?1", [source])
        .map_err(io)?;
    // Channels a higher-ranked source already fills (a schedule that has ended doesn't count): this source must not add a second schedule for them. (A
    // lower-ranked source's schedule for a channel this one fills is removed after the import, below.)
    // Channels where it only has ended programmes keep those, so this source adds just what is still to come.
    let covered = |after: i64| -> rusqlite::Result<std::collections::HashSet<String>> {
        let mut st = tx.prepare(&format!(
            "SELECT DISTINCT channel FROM programmes WHERE stop > ?2 AND {} < {}",
            rank("source"),
            rank("?1")
        ))?;
        st.query_map([source, after], |r| r.get(0))?.collect()
    };
    let (taken, ended) = (covered(now).map_err(io)?, covered(0).map_err(io)?);
    // Programmes are stored only for channels an item can take (owner decision): with dozens of community files most
    // channels are nobody's. Without any live item (no sync yet) everything is kept.
    let wanted = Wanted::load(&tx).map_err(io)?;
    let url = tx
        .query_row("SELECT url FROM epg_sources WHERE id = ?1", [source], |r| {
            r.get::<_, String>(0)
        })
        .optional()
        .map_err(io)?
        .unwrap_or_default();
    let file = source_country(&url);
    // free-epg numbers some countries' channels ("9121"): as they are, they could hit a provider's numeric guide id.
    let numbered = url.contains("free-epg.de/").then(|| file.clone()).flatten();
    let own_id = |id: String| match &numbered {
        Some(cc) if id.bytes().all(|b| b.is_ascii_digit()) => format!("{}:{id}", cc.to_lowercase()),
        _ => id,
    };
    // The channels no item can take. A programme whose channel the file hasn't listed yet is kept.
    let unwanted = std::cell::RefCell::new(std::collections::HashSet::<String>::new());
    let (from, to) = (now - days_back * 86_400, now + days_ahead * 86_400);
    // Both callbacks below record into these (RefCell: two closures can't both borrow them mutably).
    let stats = std::cell::RefCell::new(ImportStats::default());
    let failed: std::cell::RefCell<Option<rusqlite::Error>> = std::cell::RefCell::new(None);
    {
        // A channel id another source has too belongs to the higher-ranked source (a shared display name names both
        // channels; rebuild_matches picks).
        let mut ch = tx
            .prepare(&format!(
                "INSERT INTO epg_channels (id, name, icon, source) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (id) DO UPDATE SET name = ?2, icon = ?3, source = ?4
                 WHERE {} < {}",
                rank("?4"),
                rank("epg_channels.source")
            ))
            .map_err(io)?;
        let mut nm = tx
            .prepare("INSERT OR IGNORE INTO epg_names (norm, channel) VALUES (?1, ?2)")
            .map_err(io)?;
        let mut pr = tx
            .prepare(
                "INSERT INTO programmes (channel, start, stop, title, sub_title, descr, category, episode, icon, source)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )
            .map_err(io)?;
        let mut fts = tx
            .prepare("INSERT INTO programmes_fts (rowid, title, sub_title, descr) VALUES (?1, ?2, ?3, ?4)")
            .map_err(io)?;
        let parsed = parse(
            input,
            |mut c| {
                c.id = own_id(c.id);
                if failed.borrow().is_some() {
                    return;
                }
                let name = c.names.first().cloned().unwrap_or_else(|| c.id.clone());
                if !wanted.takes(&c, file.as_deref()) {
                    unwanted.borrow_mut().insert(c.id.clone());
                }
                let r = (|| -> rusqlite::Result<()> {
                    if ch.execute(params![c.id, name, c.icon, source])? > 0 {
                        stats.borrow_mut().channels += 1;
                    }
                    // Also for an id a higher-ranked source has: this one may be the source with the schedule.
                    for n in &c.names {
                        let k = norm(n);
                        if !k.is_empty() {
                            nm.execute(params![k, c.id])?;
                        }
                    }
                    Ok(())
                })();
                if let Err(e) = r {
                    *failed.borrow_mut() = Some(e);
                }
            },
            |mut p| {
                p.channel = own_id(p.channel);
                if failed.borrow().is_some() {
                    return;
                }
                p.start += offset_secs;
                p.stop += offset_secs;
                if p.stop <= from
                    || p.start >= to
                    || taken.contains(&p.channel)
                    || unwanted.borrow().contains(&p.channel)
                    || (p.stop <= now && ended.contains(&p.channel))
                {
                    stats.borrow_mut().outside += 1;
                    return;
                }
                let r = (|| -> rusqlite::Result<()> {
                    pr.execute(params![
                        p.channel,
                        p.start,
                        p.stop,
                        p.title,
                        p.sub_title,
                        p.desc,
                        p.category,
                        p.episode,
                        p.icon,
                        source
                    ])?;
                    fts.execute(params![
                        tx.last_insert_rowid(),
                        p.title,
                        p.sub_title,
                        p.desc
                    ])?;
                    Ok(())
                })();
                match r {
                    Ok(()) => stats.borrow_mut().programmes += 1,
                    Err(e) => *failed.borrow_mut() = Some(e),
                }
            },
        )
        .map_err(std::io::Error::other)?; // the XML error type differs from io()'s rusqlite one
        stats.borrow_mut().skipped = parsed.skipped;
    }
    if let Some(e) = failed.into_inner() {
        return Err(io(e)); // rolled back: the previous guide stays
    }
    // Lower-ranked sources' schedules for the channels this one now fills go (they come back if this one drops them).
    let lower = format!(
        "SELECT id FROM programmes WHERE {} > {} AND channel IN
           (SELECT DISTINCT channel FROM programmes WHERE source = ?1 AND stop > {now})",
        rank("source"),
        rank("?1")
    );
    tx.execute(
        &format!("DELETE FROM programmes_fts WHERE rowid IN ({lower})"),
        [source],
    )
    .map_err(io)?;
    tx.execute(
        &format!("DELETE FROM programmes WHERE id IN ({lower})"),
        [source],
    )
    .map_err(io)?;
    tx.commit().map_err(io)?;
    Ok(stats.into_inner())
}

/// Removes programmes that ended before the window (call after imports and once a day).
pub fn prune(conn: &Connection, now: i64, days_back: i64) -> Result<usize> {
    let before = now - days_back * 86_400;
    conn.execute(
        "DELETE FROM programmes_fts WHERE rowid IN (SELECT id FROM programmes WHERE stop < ?1)",
        [before],
    )?;
    conn.execute("DELETE FROM programmes WHERE stop < ?1", [before])
}

/// Rebuilds which guide channel each live item shows, in this order: the manual mapping; the item's guide id, exactly
/// and ignoring case; its normalised name against every display name; and finally a "twin" (an item of the same
/// normalised name, e.g. "ZDF FHD" next to a matched "DE: ZDF HD"). Only guide channels that have programmes count
/// for the automatic steps, so a provider guide that lists a channel without programmes doesn't hide an extra source
/// that has them (where both have programmes, the import gave the channel and its names to the provider).
/// Returns the number of matched items. Debugging: `SELECT * FROM item_epg WHERE item_key = …` shows the result.
pub fn rebuild_matches(conn: &mut Connection, now: i64) -> Result<usize> {
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM item_epg", [])?;
    tx.execute(
        "INSERT OR IGNORE INTO item_epg (item_key, channel) SELECT item_key, channel FROM epg_map",
        [],
    )?;
    // First the channels with something still to come; then, for what is left, any schedule (a guide that couldn't be
    // refreshed for days still serves catch-up).
    for after in [now, 0] {
        match_open(&tx, after)?;
    }
    let n = tx.query_row("SELECT count(*) FROM item_epg", [], |r| r.get::<_, i64>(0))? as usize;
    tx.commit()?;
    Ok(n)
}

/// One matching pass over the items without a match, against the guide channels with a programme ending after `after`.
fn match_open(tx: &rusqlite::Transaction, after: i64) -> Result<()> {
    let filled =
        format!("EXISTS (SELECT 1 FROM programmes p WHERE p.channel = c.id AND p.stop > {after})");
    for id in ["c.id = i.epg_id", "lower(c.id) = lower(i.epg_id)"] {
        tx.execute(
            &format!(
                "INSERT OR IGNORE INTO item_epg (item_key, channel)
                 SELECT i.key, c.id FROM items i JOIN epg_channels c ON {id}
                 WHERE i.kind = 0 AND i.epg_id != '' AND {filled}"
            ),
            [],
        )?;
    }
    // Names: done in Rust (norm() isn't SQL). Per name every channel that has it, in the sources' order, with its
    // country (its name's, its id's ending as in "Name.de", or its file's) and whether it is the provider's.
    let mut names: HashMap<String, Vec<(String, Option<String>, bool)>> = HashMap::new();
    {
        let mut st = tx.prepare(&format!(
            "SELECT n.norm, n.channel, c.name, coalesce(s.url, ''), coalesce(s.builtin, 0)
             FROM epg_names n JOIN epg_channels c ON c.id = n.channel LEFT JOIN epg_sources s ON s.id = c.source
             WHERE {filled} ORDER BY {}, n.channel LIKE '%_AR.bein', n.channel", // beIN's file has each channel twice: English before Arabic
            rank("c.source")
        ))?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let (k, ch, name): (String, String, String) = (r.get(0)?, r.get(1)?, r.get(2)?);
            let url: String = r.get(3)?;
            let from = channel_country(&ch, &name, source_country(&url).as_deref());
            names.entry(k).or_default().push((ch, from, r.get(4)?));
        }
    }
    let open = || -> Result<Vec<(String, String)>> {
        let mut st = tx.prepare(
            "SELECT key, name FROM items WHERE kind = 0 AND key NOT IN (SELECT item_key FROM item_epg)",
        )?;
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()
    };
    let mut ins =
        tx.prepare("INSERT OR IGNORE INTO item_epg (item_key, channel) VALUES (?1, ?2)")?;
    for (key, name) in open()? {
        let own = country(&name);
        // The best fit; among equals the first source (min_by_key keeps the first). The provider's own channel wins
        // unless it names another country (owner decision: the provider's guide first).
        let best =
            names
                .get(&norm(&name))
                .into_iter()
                .flatten()
                .filter_map(|(ch, from, builtin)| {
                    let f = fit(own.as_deref(), from.as_deref())?;
                    Some((if *builtin && f != 1 { 0 } else { f + 1 }, ch))
                });
        if let Some((_, ch)) = best.min_by_key(|(f, _)| *f) {
            ins.execute(params![key, ch])?;
        }
    }
    // Twins: a matched item of the same name (and no other country) lends its channel to the unmatched ones.
    let mut twins: HashMap<String, Vec<(String, Option<String>)>> = HashMap::new();
    {
        let mut st = tx.prepare(
            "SELECT i.name, e.channel FROM item_epg e JOIN items i ON i.key = e.item_key ORDER BY i.position",
        )?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let name: String = r.get(0)?;
            let k = norm(&name);
            if !k.is_empty() {
                twins
                    .entry(k)
                    .or_default()
                    .push((r.get(1)?, country(&name)));
            }
        }
    }
    for (key, name) in open()? {
        let own = country(&name);
        let best = twins
            .get(&norm(&name))
            .into_iter()
            .flatten()
            .filter_map(|(ch, from)| Some((fit(own.as_deref(), from.as_deref())?, ch)));
        if let Some((_, ch)) = best.min_by_key(|(f, _)| *f) {
            ins.execute(params![key, ch])?;
        }
    }
    Ok(())
}

/// A programme as the screens show it.
#[derive(Debug, Clone, PartialEq)]
pub struct Programme {
    pub id: i64,
    pub channel: String,
    pub start: i64,
    pub stop: i64,
    pub title: String,
    pub sub_title: String,
    pub desc: String,
    pub category: String,
    pub episode: String,
}

const COLS: &str =
    "p.id, p.channel, p.start, p.stop, p.title, p.sub_title, p.descr, p.category, p.episode";

fn row(r: &rusqlite::Row) -> rusqlite::Result<Programme> {
    Ok(Programme {
        id: r.get(0)?,
        channel: r.get(1)?,
        start: r.get(2)?,
        stop: r.get(3)?,
        title: r.get(4)?,
        sub_title: r.get(5)?,
        desc: r.get(6)?,
        category: r.get(7)?,
        episode: r.get(8)?,
    })
}

/// Now and next for each item key (None where the item has no guide or nothing is on).
pub fn now_next(
    conn: &Connection,
    keys: &[String],
    now: i64,
) -> Result<Vec<(Option<Programme>, Option<Programme>)>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {COLS} FROM item_epg e JOIN programmes p ON p.channel = e.channel
         WHERE e.item_key = ?1 AND p.stop > ?2 ORDER BY p.start LIMIT 2"
    ))?;
    keys.iter()
        .map(|k| {
            let two: Vec<Programme> = st
                .query_map(params![k, now], row)?
                .collect::<rusqlite::Result<_>>()?;
            let mut it = two.into_iter();
            Ok(match it.next() {
                Some(a) if a.start <= now => (Some(a), it.next()),
                Some(a) => (None, Some(a)),
                None => (None, None),
            })
        })
        .collect()
}

/// The guide grid's data: per item key, the programmes overlapping [from, to).
pub fn window(
    conn: &Connection,
    keys: &[String],
    from: i64,
    to: i64,
) -> Result<Vec<Vec<Programme>>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT {COLS} FROM item_epg e JOIN programmes p ON p.channel = e.channel
         WHERE e.item_key = ?1 AND p.stop > ?2 AND p.start < ?3 ORDER BY p.start"
    ))?;
    keys.iter()
        .map(|k| st.query_map(params![k, from, to], row)?.collect())
        .collect()
}

pub fn programme(conn: &Connection, id: i64) -> Result<Option<Programme>> {
    conn.query_row(
        &format!("SELECT {COLS} FROM programmes p WHERE p.id = ?1"),
        [id],
        row,
    )
    .optional()
}

/// Programme search for the global search: (programme, the live item that shows it, ready to play). Running and
/// upcoming programmes soonest first, or with `earlier` the ones that have ended, most recent first: two groups
/// with their own limit, so a missed show isn't pushed out by everything still to come (owner decision).
pub fn search(
    conn: &Connection,
    input: &str,
    now: i64,
    limit: usize,
    earlier: bool,
) -> Result<Vec<(Programme, crate::db::Hit)>> {
    let Some(q) = crate::db::fts_query(input) else {
        return Ok(vec![]);
    };
    let mut st = conn.prepare_cached(&format!(
        "SELECT {COLS}, i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days
         FROM programmes p
         JOIN items i ON i.key = (SELECT item_key FROM item_epg e WHERE e.channel = p.channel LIMIT 1)
         WHERE p.id IN (SELECT rowid FROM programmes_fts WHERE programmes_fts MATCH ?1) AND (p.stop < ?2) = {} {}
         ORDER BY p.start {} LIMIT ?3",
        earlier as i32,
        crate::db::visible_and(conn, "i")?,
        if earlier { "DESC" } else { "ASC" }
    ))?;
    st.query_map(params![q, now, limit as i64], |r| {
        Ok((
            row(r)?,
            crate::db::Hit {
                key: r.get(9)?,
                kind: crate::db::Kind::from_i64(r.get(10)?),
                name: r.get(11)?,
                category: r.get(12)?,
                logo: r.get(13)?,
                number: r.get(14)?,
                archive_days: r.get(15)?,
                group: String::new(),
            },
        ))
    })?
    .collect()
}

/// Live items without a guide match (the mapping screen), in provider order.
pub fn unmatched(
    conn: &Connection,
    limit: usize,
    offset: usize,
    query: &str,
) -> Result<Vec<(String, String)>> {
    // An empty query lists all; otherwise names containing it (LIKE: ASCII case-insensitive, like find_channels).
    let mut st = conn.prepare_cached(
        "SELECT key, name FROM items WHERE kind = 0 AND key NOT IN (SELECT item_key FROM item_epg)
         AND (?3 = '' OR name LIKE '%' || ?3 || '%')
         ORDER BY position LIMIT ?1 OFFSET ?2",
    )?;
    st.query_map(params![limit as i64, offset as i64, query], |r| {
        Ok((r.get(0)?, r.get(1)?))
    })?
    .collect()
}

/// Guide channels whose name contains the query (to pick one when mapping by hand).
pub fn find_channels(
    conn: &Connection,
    query: &str,
    limit: usize,
) -> Result<Vec<(String, String)>> {
    let mut st = conn.prepare_cached(
        "SELECT id, name FROM epg_channels WHERE name LIKE '%' || ?1 || '%' OR id LIKE '%' || ?1 || '%'
         ORDER BY name LIMIT ?2",
    )?;
    st.query_map(params![query, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect()
}

/// Maps an item to a guide channel by hand (None removes the mapping), then rebuilds the matches.
pub fn map_channel(
    conn: &mut Connection,
    item_key: &str,
    channel: Option<&str>,
    now: i64,
) -> Result<()> {
    match channel {
        Some(c) => conn.execute(
            "INSERT INTO epg_map (item_key, channel, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (item_key) DO UPDATE SET channel = ?2, updated_at = ?3",
            params![item_key, c, now],
        )?,
        None => conn.execute("DELETE FROM epg_map WHERE item_key = ?1", [item_key])?,
    };
    rebuild_matches(conn, now)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn times_parse_to_utc() {
        let table = [
            ("20251121170000 +0100", Some(1_763_740_800)),
            ("20251121160000 +0000", Some(1_763_740_800)),
            ("20251121160000", Some(1_763_740_800)),
            ("202511211600 +0000", Some(1_763_740_800)),
            ("20251121103000 -0530", Some(1_763_740_800)),
            ("20240229235959 +0000", Some(1_709_251_199)),
            ("2025112116", None),
            ("20251321160000 +0000", None),
            ("garbage", None),
        ];
        for (s, want) in table {
            assert_eq!(parse_time(s), want, "{s}");
        }
    }

    const DOC: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ard.de"><display-name>Das Erste HD</display-name><display-name>ARD</display-name><icon src="http://l.example.invalid/ard.png"/></channel>
  <channel id="Arte.FR"><display-name>arte</display-name></channel>
  <channel id=""><display-name>no id</display-name></channel>
  <programme start="20251121170000 +0100" stop="20251121180000 +0100" channel="ard.de">
    <title lang="de">Tagesschau &amp; Wetter</title><sub-title>Folge 1</sub-title>
    <desc>Nachrichten aus M&#252;nchen</desc><category>News</category><episode-num system="onscreen">S01E02</episode-num>
  </programme>
  <programme start="20251121180000 +0100" channel="ard.de"><title><![CDATA[Sport <live>]]></title></programme>
  <programme start="bad" stop="20251121180000 +0100" channel="ard.de"><title>Broken</title></programme>
  <programme start="20251121170000 +0100" stop="20251121180000 +0100" channel="ard.de"></programme>
</tv>"#;

    #[test]
    fn parses_channels_programmes_and_quirks() {
        let (mut chs, mut progs) = (vec![], vec![]);
        let stats = parse(DOC.as_bytes(), |c| chs.push(c), |p| progs.push(p)).unwrap();
        assert_eq!(
            stats,
            ParseStats {
                channels: 2,
                programmes: 2,
                skipped: 2
            }
        );
        assert_eq!(chs[0].names, ["Das Erste HD", "ARD"]);
        assert_eq!(chs[0].icon, "http://l.example.invalid/ard.png");
        let p = &progs[0];
        assert_eq!(
            (p.title.as_str(), p.desc.as_str()),
            ("Tagesschau & Wetter", "Nachrichten aus München")
        );
        assert_eq!(
            (
                p.sub_title.as_str(),
                p.category.as_str(),
                p.episode.as_str()
            ),
            ("Folge 1", "News", "S01E02")
        );
        assert_eq!((p.start, p.stop), (1_763_740_800, 1_763_744_400));
        assert_eq!(progs[1].title, "Sport <live>");
        assert_eq!(
            progs[1].stop - progs[1].start,
            1800,
            "a missing stop means half an hour"
        );
    }

    #[test]
    fn gzip_and_xz_are_detected() {
        use std::io::Write;
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(DOC.as_bytes()).unwrap();
        let bytes = gz.finish().unwrap();
        let mut n = 0;
        parse(maybe_unpack(bytes.as_slice()).unwrap(), |_| {}, |_| n += 1).unwrap();
        assert_eq!(n, 2);
        let mut xz =
            lzma_rust2::XzWriter::new(Vec::new(), lzma_rust2::XzOptions::default()).unwrap();
        xz.write_all(DOC.as_bytes()).unwrap();
        let bytes = xz.finish().unwrap();
        let mut n = 0;
        parse(maybe_unpack(bytes.as_slice()).unwrap(), |_| {}, |_| n += 1).unwrap();
        assert_eq!(n, 2);
        // A download that broke off is an error, not a short guide.
        let cut = &bytes[..bytes.len() / 2];
        assert!(parse(maybe_unpack(cut).unwrap(), |_| {}, |_| {}).is_err());
    }

    fn db_with_items() -> Connection {
        let mut c = crate::db::open(Path::new(":memory:")).unwrap();
        let pl = "#EXTM3U\n\
            #EXTINF:-1 tvg-id=\"ard.de\",DE | Das Erste FHD\nhttp://h/live/u/p/1.ts\n\
            #EXTINF:-1 tvg-id=\"arte.fr\",Arte\nhttp://h/live/u/p/2.ts\n\
            #EXTINF:-1,DE: ARD HD\nhttp://h/live/u/p/3.ts\n\
            #EXTINF:-1,Unknown Channel\nhttp://h/live/u/p/4.ts\n";
        crate::db::import_m3u(&mut c, pl.as_bytes(), &[]).unwrap();
        c
    }

    #[test]
    fn import_match_and_query() {
        let mut c = db_with_items();
        let now = 1_763_742_000; // 17:20 local: Tagesschau runs
        let stats = import(&mut c, 1, DOC.as_bytes(), now, 2, 7, 0).unwrap();
        assert_eq!((stats.channels, stats.programmes), (2, 2));
        // Matching: exact id, normalised display name ("ARD" ← "DE: ARD HD"); not "Unknown", and not Arte: its guide
        // channel has no programmes (an extra source may fill it).
        assert_eq!(rebuild_matches(&mut c, now).unwrap(), 2);
        let keys: Vec<String> = ["live:1", "live:2", "live:3", "live:4"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let nn = now_next(&c, &keys, now).unwrap();
        assert_eq!(
            nn[0].0.as_ref().map(|p| p.title.as_str()),
            Some("Tagesschau & Wetter")
        );
        assert_eq!(
            nn[0].1.as_ref().map(|p| p.title.as_str()),
            Some("Sport <live>")
        );
        assert_eq!(nn[2].0.as_ref().map(|p| p.channel.as_str()), Some("ard.de"));
        assert_eq!(
            (nn[1].0.is_none(), nn[3].0.is_none()),
            (true, true),
            "arte has no programmes, unknown no match"
        );
        let w = window(&c, &keys[..1], now + 3600, now + 7200).unwrap();
        assert_eq!(w[0].len(), 1);
        assert_eq!(
            programme(&c, w[0][0].id).unwrap().unwrap().title,
            "Sport <live>"
        );
        // Programme search, umlaut-insensitive, with the item that shows it.
        let hits = search(&c, "munchen", now, 10, false).unwrap();
        assert_eq!(
            (hits.len(), hits[0].0.title.as_str()),
            (1, "Tagesschau & Wetter")
        );
        assert!(hits[0].1.key == "live:1" || hits[0].1.key == "live:3");
        // Three hours later it has ended: it is in the "earlier" group, not among the running and upcoming.
        let later = now + 3 * 3600;
        assert!(search(&c, "munchen", later, 10, false).unwrap().is_empty());
        assert_eq!(search(&c, "munchen", later, 10, true).unwrap().len(), 1);
        // Manual mapping wins and survives a rebuild; unmatched lists the rest.
        assert_eq!(
            unmatched(&c, 10, 0, "").unwrap(),
            [
                ("live:2".to_string(), "Arte".to_string()),
                ("live:4".to_string(), "Unknown Channel".to_string())
            ]
        );
        // The screen's search: part of the name, any case, over every page.
        assert_eq!(
            unmatched(&c, 10, 0, "known").unwrap(),
            [("live:4".to_string(), "Unknown Channel".to_string())]
        );
        assert!(unmatched(&c, 10, 0, "zdf").unwrap().is_empty());
        assert_eq!(find_channels(&c, "Erste", 5).unwrap()[0].0, "ard.de");
        map_channel(&mut c, "live:4", Some("ard.de"), now).unwrap();
        map_channel(&mut c, "live:2", Some("Arte.FR"), now).unwrap();
        assert!(
            unmatched(&c, 10, 0, "").unwrap().is_empty(),
            "a manual mapping counts, programmes or not"
        );
        assert!(now_next(&c, &keys[3..], now).unwrap()[0].0.is_some());
    }

    #[test]
    fn reimport_replaces_and_window_and_offset_apply() {
        let mut c = db_with_items();
        let now = 1_763_742_000;
        import(&mut c, 1, DOC.as_bytes(), now, 2, 7, 0).unwrap();
        let again = import(&mut c, 1, DOC.as_bytes(), now, 2, 7, 0).unwrap();
        let n: i64 = c
            .query_row("SELECT count(*) FROM programmes", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            (again.programmes, n),
            (2, 2),
            "a source replaces its own rows"
        );
        // A second source can't add a second schedule for a channel the first already fills.
        let other = import(&mut c, 2, DOC.as_bytes(), now, 2, 7, 0).unwrap();
        assert_eq!((other.programmes, other.outside), (0, 2));
        // Far in the future: outside the window. The offset moves times (+1 h).
        let later = import(&mut c, 1, DOC.as_bytes(), now - 30 * 86_400, 2, 7, 0).unwrap();
        assert_eq!(later.programmes, 0);
        import(&mut c, 1, DOC.as_bytes(), now, 2, 7, 3600).unwrap();
        let start: i64 = c
            .query_row("SELECT min(start) FROM programmes", [], |r| r.get(0))
            .unwrap();
        assert_eq!(start, 1_763_740_800 + 3600);
        assert_eq!(prune(&c, now + 10 * 86_400, 2).unwrap(), 2);
    }

    #[test]
    fn overlapping_sources_give_the_provider_its_channels_and_twins_borrow_a_match() {
        // Source 1 is the provider's guide, 2 an extra file (both listed, so they rank provider first).
        let mut c = crate::db::open(Path::new(":memory:")).unwrap();
        c.execute_batch(
            "INSERT INTO epg_sources (id, url, builtin, updated_at) VALUES (1, 'builtin', 1, 0), (2, 'x', 0, 0)",
        )
        .unwrap();
        let pl = "#EXTM3U\n\
            #EXTINF:-1 tvg-id=\"zdf\",DE: ZDF HD\nhttp://h/live/u/p/1.ts\n\
            #EXTINF:-1,ZDF FHD\nhttp://h/live/u/p/2.ts\n\
            #EXTINF:-1 tvg-id=\"kika\",KiKA\nhttp://h/live/u/p/3.ts\n\
            #EXTINF:-1,|DE| 3sat\nhttp://h/live/u/p/4.ts\n";
        crate::db::import_m3u(&mut c, pl.as_bytes(), &[]).unwrap();
        let now = 1_763_742_000;
        let prog = |ch: &str, title: &str| {
            format!(
                r#"<programme start="20251121170000 +0100" stop="20251121180000 +0100" channel="{ch}"><title>{title}</title></programme>"#
            )
        };
        // The provider lists ZDF with a schedule, KiKA and 3sat without one; the extra file has all three.
        let provider = format!(
            r#"<tv><channel id="zdf"><display-name>ZDF</display-name></channel>
               <channel id="kika"><display-name>KiKA</display-name></channel>
               <channel id="3sat.p"><display-name>3sat</display-name></channel>{}</tv>"#,
            prog("zdf", "Provider news")
        );
        let extra = format!(
            r#"<tv><channel id="zdf"><display-name>ZDF</display-name></channel>
               <channel id="kika"><display-name>KiKA</display-name></channel>
               <channel id="3sat.x"><display-name>3sat</display-name></channel>{}{}{}</tv>"#,
            prog("zdf", "Extra news"),
            prog("kika", "Extra cartoons"),
            prog("3sat.x", "Extra culture")
        );
        // Twice in refresh order (provider first), as two refreshes would: the second must not flip anything.
        for _ in 0..2 {
            import(&mut c, 1, provider.as_bytes(), now, 2, 7, 0).unwrap();
            import(&mut c, 2, extra.as_bytes(), now, 2, 7, 0).unwrap();
            rebuild_matches(&mut c, now).unwrap();
            let keys: Vec<String> = (1..=4).map(|i| format!("live:{i}")).collect();
            let titles: Vec<Option<String>> = now_next(&c, &keys, now)
                .unwrap()
                .into_iter()
                .map(|(n, _)| n.map(|p| p.title))
                .collect();
            assert_eq!(
                titles,
                [
                    Some("Provider news".into()),  // both have it: the provider's schedule
                    Some("Provider news".into()), // a twin of "DE: ZDF HD" (no guide id, name "ZDF")
                    Some("Extra cartoons".into()), // the provider lists KiKA without programmes
                    Some("Extra culture".into()), // "|DE| 3sat": the provider's 3sat is empty, the extra's isn't
                ]
            );
            let n: i64 = c
                .query_row(
                    "SELECT count(*) FROM programmes WHERE channel = 'zdf'",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "one schedule per channel");
        }
    }

    #[test]
    fn a_shared_name_needs_the_right_country_and_a_running_schedule() {
        let mut c = crate::db::open(Path::new(":memory:")).unwrap();
        c.execute_batch(
            "INSERT INTO epg_sources (id, url, builtin, updated_at) VALUES (1, 'builtin', 1, 0),
             (2, 'https://h.invalid/epg_ripper_DE1.xml.gz', 0, 0), (3, 'https://h.invalid/epg_ripper_UK1.xml.gz', 0, 0),
             (4, 'https://free-epg.de/api/epg/gb.xml.gz', 0, 0)",
        )
        .unwrap();
        let pl = "#EXTM3U\n\
            #EXTINF:-1,Comedy HD UK\nhttp://h/live/u/p/1.ts\n\
            #EXTINF:-1,Comedy DE\nhttp://h/live/u/p/2.ts\n\
            #EXTINF:-1,Comedy AT\nhttp://h/live/u/p/3.ts\n\
            #EXTINF:-1,Comedy RU\nhttp://h/live/u/p/4.ts\n\
            #EXTINF:-1 tvg-id=\"old\",Krimi DE\nhttp://h/live/u/p/5.ts\n\
            #EXTINF:-1 tvg-id=\"42\",Numbered\nhttp://h/live/u/p/6.ts\n\
            #EXTINF:-1,Drama UK\nhttp://h/live/u/p/7.ts\n";
        crate::db::import_m3u(&mut c, pl.as_bytes(), &[]).unwrap();
        let now = 1_763_742_000;
        let doc = |id: &str, name: &str, hours: &str, title: &str| {
            format!(
                r#"<channel id="{id}"><display-name>{name}</display-name></channel>
                   <programme start="20251121{hours}0000 +0100" stop="20251121180000 +0100" channel="{id}"><title>{title}</title></programme>"#
            )
        };
        // The provider's schedule for "old" ended at noon; the German file has the channel under the same id.
        let ended = r#"<tv><channel id="old"><display-name>Alt</display-name></channel>
            <programme start="20251121110000 +0100" stop="20251121120000 +0100" channel="old"><title>Ended</title></programme></tv>"#;
        let de = format!(
            "<tv>{}{}</tv>",
            doc("c.de", "Comedy", "17", "German"),
            doc("old", "Krimi", "17", "Krimi now")
        );
        let uk = format!(
            "<tv>{}{}</tv>",
            doc("c.uk", "Comedy", "17", "British"),
            doc("n.uk", "Nobody", "17", "No item")
        );
        let free = format!(
            "<tv>{}{}</tv>",
            doc("42", "Other", "17", "Wrong"),
            doc("43", "Drama", "17", "British drama")
        );
        for _ in 0..2 {
            import(&mut c, 1, ended.as_bytes(), now, 2, 7, 0).unwrap();
            import(&mut c, 2, de.as_bytes(), now, 2, 7, 0).unwrap();
            import(&mut c, 3, uk.as_bytes(), now, 2, 7, 0).unwrap();
            import(&mut c, 4, free.as_bytes(), now, 2, 7, 0).unwrap();
            rebuild_matches(&mut c, now).unwrap();
            let keys: Vec<String> = (1..=7).map(|i| format!("live:{i}")).collect();
            let titles: Vec<Option<String>> = now_next(&c, &keys, now)
                .unwrap()
                .into_iter()
                .map(|(n, _)| n.map(|p| p.title))
                .collect();
            let some = |s: &str| Some(s.to_string());
            assert_eq!(
                titles,
                [
                    some("British"), // although the German file ranks first
                    some("German"),
                    some("German"), // Germany, Austria and Switzerland share channels
                    None,           // no Russian guide: better none than a wrong one
                    some("Krimi now"),
                    None, // another project's channel number 42
                    some("British drama"),
                ]
            );
            // Programmes of channels no item can take aren't stored.
            let stored: i64 = c
                .query_row(
                    "SELECT count(*) FROM programmes WHERE title IN ('No item', 'Wrong')",
                    [],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(stored, 0);
        }
    }

    #[test]
    fn names_normalise_for_matching() {
        for (raw, want) in [
            ("DE | Das Erste HD", "daserste"),
            ("[DE] ZDF FHD", "zdf"),
            ("Sky Cinema (HEVC)", "skycinema"),
            ("BBC-One", "bbcone"),
            // A country code at the end, or before a dash (several community files).
            ("Kanal 5 FHD DE", "kanal5"),
            ("AT - Kanal 5", "kanal5"),
            // Only known codes, and never the whole name.
            ("Kanal TV", "kanaltv"),
            ("DE", "de"),
            // Accents fold; a plus is a different channel, not decoration.
            ("Planète Süd", "planetesud"),
            ("3+", "3plus"),
            ("Kanal +1", "kanalplus1"),
            // beIN's file.
            ("beIN_SPORTS1_DIGITAL_Mono_EN", "beinsports1"),
            ("NEW_beIN-SPORTS-MAX-05_AR", "beinsportsmax5"),
            ("logos-_beINSPORTS8_EN", "beinsports8"),
            ("beIN_SPORTS_XTRA_04_bein.com_AR", "beinsportsxtra4"),
            ("beIN SPORTS 1 HD QA", "beinsports1"),
        ] {
            assert_eq!(norm(raw), want, "{raw}");
        }
        for (raw, want) in [
            ("Kanal 5 HD DE", Some("DE")),
            ("AT - Kanal 5", Some("AT")),
            ("|DE| Kanal", Some("DE")),
            ("GB: Kanal", Some("UK")),
            ("Kanal (RS)", Some("RS")),
            ("Kanal 5", None),
        ] {
            assert_eq!(country(raw).as_deref(), want, "{raw}");
        }
        for (url, want) in [
            ("https://h.invalid/epg_ripper_AT1.xml.gz", Some("AT")),
            ("https://h.invalid/epg_ripper_BEIN1.xml.gz", Some("QA")),
            ("https://free-epg.de/api/epg/gb.xml.gz", Some("UK")),
            ("https://h.invalid/guide.xml", None),
        ] {
            assert_eq!(source_country(url).as_deref(), want, "{url}");
        }
    }
}
