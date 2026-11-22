//! The TV guide (EPG): XMLTV import, channel matching, and the queries every screen uses (now/next in lists, the
//! guide grid's window, programme details, programme search).
//!
//! - Parser: streaming over a `BufRead` (quick-xml), gzip detected by its magic bytes (flate2); a 300 MB guide never
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

/// Wraps a reader in a gzip decoder when it starts with gzip's magic bytes.
pub fn maybe_gunzip<'a>(mut r: impl BufRead + 'a) -> std::io::Result<Box<dyn BufRead + 'a>> {
    let gz = r.fill_buf()?.starts_with(&[0x1f, 0x8b]);
    Ok(if gz {
        Box::new(BufReader::new(flate2::bufread::GzDecoder::new(r)))
    } else {
        Box::new(r)
    })
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

/// The matching key of a channel name: cleaned (prefixes, quality tags), lower-case, letters and digits only.
pub fn norm(name: &str) -> String {
    clean_name(name)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ImportStats {
    pub channels: usize,
    pub programmes: usize,
    pub skipped: usize,
    /// Programmes left out: outside the window, or for a channel an earlier source already covers.
    pub outside: usize,
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
    let input = maybe_gunzip(BufReader::new(input))?;
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
    // Channels other sources already fill: this source must not add a second schedule for them.
    let taken: std::collections::HashSet<String> = {
        let mut st = tx
            .prepare("SELECT DISTINCT channel FROM programmes WHERE source != ?1")
            .map_err(io)?;
        st.query_map([source], |r| r.get(0))
            .map_err(io)?
            .collect::<rusqlite::Result<_>>()
            .map_err(io)?
    };
    let (from, to) = (now - days_back * 86_400, now + days_ahead * 86_400);
    // Both callbacks below record into these (RefCell: two closures can't both borrow them mutably).
    let stats = std::cell::RefCell::new(ImportStats::default());
    let failed: std::cell::RefCell<Option<rusqlite::Error>> = std::cell::RefCell::new(None);
    {
        let mut ch = tx
            .prepare("INSERT OR IGNORE INTO epg_channels (id, name, icon, source) VALUES (?1, ?2, ?3, ?4)")
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
            |c| {
                if failed.borrow().is_some() {
                    return;
                }
                let name = c.names.first().cloned().unwrap_or_else(|| c.id.clone());
                let r = (|| -> rusqlite::Result<()> {
                    if ch.execute(params![c.id, name, c.icon, source])? > 0 {
                        stats.borrow_mut().channels += 1;
                        for n in &c.names {
                            let k = norm(n);
                            if !k.is_empty() {
                                nm.execute(params![k, c.id])?;
                            }
                        }
                    }
                    Ok(())
                })();
                if let Err(e) = r {
                    *failed.borrow_mut() = Some(e);
                }
            },
            |mut p| {
                if failed.borrow().is_some() {
                    return;
                }
                p.start += offset_secs;
                p.stop += offset_secs;
                if p.stop <= from || p.start >= to || taken.contains(&p.channel) {
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

/// Rebuilds which guide channel each live item shows (manual mapping, id, id ignoring case, normalised name).
/// Returns the number of matched items.
pub fn rebuild_matches(conn: &mut Connection) -> Result<usize> {
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM item_epg", [])?;
    tx.execute(
        "INSERT OR IGNORE INTO item_epg (item_key, channel) SELECT item_key, channel FROM epg_map",
        [],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO item_epg (item_key, channel)
         SELECT i.key, c.id FROM items i JOIN epg_channels c ON c.id = i.epg_id WHERE i.kind = 0 AND i.epg_id != ''",
        [],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO item_epg (item_key, channel)
         SELECT i.key, c.id FROM items i JOIN epg_channels c ON lower(c.id) = lower(i.epg_id)
         WHERE i.kind = 0 AND i.epg_id != ''",
        [],
    )?;
    // Names: done in Rust (norm() isn't SQL). Only for the items still without a match.
    let names: HashMap<String, String> = {
        let mut st = tx.prepare("SELECT norm, channel FROM epg_names")?;
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?
    };
    let open: Vec<(String, String)> = {
        let mut st = tx.prepare(
            "SELECT key, name FROM items WHERE kind = 0 AND key NOT IN (SELECT item_key FROM item_epg)",
        )?;
        st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?
    };
    {
        let mut ins =
            tx.prepare("INSERT OR IGNORE INTO item_epg (item_key, channel) VALUES (?1, ?2)")?;
        for (key, name) in open {
            if let Some(ch) = names.get(&norm(&name)) {
                ins.execute(params![key, ch])?;
            }
        }
    }
    let n = tx.query_row("SELECT count(*) FROM item_epg", [], |r| r.get::<_, i64>(0))? as usize;
    tx.commit()?;
    Ok(n)
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

/// Programme search for the global search: (programme, the live item that shows it, ready to play), ongoing and
/// upcoming first.
pub fn search(
    conn: &Connection,
    input: &str,
    now: i64,
    limit: usize,
) -> Result<Vec<(Programme, crate::db::Hit)>> {
    let Some(q) = crate::db::fts_query(input) else {
        return Ok(vec![]);
    };
    let mut st = conn.prepare_cached(&format!(
        "SELECT {COLS}, i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days
         FROM programmes p
         JOIN items i ON i.key = (SELECT item_key FROM item_epg e WHERE e.channel = p.channel LIMIT 1)
         WHERE p.id IN (SELECT rowid FROM programmes_fts WHERE programmes_fts MATCH ?1)
         ORDER BY p.stop < ?2, p.start LIMIT ?3"
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
            },
        ))
    })?
    .collect()
}

/// Live items without a guide match (the mapping screen), in provider order.
pub fn unmatched(conn: &Connection, limit: usize, offset: usize) -> Result<Vec<(String, String)>> {
    let mut st = conn.prepare_cached(
        "SELECT key, name FROM items WHERE kind = 0 AND key NOT IN (SELECT item_key FROM item_epg)
         ORDER BY position LIMIT ?1 OFFSET ?2",
    )?;
    st.query_map(params![limit as i64, offset as i64], |r| {
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
    rebuild_matches(conn)?;
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
    fn gzip_is_detected() {
        use std::io::Write;
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(DOC.as_bytes()).unwrap();
        let bytes = gz.finish().unwrap();
        let mut n = 0;
        parse(maybe_gunzip(bytes.as_slice()).unwrap(), |_| {}, |_| n += 1).unwrap();
        assert_eq!(n, 2);
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
        // Matching: exact id, id ignoring case, normalised display name ("ARD" ← "DE: ARD HD"); not "Unknown".
        assert_eq!(rebuild_matches(&mut c).unwrap(), 3);
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
        let hits = search(&c, "munchen", now, 10).unwrap();
        assert_eq!(
            (hits.len(), hits[0].0.title.as_str()),
            (1, "Tagesschau & Wetter")
        );
        assert!(hits[0].1.key == "live:1" || hits[0].1.key == "live:3");
        // Manual mapping wins and survives a rebuild; unmatched lists the rest.
        assert_eq!(
            unmatched(&c, 10, 0).unwrap(),
            [("live:4".to_string(), "Unknown Channel".to_string())]
        );
        assert_eq!(find_channels(&c, "Erste", 5).unwrap()[0].0, "ard.de");
        map_channel(&mut c, "live:4", Some("ard.de"), now).unwrap();
        assert!(unmatched(&c, 10, 0).unwrap().is_empty());
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
    fn names_normalise_for_matching() {
        for (raw, want) in [
            ("DE | Das Erste HD", "daserste"),
            ("[DE] ZDF FHD", "zdf"),
            ("Sky Cinema (HEVC)", "skycinema"),
            ("BBC-One", "bbcone"),
        ] {
            assert_eq!(norm(raw), want, "{raw}");
        }
    }
}
