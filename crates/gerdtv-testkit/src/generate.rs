//! Synthetic test data: a provider library (live channels, movies, series episodes) as M3U or Xtream Codes JSON, and
//! an XMLTV guide for it. Deterministic (seeded), sized to the performance budgets (docs/SPEC.md and the 6.4 budgets:
//! 150k entries, 2,000 channels × 7 days), and full of the quirks real providers have: country prefixes (`DE |`),
//! quality tags (HD/FHD/4K), umlauts, `(2019)` years, `S01E02` episode names, empty logos, odd group names.
//! Every URL points at `example.invalid`, so nothing here can leak or reach a real server.
//!
//! Writers stream to any `io::Write`, so a 300 MB guide never sits in memory.

use std::io::{self, Write};

/// A tiny deterministic PRNG (xorshift64*): reproducible data without a rand dependency.
#[derive(Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed.max(1))
    }
    pub fn next_u64(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    /// A number in 0..n.
    pub fn below(&mut self, n: usize) -> usize {
        (self.next_u64() % n as u64) as usize
    }
    pub fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[self.below(items.len())]
    }
}

const WORDS: &[&str] = &[
    "Sport",
    "Nachrichten",
    "Kino",
    "Welt",
    "München",
    "Köln",
    "Familie",
    "Drama",
    "Natur",
    "Doku",
    "Musik",
    "Comedy",
    "Krimi",
    "Abenteuer",
    "Geschichte",
    "Wissen",
    "Reise",
    "Küche",
    "Größe",
    "Straße",
    "Action",
    "Science",
    "News",
    "Kids",
    "Planet",
    "Zeit",
    "Arena",
    "Life",
    "Classic",
    "Märchen",
];
const COUNTRIES: &[&str] = &["DE", "AT", "CH", "UK", "US", "FR", "IT", "TR", "PL", "NL"];
const QUALITY: &[&str] = &["", "", " HD", " FHD", " 4K", " UHD", " HEVC", " SD"];
const GENRES: &[&str] = &[
    "Action",
    "Drama",
    "Komödie",
    "Thriller",
    "Dokumentation",
    "Kinder",
    "Horror",
    "Romanze",
];

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kind {
    Live,
    Movie,
    Episode,
}

/// One library entry, as both M3U and the XC API describe it.
#[derive(Debug, Clone)]
pub struct Entry {
    pub kind: Kind,
    /// The provider's stream id (series episodes: the episode id).
    pub id: u64,
    pub name: String,
    pub group: String,
    /// The provider's category id for `group`.
    pub category_id: u32,
    /// Live only: the XMLTV channel id (empty for some channels, as with real providers).
    pub epg_id: String,
    /// Live only: the channel number.
    pub number: u32,
    pub logo: String,
    /// Episodes: the series name and S/E numbers.
    pub series: Option<(String, u32, u32)>,
    pub year: Option<u32>,
}

impl Entry {
    /// The stream URL in the XC path form every provider uses (credentials in the path; redaction tests rely on it).
    pub fn url(&self) -> String {
        let base = "http://xc.example.invalid:8080";
        match self.kind {
            Kind::Live => format!("{base}/live/testuser/testpass/{}.ts", self.id),
            Kind::Movie => format!("{base}/movie/testuser/testpass/{}.mkv", self.id),
            Kind::Episode => format!("{base}/series/testuser/testpass/{}.mp4", self.id),
        }
    }
}

/// The synthetic library: `n` entries, 30 % live, 50 % movies, 20 % series episodes, in ~`n / 750` groups per kind.
pub fn library(n: usize, seed: u64) -> impl Iterator<Item = Entry> {
    let mut rng = Rng::new(seed);
    let groups_per_kind = (n / 750).clamp(3, 400);
    (0..n).map(move |i| {
        let kind = match i % 10 {
            0..=2 => Kind::Live,
            3..=7 => Kind::Movie,
            _ => Kind::Episode,
        };
        let g = rng.below(groups_per_kind);
        let country = COUNTRIES[g % COUNTRIES.len()];
        let (group, category_id) = match kind {
            Kind::Live => (
                format!("{country} | {} {g}", WORDS[g % WORDS.len()]),
                1000 + g as u32,
            ),
            Kind::Movie => (
                format!("VOD {country} | {}", GENRES[g % GENRES.len()]),
                2000 + g as u32,
            ),
            Kind::Episode => (
                format!("SERIES {country} | {}", GENRES[g % GENRES.len()]),
                3000 + g as u32,
            ),
        };
        let title = format!("{} {}", rng.pick(WORDS), rng.pick(WORDS));
        let year = 1960 + rng.below(66) as u32;
        let (name, series, year) = match kind {
            Kind::Live => (
                format!("{country} | {title}{}", rng.pick(QUALITY)),
                None,
                None,
            ),
            Kind::Movie => (
                format!("{country} | {title} ({year}){}", rng.pick(QUALITY)),
                None,
                Some(year),
            ),
            Kind::Episode => {
                let (s, e) = (1 + rng.below(8) as u32, 1 + rng.below(24) as u32);
                let show = format!("{title} {}", i % 97);
                (
                    format!("{country} | {show} S{s:02}E{e:02}"),
                    Some((show, s, e)),
                    Some(year),
                )
            }
        };
        Entry {
            kind,
            id: 100_000 + i as u64,
            epg_id: if kind == Kind::Live && i % 17 != 0 {
                format!("ch{i}.example.invalid")
            } else {
                String::new()
            },
            number: if kind == Kind::Live {
                (i / 10 * 3 + i % 10 + 1) as u32
            } else {
                0
            },
            logo: if i % 11 == 0 {
                String::new()
            } else {
                format!("http://img.example.invalid/{}.png", i % 5000)
            },
            name,
            group,
            category_id,
            series,
            year,
        }
    })
}

/// Writes the library as an extended M3U (`#EXTINF` with tvg-* attributes, `#EXTGRP` on some entries, an
/// `#EXTVLCOPT` here and there, plus a few malformed lines a parser must skip). Returns the number of entries.
pub fn write_m3u(w: &mut impl Write, n: usize, seed: u64) -> io::Result<usize> {
    writeln!(
        w,
        "#EXTM3U url-tvg=\"http://xc.example.invalid:8080/xmltv.php\""
    )?;
    let mut count = 0;
    for (i, e) in library(n, seed).enumerate() {
        let catchup = if e.kind == Kind::Live && i % 13 == 0 {
            " catchup=\"xc\" catchup-days=\"3\""
        } else {
            ""
        };
        writeln!(
            w,
            "#EXTINF:-1 tvg-id=\"{}\" tvg-name=\"{}\" tvg-logo=\"{}\" tvg-chno=\"{}\" group-title=\"{}\"{catchup},{}",
            e.epg_id, e.name, e.logo, e.number, e.group, e.name
        )?;
        if i % 50 == 0 {
            writeln!(w, "#EXTGRP:{}", e.group)?;
        }
        if i % 200 == 0 {
            writeln!(w, "#EXTVLCOPT:http-user-agent=TestAgent/1.0")?;
        }
        if i % 5000 == 4999 {
            writeln!(w, "#EXTINF:broken line without a comma")?; // malformed: logged and skipped
        }
        writeln!(w, "{}", e.url())?;
        count += 1;
    }
    Ok(count)
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Writes an XMLTV guide for `channels` channels over `days` days from `start` (Unix seconds, UTC), with programmes
/// of 30–120 min and descriptions sized so 2,000 channels × 7 days come to about 300 MB (the import budget).
/// Times carry a `+0100` offset, as many German guides do. Returns the number of programmes.
pub fn write_xmltv(
    w: &mut impl Write,
    channels: usize,
    days: u32,
    start: i64,
    seed: u64,
) -> io::Result<usize> {
    let mut rng = Rng::new(seed);
    writeln!(
        w,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv generator-info-name=\"gerdtv-testkit\">"
    )?;
    for c in 0..channels {
        writeln!(
            w,
            "  <channel id=\"ch{}.example.invalid\"><display-name>Channel {c} HD</display-name></channel>",
            c * 10 // matches the live entries' epg ids (every 10th library entry is live: 0, 10, 20 …)
        )?;
    }
    let end = start + days as i64 * 86_400;
    let mut count = 0;
    let desc_words = 120; // ≈ 900 bytes per programme in total
    for c in 0..channels {
        let mut t = start;
        while t < end {
            let len = 30 * 60 + rng.below(91) as i64 * 60;
            let title = xml_escape(&format!("{} {}", rng.pick(WORDS), rng.pick(WORDS)));
            let desc: Vec<&str> = (0..desc_words).map(|_| rng.pick(WORDS)).collect();
            writeln!(
                w,
                "  <programme start=\"{}\" stop=\"{}\" channel=\"ch{}.example.invalid\"><title lang=\"de\">{title}</title><sub-title>Folge {}</sub-title><desc lang=\"de\">{}</desc><category>{}</category></programme>",
                xmltv_time(t),
                xmltv_time(t + len),
                c * 10,
                1 + rng.below(300),
                xml_escape(&desc.join(" ")),
                rng.pick(GENRES),
            )?;
            t += len;
            count += 1;
        }
    }
    writeln!(w, "</tv>")?;
    Ok(count)
}

/// `YYYYMMDDhhmmss +0100` for a UTC timestamp (civil-from-days, so no date crate is needed here).
pub fn xmltv_time(utc: i64) -> String {
    let local = utc + 3600;
    let (days, secs) = (local.div_euclid(86_400), local.rem_euclid(86_400));
    // Howard Hinnant's days-to-civil algorithm.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!(
        "{y:04}{m:02}{d:02}{:02}{:02}{:02} +0100",
        secs / 3600,
        secs % 3600 / 60,
        secs % 60
    )
}

/// An `io::Write` that only counts bytes (for sizing checks without memory or disk).
#[derive(Default)]
pub struct Counter(pub u64);

impl Write for Counter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0 += buf.len() as u64;
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xmltv_time_is_local_with_offset() {
        assert_eq!(xmltv_time(0), "19700101010000 +0100");
        assert_eq!(xmltv_time(1_763_740_800), "20251121170000 +0100"); // 2025-11-21 16:00 UTC
    }

    #[test]
    fn library_is_deterministic_and_mixed() {
        let a: Vec<Entry> = library(1000, 7).collect();
        let b: Vec<Entry> = library(1000, 7).collect();
        assert_eq!(
            a.iter().map(|e| &e.name).collect::<Vec<_>>(),
            b.iter().map(|e| &e.name).collect::<Vec<_>>()
        );
        let live = a.iter().filter(|e| e.kind == Kind::Live).count();
        assert_eq!(live, 300);
        assert!(
            a.iter()
                .any(|e| e.name.contains('ü') || e.name.contains('ö')),
            "umlauts present"
        );
        assert!(
            a.iter().any(|e| e.name.ends_with(" 4K")),
            "quality tags present"
        );
        assert!(a.iter().all(|e| e.url().contains("example.invalid")));
    }
}
