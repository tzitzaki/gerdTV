//! Export and import of a profile's user data (docs/SPEC.md, "Settings"): favourites, recently watched, continue
//! watching, hidden groups, profile settings, per-channel stream preferences, the manual guide mapping, reminders and
//! recent searches, as one JSON file. No secrets (they never were in the database) and no catalogue: the provider
//! sends that again.
//!
//! Import merges row by row on each table's key: a row only replaces one whose `updated_at` is older, so importing an
//! old file never undoes newer changes, and a later home hub can sync the same way (docs/DATA_MODEL.md).
//!
//! Debugging an import that "did nothing": the file's rows were older than the device's; compare `updated_at`.

use rusqlite::{Connection, types::Value};
use serde_json::{Map, Value as Json, json};

/// The user tables and their key columns. Every one has `updated_at`.
const TABLES: &[(&str, &[&str])] = &[
    ("favourites", &["key"]),
    ("recents", &["key"]),
    ("resume", &["key"]),
    ("hidden_groups", &["kind", "category"]),
    ("settings", &["key"]),
    ("stream_prefs", &["key"]),
    ("epg_map", &["item_key"]),
    ("reminders", &["item_key", "start"]),
    ("search_history", &["section", "query"]),
];

/// Identifies the file; `version` changes only if the layout does.
const FORMAT: &str = "gerdtv-userdata";
const VERSION: i64 = 1;

#[derive(Debug, thiserror::Error)]
pub enum UserDataError {
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("not a gerdTV user data file: {0}")]
    Format(String),
}

pub type Result<T> = std::result::Result<T, UserDataError>;

fn to_json(v: Value) -> Json {
    match v {
        Value::Null => Json::Null,
        Value::Integer(i) => json!(i),
        Value::Real(f) => json!(f),
        Value::Text(s) => json!(s),
        Value::Blob(_) => Json::Null, // no user table has blobs
    }
}

fn from_json(v: &Json) -> Value {
    match v {
        Json::Number(n) if n.is_i64() => Value::Integer(n.as_i64().unwrap()),
        Json::Number(n) => Value::Real(n.as_f64().unwrap_or(0.0)),
        Json::String(s) => Value::Text(s.clone()),
        Json::Bool(b) => Value::Integer(*b as i64),
        _ => Value::Null,
    }
}

/// Every user table as JSON: `{"format", "version", "tables": {name: [row objects]}}`.
pub fn export(conn: &Connection) -> Result<String> {
    let mut tables = Map::new();
    for (table, _) in TABLES {
        let mut st = conn.prepare(&format!("SELECT * FROM {table}"))?;
        let cols: Vec<String> = st.column_names().map(|c| c.to_string()).collect();
        let rows = st.query_map([], |r| {
            let mut o = Map::new();
            for (i, c) in cols.iter().enumerate() {
                o.insert(c.clone(), to_json(r.get::<_, Value>(i)?));
            }
            Ok(Json::Object(o))
        })?;
        tables.insert(
            table.to_string(),
            Json::Array(rows.collect::<rusqlite::Result<_>>()?),
        );
    }
    Ok(serde_json::to_string_pretty(&json!({
        "format": FORMAT,
        "version": VERSION,
        "tables": tables,
    }))
    .expect("JSON values always serialise"))
}

/// Merges an exported file into the profile; returns how many rows were added or replaced. Unknown tables and
/// columns are skipped (a file from a newer version), so is a row without its key columns.
pub fn import(conn: &mut Connection, text: &str) -> Result<usize> {
    let doc: Json = serde_json::from_str(text).map_err(|e| UserDataError::Format(e.to_string()))?;
    if doc["format"] != FORMAT {
        return Err(UserDataError::Format("missing format marker".into()));
    }
    let tx = conn.transaction()?;
    let mut changed = 0;
    for (table, keys) in TABLES {
        let Some(rows) = doc["tables"][table].as_array() else {
            continue;
        };
        let known: Vec<String> = tx
            .prepare(&format!("SELECT * FROM {table} LIMIT 0"))?
            .column_names()
            .map(|c| c.to_string())
            .collect();
        for row in rows {
            let Some(obj) = row.as_object() else { continue };
            let cols: Vec<&String> = known.iter().filter(|c| obj.contains_key(*c)).collect();
            if !keys.iter().all(|k| obj.contains_key(*k)) || !obj.contains_key("updated_at") {
                continue;
            }
            let names = cols
                .iter()
                .map(|c| c.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            let marks = (1..=cols.len())
                .map(|i| format!("?{i}"))
                .collect::<Vec<_>>()
                .join(", ");
            let sets = cols
                .iter()
                .filter(|c| !keys.contains(&c.as_str()))
                .map(|c| format!("{c} = excluded.{c}"))
                .collect::<Vec<_>>()
                .join(", ");
            // Newer wins: an older imported row leaves the device's row as it is.
            let sql = format!(
                "INSERT INTO {table} ({names}) VALUES ({marks})
                 ON CONFLICT ({}) DO UPDATE SET {sets} WHERE excluded.updated_at > {table}.updated_at",
                keys.join(", ")
            );
            let values: Vec<Value> = cols.iter().map(|c| from_json(&obj[c.as_str()])).collect();
            changed += tx.execute(&sql, rusqlite::params_from_iter(values))?;
        }
    }
    tx.commit()?;
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db;
    use std::path::Path;

    fn exec(c: &Connection, sql: &str) {
        c.execute_batch(sql).unwrap();
    }

    #[test]
    fn round_trip_merges_newer_rows_only() {
        let a = db::open(Path::new(":memory:")).unwrap();
        exec(
            &a,
            "INSERT INTO favourites VALUES ('live:1', 100), ('live:2', 100);
                  INSERT INTO hidden_groups VALUES (0, 'Adult', 100);
                  INSERT INTO settings VALUES ('buffer', 'smooth', 100);
                  INSERT INTO resume VALUES ('movie:5', 600, 6000, 100);",
        );
        let file = export(&a).unwrap();
        assert!(!file.contains("password") && file.contains("\"format\": \"gerdtv-userdata\""));

        let mut b = db::open(Path::new(":memory:")).unwrap();
        exec(&b, "INSERT INTO settings VALUES ('buffer', 'fast', 200);"); // newer on the device
        exec(&b, "INSERT INTO resume VALUES ('movie:5', 60, 6000, 50);"); // older on the device
        let changed = import(&mut b, &file).unwrap();
        assert_eq!(
            changed, 4,
            "2 favourites, 1 hidden group, the older resume row; not the newer setting"
        );
        let buffer: String = b
            .query_row("SELECT value FROM settings WHERE key = 'buffer'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(buffer, "fast");
        let pos: i64 = b
            .query_row(
                "SELECT position FROM resume WHERE key = 'movie:5'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(pos, 600);
        // Importing the same file again changes nothing.
        assert_eq!(import(&mut b, &file).unwrap(), 0);
    }

    #[test]
    fn rejects_other_files_and_skips_unknown_parts() {
        let mut c = db::open(Path::new(":memory:")).unwrap();
        assert!(import(&mut c, "{\"tables\": {}}").is_err());
        assert!(import(&mut c, "not json").is_err());
        let newer = r#"{"format": "gerdtv-userdata", "version": 2, "tables": {
            "favourites": [{"key": "live:9", "updated_at": 5, "colour": "red"}, {"updated_at": 5}],
            "wishlist": [{"key": "x", "updated_at": 1}]}}"#;
        assert_eq!(import(&mut c, newer).unwrap(), 1);
    }
}
