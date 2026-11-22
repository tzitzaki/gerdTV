//! Streaming M3U / M3U8 playlist parser (the fallback source; Xtream Codes is the main one).
//!
//! Single pass over a `BufRead`: it never holds the whole file, and hands each entry to a callback as soon as its
//! URL line arrives, so a 150k-entry playlist is browsable while it is still downloading. Understands `#EXTINF`
//! attributes (tvg-id, tvg-name, tvg-logo, tvg-chno, group-title, catchup, catchup-days, catchup-source,
//! timeshift), `#EXTGRP` and `#EXTVLCOPT:http-user-agent`. Malformed lines are counted and skipped, never fatal.
//!
//! Debug hint: `Stats::skipped` > 0 means lines were dropped; run with RUST_LOG=gerdtv_core::m3u=debug to see them.

use std::io::BufRead;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Live,
    Movie,
    Episode,
}

/// One playlist entry.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Entry {
    pub name: String,
    pub url: String,
    pub tvg_id: String,
    pub tvg_name: String,
    pub logo: String,
    pub group: String,
    pub number: Option<u32>,
    pub catchup: String,
    pub catchup_days: Option<u32>,
    pub catchup_source: String,
    pub timeshift: Option<u32>,
    /// From `#EXTVLCOPT:http-user-agent=…` (some providers require one per stream).
    pub user_agent: String,
    pub kind: Option<Kind>,
    /// Season and episode from an `S01E02`-style name.
    pub episode: Option<(u32, u32)>,
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Stats {
    pub entries: usize,
    pub skipped: usize,
    /// The playlist's guide URL from the header (`#EXTM3U url-tvg="…"` or `x-tvg-url`), if any.
    pub tvg_url: Option<String>,
}

/// Parses `input`, calling `on_entry` for every complete entry. I/O errors end the parse and are returned.
pub fn parse(mut input: impl BufRead, mut on_entry: impl FnMut(Entry)) -> std::io::Result<Stats> {
    let mut stats = Stats::default();
    let mut pending: Option<Entry> = None;
    let mut group_hint = String::new();
    let mut user_agent = String::new();
    let mut line = String::new();
    loop {
        line.clear();
        if input.read_line(&mut line)? == 0 {
            break;
        }
        let l = line.trim();
        if l.is_empty() {
            continue;
        }
        if let Some(rest) = l.strip_prefix("#EXTINF:") {
            if pending.is_some() {
                stats.skipped += 1; // an #EXTINF without its URL line
            }
            pending = parse_extinf(rest);
            if pending.is_none() {
                stats.skipped += 1;
                tracing::debug!(target: "gerdtv_core::m3u", "malformed #EXTINF skipped");
            }
        } else if let Some(g) = l.strip_prefix("#EXTGRP:") {
            group_hint = g.trim().to_string();
        } else if let Some(opt) = l.strip_prefix("#EXTVLCOPT:") {
            if let Some(ua) = opt.strip_prefix("http-user-agent=") {
                user_agent = ua.to_string();
            }
        } else if let Some(h) = l.strip_prefix("#EXTM3U") {
            stats.tvg_url = attributes(h)
                .into_iter()
                .find(|(k, _)| {
                    k.eq_ignore_ascii_case("url-tvg") || k.eq_ignore_ascii_case("x-tvg-url")
                })
                .map(|(_, v)| v.split(',').next().unwrap_or("").trim().to_string()) // several URLs: the first
                .filter(|v| !v.is_empty());
        } else if l.starts_with('#') {
            // #EXTM3U and other directives: nothing to keep.
        } else if let Some(mut e) = pending.take() {
            e.url = l.to_string();
            if e.group.is_empty() {
                e.group = std::mem::take(&mut group_hint);
            }
            e.user_agent = std::mem::take(&mut user_agent);
            e.episode = episode_of(&e.name);
            e.kind = Some(classify(&e));
            group_hint.clear();
            stats.entries += 1;
            on_entry(e);
        } else {
            stats.skipped += 1; // a URL without #EXTINF
        }
    }
    if pending.is_some() {
        stats.skipped += 1;
    }
    Ok(stats)
}

/// `-1 tvg-id="x" group-title="a, b",Display Name` → an entry without URL. The title starts after the first comma
/// outside quotes (titles may contain commas; attribute values too).
fn parse_extinf(rest: &str) -> Option<Entry> {
    let mut in_quotes = false;
    let mut split = None;
    for (i, c) in rest.char_indices() {
        match c {
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                split = Some(i);
                break;
            }
            _ => {}
        }
    }
    let i = split?;
    let (attrs, name) = (&rest[..i], rest[i + 1..].trim());
    let mut e = Entry {
        name: name.to_string(),
        ..Entry::default()
    };
    for (k, v) in attributes(attrs) {
        match k.to_ascii_lowercase().as_str() {
            "tvg-id" => e.tvg_id = v.to_string(),
            "tvg-name" => e.tvg_name = v.to_string(),
            "tvg-logo" => e.logo = v.to_string(),
            "tvg-chno" => e.number = v.parse().ok().filter(|n| *n > 0),
            "group-title" => e.group = v.to_string(),
            "catchup" => e.catchup = v.to_string(),
            "catchup-days" => e.catchup_days = v.parse().ok(),
            "catchup-source" => e.catchup_source = v.to_string(),
            "timeshift" => e.timeshift = v.parse().ok(),
            _ => {}
        }
    }
    if e.name.is_empty() {
        e.name = e.tvg_name.clone();
    }
    (!e.name.is_empty()).then_some(e)
}

/// `key="value"` pairs (also unquoted `key=value`).
fn attributes(s: &str) -> Vec<(&str, &str)> {
    let mut out = Vec::new();
    let mut rest = s;
    while let Some(eq) = rest.find('=') {
        let key = rest[..eq].rsplit(' ').next().unwrap_or("").trim();
        let after = &rest[eq + 1..];
        let (value, next) = if let Some(q) = after.strip_prefix('"') {
            match q.find('"') {
                Some(end) => (&q[..end], &q[end + 1..]),
                None => (q, ""),
            }
        } else {
            let end = after.find(' ').unwrap_or(after.len());
            (&after[..end], &after[end..])
        };
        if !key.is_empty() {
            out.push((key, value));
        }
        rest = next;
    }
    out
}

/// `… S01E02 …` / `s1e2` / `S01 E02` → (season, episode).
pub fn episode_of(name: &str) -> Option<(u32, u32)> {
    let b = name.as_bytes();
    for i in 0..b.len() {
        if !(b[i] == b'S' || b[i] == b's') || (i > 0 && b[i - 1].is_ascii_alphanumeric()) {
            continue;
        }
        // Not `?`: an "S" without digits (the S of "Show") must not end the search.
        let Some((s, j)) = digits(b, i + 1) else {
            continue;
        };
        let j = if b.get(j) == Some(&b' ') { j + 1 } else { j };
        if matches!(b.get(j), Some(b'E') | Some(b'e'))
            && let Some((e, _)) = digits(b, j + 1)
        {
            return Some((s, e));
        }
    }
    None
}

fn digits(b: &[u8], from: usize) -> Option<(u32, usize)> {
    let end = (from..b.len())
        .find(|&k| !b[k].is_ascii_digit())
        .unwrap_or(b.len());
    if end == from || end - from > 4 {
        return None;
    }
    std::str::from_utf8(&b[from..end])
        .ok()?
        .parse()
        .ok()
        .map(|n| (n, end))
}

/// Live, movie or episode: the URL path first (Xtream Codes paths), then the extension, then the group's wording.
pub fn classify(e: &Entry) -> Kind {
    let url = e.url.to_ascii_lowercase();
    let path = url.split('?').next().unwrap_or("");
    if path.contains("/movie/") {
        return Kind::Movie;
    }
    if path.contains("/series/") {
        return Kind::Episode;
    }
    if path.contains("/live/") {
        return Kind::Live;
    }
    let ext = path
        .rsplit('/')
        .next()
        .and_then(|f| f.rsplit_once('.'))
        .map(|(_, x)| x)
        .unwrap_or("");
    match ext {
        "mp4" | "mkv" | "avi" | "mov" | "wmv" | "m4v" | "webm" => {
            return if e.episode.is_some() {
                Kind::Episode
            } else {
                Kind::Movie
            };
        }
        "ts" | "m3u8" => {}
        _ => {}
    }
    let g = e.group.to_lowercase();
    if ["serie", "series", "staffel", "season"]
        .iter()
        .any(|w| g.contains(w))
    {
        Kind::Episode
    } else if ["vod", "movie", "film", "kino"]
        .iter()
        .any(|w| g.contains(w))
    {
        Kind::Movie
    } else {
        Kind::Live
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_str(s: &str) -> (Vec<Entry>, Stats) {
        let mut v = vec![];
        let stats = parse(s.as_bytes(), |e| v.push(e)).unwrap();
        (v, stats)
    }

    #[test]
    fn parses_attributes_and_quirks() {
        let (v, stats) = parse_str(
            "#EXTM3U url-tvg=\"x\"\n\
             #EXTINF:-1 tvg-id=\"ard.de\" tvg-name=\"ARD HD\" tvg-logo=\"http://l.example.invalid/a.png\" tvg-chno=\"1\" group-title=\"DE | Vollprogramm, HD\" catchup=\"xc\" catchup-days=\"7\",Das Erste, HD\n\
             http://x.example.invalid/live/u/p/1.ts\n\
             #EXTINF:-1,\n\
             http://x.example.invalid/nothing.ts\n\
             #EXTINF:0 tvg-name=\"Fallback Name\",\n\
             #EXTGRP:Kino\n\
             #EXTVLCOPT:http-user-agent=Agent/2\n\
             http://x.example.invalid/films/abc.mkv\n\
             #EXTINF:-1 group-title=\"Serien\",Show S02E05\n\
             http://x.example.invalid/s/5.mp4\n\
             http://orphan.example.invalid/url.ts\n\
             #EXTINF:broken without comma\n\
             #EXTINF:-1,Last without url\n",
        );
        assert_eq!(v.len(), 3);
        let a = &v[0];
        assert_eq!(
            (a.name.as_str(), a.tvg_id.as_str(), a.group.as_str()),
            ("Das Erste, HD", "ard.de", "DE | Vollprogramm, HD")
        );
        assert_eq!(
            (a.number, a.catchup_days, a.kind),
            (Some(1), Some(7), Some(Kind::Live))
        );
        assert_eq!(
            (
                v[1].name.as_str(),
                v[1].group.as_str(),
                v[1].user_agent.as_str()
            ),
            ("Fallback Name", "Kino", "Agent/2")
        );
        assert_eq!(v[1].kind, Some(Kind::Movie));
        assert_eq!(
            (v[2].kind, v[2].episode),
            (Some(Kind::Episode), Some((2, 5)))
        );
        // The nameless #EXTINF and its then-orphaned URL, the orphan URL, the comma-less #EXTINF, the URL-less last.
        assert_eq!(
            stats,
            Stats {
                entries: 3,
                skipped: 5,
                tvg_url: Some("x".into()), // the header's url-tvg
            }
        );
    }

    #[test]
    fn episode_names() {
        for (name, ep) in [
            ("Show S01E02", Some((1, 2))),
            ("show s1e10 extra", Some((1, 10))),
            ("Show S03 E04", Some((3, 4))),
            ("NEWS 2024", None),
            ("SOS Eisberg", None),
            ("Mass Effect", None),
        ] {
            assert_eq!(episode_of(name), ep, "{name}");
        }
    }

    #[test]
    fn classification_order() {
        let e = |url: &str, group: &str, name: &str| {
            let mut e = Entry {
                url: url.into(),
                group: group.into(),
                name: name.into(),
                ..Entry::default()
            };
            e.episode = episode_of(name);
            classify(&e)
        };
        assert_eq!(e("http://h/movie/u/p/1.mkv", "Live", "x"), Kind::Movie);
        assert_eq!(e("http://h/series/u/p/1.mp4", "", "x"), Kind::Episode);
        assert_eq!(e("http://h/live/u/p/1.ts", "VOD", "x"), Kind::Live);
        assert_eq!(e("http://h/a.mp4", "", "Show S01E01"), Kind::Episode);
        assert_eq!(e("http://h/a.mp4", "", "Film"), Kind::Movie);
        assert_eq!(e("http://h/a.ts", "Serien DE", "x"), Kind::Episode);
        assert_eq!(e("http://h/a", "VOD | Kino", "x"), Kind::Movie);
        assert_eq!(e("http://h/a", "Sport", "x"), Kind::Live);
    }
}
