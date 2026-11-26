//! The user's own order in the catalogue: own groups (with their items in the user's order), own names for channels
//! and groups, and the groups' order (Settings aside, all from the long-press menus).
//!
//! Own names and the groups' order live in user tables and are written into `items` and `categories` after every
//! sync ([apply]), in its transaction: so lists, search, sorting and zapping need to know nothing about them. The
//! guide's matching asks for the provider's name ([PROVIDER_NAME]): a channel renamed "Evening" still finds its guide.
//! Own groups have category ids "custom:<id>". Removing a group or an item leaves a row marked deleted, so it stays
//! removed when an older export is imported. An item the catalogue lacks right now is left out, not forgotten.
//!
//! Debug hints: a name that comes back after an update: its item_prefs row is missing or empty. A group at the wrong
//! place: group_prefs.position counts from 0; groups without a row keep the provider's order after them.

use crate::db::{self, Hit, Kind, Sort};
use rusqlite::{Connection, OptionalExtension, Result, params};

pub const CUSTOM: &str = "custom:";

/// SQL: the provider's name of the item row `items` (its own name may be the user's).
pub const PROVIDER_NAME: &str = "coalesce((SELECT p.provider_name FROM item_prefs p WHERE p.key = items.key AND p.name <> ''), items.name)";

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// Writes the user's names and group order over what a sync just stored.
pub fn apply(conn: &Connection) -> Result<()> {
    let named: Vec<(String, String)> = conn
        .prepare_cached("SELECT key, name FROM item_prefs WHERE name <> ''")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_>>()?;
    for (key, name) in named {
        write_name(conn, &key, &name)?;
    }
    conn.execute(
        "UPDATE categories SET name = (SELECT g.name FROM group_prefs g
            WHERE g.kind = categories.kind AND g.category = categories.id)
         WHERE EXISTS (SELECT 1 FROM group_prefs g
            WHERE g.kind = categories.kind AND g.category = categories.id AND g.name <> '')",
        [],
    )?;
    // Ordered groups before all others, whose provider positions start at 0.
    conn.execute(
        "UPDATE categories SET position = (SELECT g.position - 1000000 FROM group_prefs g
            WHERE g.kind = categories.kind AND g.category = categories.id)
         WHERE EXISTS (SELECT 1 FROM group_prefs g
            WHERE g.kind = categories.kind AND g.category = categories.id AND g.position IS NOT NULL)",
        [],
    )?;
    Ok(())
}

/// Puts `name` on an item and its search index, remembering the provider's name it replaces.
fn write_name(conn: &Connection, key: &str, name: &str) -> Result<()> {
    let Some(current) = conn
        .query_row("SELECT name FROM items WHERE key = ?1", [key], |r| {
            r.get::<_, String>(0)
        })
        .optional()?
    else {
        return Ok(());
    };
    if current != name {
        conn.execute(
            "UPDATE item_prefs SET provider_name = ?2 WHERE key = ?1 AND name <> ''",
            params![key, current],
        )?;
        db::rename_item(conn, key, name)?;
    }
    Ok(())
}

/// Names an item; empty: the provider's name again.
pub fn rename_item(conn: &mut Connection, key: &str, name: &str) -> Result<()> {
    let name = name.trim();
    let tx = conn.transaction()?;
    let provider: Option<String> = tx
        .query_row(
            &format!("SELECT {PROVIDER_NAME} FROM items WHERE key = ?1"),
            [key],
            |r| r.get(0),
        )
        .optional()?;
    let Some(provider) = provider else {
        return Ok(()); // gone from the catalogue
    };
    tx.execute(
        "INSERT INTO item_prefs (key, name, provider_name, updated_at) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (key) DO UPDATE SET name = ?2, provider_name = ?3, updated_at = ?4",
        params![key, name, provider, now()],
    )?;
    db::rename_item(&tx, key, if name.is_empty() { &provider } else { name })?;
    tx.commit()
}

/// Names a group of the provider's or one of the user's. Empty: the provider's name again, from the next sync.
pub fn rename_group(conn: &Connection, kind: Kind, category: &str, name: &str) -> Result<()> {
    let name = name.trim();
    if let Some(id) = category.strip_prefix(CUSTOM) {
        if !name.is_empty() {
            conn.execute(
                "UPDATE custom_groups SET name = ?2, updated_at = ?3 WHERE id = ?1",
                params![id, name, now()],
            )?;
        }
        return Ok(());
    }
    conn.execute(
        "INSERT INTO group_prefs (kind, category, name, updated_at) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT (kind, category) DO UPDATE SET name = ?3, updated_at = ?4",
        params![kind as i64, category, name, now()],
    )?;
    apply(conn)
}

/// Stores the groups' order as shown (`ids` top to bottom; the user's own ones always come first).
pub fn set_group_order(conn: &mut Connection, kind: Kind, ids: &[String]) -> Result<()> {
    let tx = conn.transaction()?;
    for (i, id) in ids.iter().enumerate() {
        match id.strip_prefix(CUSTOM) {
            Some(own) => tx.execute(
                "UPDATE custom_groups SET position = ?2, updated_at = ?3 WHERE id = ?1",
                params![own, i as i64, now()],
            )?,
            None => tx.execute(
                "INSERT INTO group_prefs (kind, category, position, updated_at) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (kind, category) DO UPDATE SET position = ?3, updated_at = ?4",
                params![kind as i64, id, i as i64, now()],
            )?,
        };
    }
    apply(&tx)?;
    tx.commit()
}

/// A new, empty group; its category id.
pub fn create(conn: &Connection, kind: Kind, name: &str) -> Result<String> {
    // Random, so the same group made on two devices stays two groups when their data is merged.
    let id: String = conn.query_row("SELECT lower(hex(randomblob(8)))", [], |r| r.get(0))?;
    conn.execute(
        "INSERT INTO custom_groups (id, kind, name, position, deleted, updated_at)
         VALUES (?1, ?2, ?3, (SELECT coalesce(max(position) + 1, 0) FROM custom_groups), 0, ?4)",
        params![id, kind as i64, name.trim(), now()],
    )?;
    Ok(format!("{CUSTOM}{id}"))
}

pub fn delete(conn: &Connection, category: &str) -> Result<()> {
    conn.execute(
        "UPDATE custom_groups SET deleted = 1, updated_at = ?2 WHERE id = ?1",
        params![category.trim_start_matches(CUSTOM), now()],
    )?;
    Ok(())
}

/// The user's groups of a kind with how many items each shows; empty ones too (they were just made).
pub fn list(conn: &Connection, kind: Kind) -> Result<Vec<(String, String, usize)>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT g.id, g.name, (SELECT count(*) FROM custom_group_items c JOIN items i ON i.key = c.item_key
            WHERE c.group_id = g.id AND c.deleted = 0 {})
         FROM custom_groups g WHERE g.kind = ?1 AND g.deleted = 0 ORDER BY g.position, g.id",
        db::visible_and(conn, "i")?
    ))?;
    let rows = st.query_map([kind as i64], |r| {
        let id: String = r.get(0)?;
        Ok((
            format!("{CUSTOM}{id}"),
            r.get(1)?,
            r.get::<_, i64>(2)? as usize,
        ))
    })?;
    rows.collect()
}

/// Adds an item at the end of a group (once), or removes it.
pub fn set_member(conn: &Connection, category: &str, key: &str, member: bool) -> Result<()> {
    conn.execute(
        "INSERT INTO custom_group_items (group_id, item_key, position, deleted, updated_at)
         VALUES (?1, ?2, (SELECT coalesce(max(position) + 1, 0) FROM custom_group_items WHERE group_id = ?1), ?3, ?4)
         ON CONFLICT (group_id, item_key) DO UPDATE SET deleted = ?3, updated_at = ?4",
        params![category.trim_start_matches(CUSTOM), key, !member, now()],
    )?;
    Ok(())
}

/// Stores the order of a group's items.
pub fn set_item_order(conn: &mut Connection, category: &str, keys: &[String]) -> Result<()> {
    let tx = conn.transaction()?;
    for (i, key) in keys.iter().enumerate() {
        tx.execute(
            "UPDATE custom_group_items SET position = ?3, updated_at = ?4 WHERE group_id = ?1 AND item_key = ?2",
            params![category.trim_start_matches(CUSTOM), key, i as i64, now()],
        )?;
    }
    tx.commit()
}

/// One page of a group's items: in the user's order, unless the section is sorted otherwise.
pub fn items(
    conn: &Connection,
    category: &str,
    sort: Sort,
    limit: usize,
    offset: usize,
) -> Result<Vec<Hit>> {
    let order = match sort {
        Sort::Provider => "c.position, i.position".to_string(),
        other => other.items_sql("i."),
    };
    let mut st = conn.prepare_cached(&format!(
        "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days
         FROM custom_group_items c JOIN items i ON i.key = c.item_key
         WHERE c.group_id = ?1 AND c.deleted = 0 {} ORDER BY {order} LIMIT ?2 OFFSET ?3",
        db::visible_and(conn, "i")?
    ))?;
    let rows = st.query_map(
        params![
            category.trim_start_matches(CUSTOM),
            limit as i64,
            offset as i64
        ],
        |r| {
            Ok(Hit {
                key: r.get(0)?,
                kind: Kind::from_i64(r.get(1)?),
                name: r.get(2)?,
                category: r.get(3)?,
                logo: r.get(4)?,
                number: r.get(5)?,
                archive_days: r.get(6)?,
                group: String::new(),
            })
        },
    )?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIST: &str = "#EXTM3U
#EXTINF:-1 group-title=\"News\",DE | Eins HD\nhttp://h.example.invalid/live/a/b/1.ts
#EXTINF:-1 group-title=\"News\",Zwei\nhttp://h.example.invalid/live/a/b/2.ts
#EXTINF:-1 group-title=\"Sport\",Drei\nhttp://h.example.invalid/live/a/b/3.ts
";

    fn sync(c: &mut Connection) {
        db::import_m3u(c, LIST.as_bytes(), &["a", "b"]).unwrap();
    }

    fn database() -> Connection {
        let mut c = db::open(std::path::Path::new(":memory:")).unwrap();
        sync(&mut c);
        c
    }

    fn keys(hits: Vec<Hit>) -> Vec<String> {
        hits.into_iter().map(|h| h.key).collect()
    }

    fn name(c: &Connection, sql: &str) -> String {
        c.query_row(sql, [], |r| r.get(0)).unwrap()
    }

    /// New, because nothing owns the user's own groups: members keep the user's order, hidden groups' items stay out.
    #[test]
    fn own_groups_hold_items_in_the_users_order() {
        let mut c = database();
        let g = create(&c, Kind::Live, " Mine ").unwrap();
        for k in ["live:1", "live:3", "live:3", "live:gone"] {
            set_member(&c, &g, k, true).unwrap();
        }
        assert_eq!(
            list(&c, Kind::Live).unwrap(),
            [(g.clone(), "Mine".into(), 2)]
        );
        assert!(list(&c, Kind::Movie).unwrap().is_empty());
        set_item_order(&mut c, &g, &["live:3".into(), "live:1".into()]).unwrap();
        sync(&mut c);
        let page = |c: &Connection, s| keys(items(c, &g, s, 10, 0).unwrap());
        assert_eq!(page(&c, Sort::Provider), ["live:3", "live:1"]);
        assert_eq!(page(&c, Sort::NameDesc), ["live:1", "live:3"]);
        db::set_group_hidden(&c, Kind::Live, "Sport", true).unwrap();
        assert_eq!(page(&c, Sort::Provider), ["live:1"]);
        set_member(&c, &g, "live:1", false).unwrap();
        assert!(page(&c, Sort::Provider).is_empty());
        delete(&c, &g).unwrap();
        assert!(list(&c, Kind::Live).unwrap().is_empty());
    }

    /// Own names survive a sync, are found by search, and leave the provider's name to the guide and to undoing.
    #[test]
    fn own_names_survive_a_sync_and_can_be_undone() {
        let mut c = database();
        rename_item(&mut c, "live:1", "Abend").unwrap();
        rename_item(&mut c, "live:1", "Abendprogramm").unwrap();
        rename_group(&c, Kind::Live, "News", "Nachrichten").unwrap();
        for _ in 0..2 {
            assert_eq!(
                name(&c, "SELECT name FROM items WHERE key = 'live:1'"),
                "Abendprogramm"
            );
            assert_eq!(
                name(&c, "SELECT name FROM categories WHERE id = 'News'"),
                "Nachrichten"
            );
            let provider = format!("SELECT {PROVIDER_NAME} FROM items WHERE key = 'live:1'");
            assert_eq!(name(&c, &provider), "DE | Eins HD");
            let found = |q| keys(db::search(&c, q, &[], None, 5, 0).unwrap());
            assert_eq!(found("abendpro"), ["live:1"]);
            assert!(found("eins").is_empty());
            sync(&mut c);
        }
        rename_item(&mut c, "live:1", "").unwrap();
        assert_eq!(
            name(&c, "SELECT name FROM items WHERE key = 'live:1'"),
            "DE | Eins HD"
        );
        sync(&mut c);
        assert_eq!(
            name(&c, "SELECT name FROM items WHERE key = 'live:1'"),
            "DE | Eins HD"
        );
        rename_item(&mut c, "live:gone", "x").unwrap();
    }

    #[test]
    fn the_groups_order_survives_a_sync() {
        let mut c = database();
        set_group_order(&mut c, Kind::Live, &["Sport".into(), "News".into()]).unwrap();
        for _ in 0..2 {
            let first = "SELECT id FROM categories c WHERE kind = 0 ORDER BY c.position LIMIT 1";
            assert_eq!(name(&c, first), "Sport");
            sync(&mut c);
        }
    }
}
