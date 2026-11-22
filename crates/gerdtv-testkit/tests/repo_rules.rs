//! Rules about the repository itself (CLAUDE.md). Each test owns one rule; extend its table rather than adding files.
//! Run alone with `just test-docs`. A failure message names the file and what to change.

use gerdtv_testkit::repo_root;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

fn read(rel: &str) -> String {
    fs::read_to_string(repo_root().join(rel)).unwrap_or_else(|e| panic!("{rel}: {e}"))
}

fn files_in(rel_dir: &str, ext: &str) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(repo_root().join(rel_dir))
        .unwrap_or_else(|e| panic!("{rel_dir}: {e}"))
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|x| x == ext))
        .collect();
    v.sort();
    v
}

fn name(p: &Path) -> String {
    p.strip_prefix(repo_root())
        .unwrap_or(p)
        .display()
        .to_string()
}

/// Workflows: only GitHub's free standard runners, only GitHub-owned actions pinned by full commit SHA,
/// never `pull_request_target`, and a default read-only token (CLAUDE.md "CI"; docs/SETUP.md "CI").
#[test]
fn workflows_use_standard_runners_and_pinned_github_actions() {
    let workflows = files_in(".github/workflows", "yml");
    assert!(!workflows.is_empty(), "no workflows found");
    for wf in workflows {
        let text = fs::read_to_string(&wf).unwrap();
        let wf = name(&wf);
        assert!(
            !text.contains("pull_request_target"),
            "{wf}: pull_request_target is not allowed"
        );
        assert!(
            text.lines().any(|l| l == "permissions:"),
            "{wf}: needs a top-level `permissions:` block"
        );
        for (n, line) in text.lines().enumerate() {
            let line = line.trim();
            if let Some(runner) = line.strip_prefix("runs-on:") {
                let runner = runner.trim();
                assert!(
                    runner == "ubuntu-latest" || runner == "macos-latest",
                    "{wf}:{}: runs-on {runner:?}; only ubuntu-latest or macos-latest (free standard runners)",
                    n + 1
                );
            }
            if let Some(action) = line.trim_start_matches("- ").strip_prefix("uses:") {
                let action = action.split('#').next().unwrap().trim();
                let (repo, sha) = action.split_once('@').unwrap_or((action, ""));
                assert!(
                    repo.starts_with("actions/"),
                    "{wf}:{}: {repo} is not a GitHub-owned action",
                    n + 1
                );
                assert!(
                    sha.len() == 40 && sha.chars().all(|c| c.is_ascii_hexdigit()),
                    "{wf}:{}: {repo} must be pinned by a full commit SHA",
                    n + 1
                );
            }
        }
    }
}

/// The required checks of the `main` ruleset are the ci.yml job names; renaming one blocks every merge.
#[test]
fn ci_keeps_the_required_job_names() {
    let ci = read(".github/workflows/ci.yml");
    for job in ["linux", "macos", "android"] {
        assert!(
            ci.contains(&format!("\n  {job}:\n")),
            "ci.yml: job `{job}` is a required check; keep its name"
        );
    }
}

/// Every repo path and `just` recipe a doc names exists (docs stay current; CLAUDE.md "Docs").
/// A backticked token counts as a path when its first segment exists at the repo root (so `origin/main` or
/// `~/…` aren't checked); tokens with placeholders (`<`, `*`, `{`, spaces) are skipped.
#[test]
fn docs_name_only_existing_paths_and_recipes() {
    let root = repo_root();
    let recipes: BTreeSet<String> = read("justfile")
        .lines()
        .filter(|l| {
            l.chars().next().is_some_and(|c| c.is_ascii_lowercase())
                && l.contains(':')
                && !l.contains(":=")
        })
        .map(|l| l.split([' ', ':']).next().unwrap().to_string())
        .collect();
    let mut docs = files_in("docs", "md");
    docs.extend([root.join("CLAUDE.md"), root.join("README.md")]);
    let mut problems = vec![];
    for doc in docs {
        let text = fs::read_to_string(&doc).unwrap();
        for (i, token) in text.split('`').enumerate() {
            if i % 2 == 0 || token.is_empty() || token.contains(['\n']) {
                continue;
            }
            if let Some(rest) = token.strip_prefix("just ") {
                let recipe = rest.split_whitespace().next().unwrap_or("");
                if !recipes.contains(recipe) {
                    problems.push(format!(
                        "{}: `{token}`: no recipe `{recipe}` in justfile",
                        name(&doc)
                    ));
                }
                continue;
            }
            if token.contains(['<', '*', '{', ' ', '$'])
                || token.starts_with(['~', '/', '-', '.'])
                    && !token.starts_with(".git")
                    && !token.starts_with(".claude")
            {
                continue;
            }
            let path = token.trim_end_matches('/');
            let first = path.split('/').next().unwrap();
            if root.join(first).exists() && !root.join(path).exists() {
                problems.push(format!("{}: `{token}` does not exist", name(&doc)));
            }
        }
    }
    assert!(
        problems.is_empty(),
        "stale doc references:\n{}",
        problems.join("\n")
    );
}

/// HANDOVER.md and DEVICE_CHECKS.md are read on a phone: ≤ 60 lines of ≤ 160 characters, no continuation lines.
#[test]
fn phone_docs_stay_within_their_limits() {
    for doc in ["docs/HANDOVER.md", "docs/DEVICE_CHECKS.md"] {
        let text = read(doc);
        let lines: Vec<&str> = text.lines().collect();
        assert!(
            lines.len() <= 60,
            "{doc}: {} lines, at most 60; send the oldest items to the owner",
            lines.len()
        );
        for (n, line) in lines.iter().enumerate() {
            assert!(
                line.chars().count() <= 160,
                "{doc}:{}: longer than 160 characters",
                n + 1
            );
            assert!(
                line.is_empty() || !line.starts_with([' ', '\t']),
                "{doc}:{}: continuation line; one full-sentence item per line",
                n + 1
            );
        }
    }
}

/// The ARB files share every key, in sorted order (parallel PRs never append to a shared end), and the app's name
/// is spelled "gerdTV" in every user-visible string.
#[test]
fn arb_files_match_and_are_sorted() {
    let arbs = files_in("app/lib/l10n", "arb");
    assert!(arbs.len() >= 2, "expected app_en.arb and app_de.arb");
    let keys_of = |p: &PathBuf| -> Vec<String> {
        let v: serde_json::Value = serde_json::from_str(&fs::read_to_string(p).unwrap()).unwrap();
        let obj = v.as_object().unwrap();
        for (k, val) in obj {
            if let Some(s) = val.as_str() {
                assert!(
                    !s.to_lowercase().contains("gerdtv") || s.contains("gerdTV"),
                    "{}: `{k}` must spell the name gerdTV",
                    name(p)
                );
            }
        }
        // serde_json keeps keys sorted, so read the order from the text itself.
        let text = fs::read_to_string(p).unwrap();
        text.lines()
            .filter_map(|l| {
                l.trim()
                    .strip_prefix('"')
                    .and_then(|r| r.split_once('"'))
                    .map(|(k, _)| k.to_string())
            })
            .filter(|k| !k.starts_with('@') && obj.contains_key(k))
            .collect()
    };
    let reference = keys_of(&arbs[0]);
    let mut sorted = reference.clone();
    sorted.sort();
    assert_eq!(reference, sorted, "{}: keys must be sorted", name(&arbs[0]));
    for arb in &arbs[1..] {
        assert_eq!(
            keys_of(arb),
            reference,
            "{}: keys must match {} in the same order",
            name(arb),
            name(&arbs[0])
        );
    }
}

/// Every platform shows the exact name "gerdTV" (lowercase `gerdtv` only for ids and binaries).
#[test]
fn platforms_show_the_name_gerdtv() {
    let cases = [
        (
            "app/android/app/src/main/AndroidManifest.xml",
            "android:label=\"gerdTV\"",
        ),
        (
            "app/macos/Runner/Configs/AppInfo.xcconfig",
            "PRODUCT_NAME = gerdTV",
        ),
        (
            "app/ios/Runner/Info.plist",
            "<key>CFBundleDisplayName</key>\n\t<string>gerdTV</string>",
        ),
        (
            "app/ios/Runner/Info.plist",
            "<key>CFBundleName</key>\n\t<string>gerdTV</string>",
        ),
        (
            "app/linux/runner/my_application.cc",
            "gtk_window_set_title(window, \"gerdTV\")",
        ),
    ];
    for (file, expected) in cases {
        assert!(
            read(file).contains(expected),
            "{file}: expected `{expected}`"
        );
    }
}

/// The denylist check (CLAUDE.md "Public repo hygiene") refuses what it cannot check: a base it can't resolve or an
/// extra file it can't read must fail, never print "clean". A probe pattern stands in for the private list.
#[test]
fn denylist_check_fails_closed() {
    let dir = std::env::temp_dir().join(format!("gerdtv-denylist-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let list = dir.join("denylist");
    // Assembled at run time: written out literally, it would sit in this file's diff and match itself.
    let probe = ["zz", "denylist", "probe", "zz"].join("-");
    fs::write(&list, format!("{probe}\n")).unwrap();
    let hit = dir.join("hit.md");
    fs::write(&hit, format!("a body naming {}\n", probe.to_uppercase())).unwrap();
    let ok = dir.join("ok.md");
    fs::write(&ok, "a harmless body\n").unwrap();
    let missing = dir.join("missing.md");
    let run = |args: &[&str]| {
        std::process::Command::new(repo_root().join("scripts/check-denylist.sh"))
            .args(args)
            .current_dir(repo_root())
            .env("GERDTV_DENYLIST", &list)
            .output()
            .unwrap()
    };
    let s = |p: &Path| p.display().to_string();
    // (arguments, should pass)
    let cases: Vec<(Vec<String>, bool)> = vec![
        (vec!["HEAD".into(), s(&ok)], true),
        (vec!["HEAD".into(), s(&hit)], false),
        (vec!["--file".into(), s(&ok)], false),
        (vec!["no-such-ref".into()], false),
        (vec!["HEAD".into(), s(&missing)], false),
    ];
    for (args, pass) in cases {
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let out = run(&args);
        assert_eq!(
            out.status.success(),
            pass,
            "check-denylist.sh {args:?}: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    fs::remove_dir_all(&dir).unwrap();
}

/// Release notes start at the previous *published* release: a tag whose release run failed (no release) must not
/// cut the PRs it carried out of the next notes. A fake `gh` knows which tags have a release.
#[test]
fn release_notes_skip_tags_without_a_release() {
    let dir = std::env::temp_dir().join(format!("gerdtv-notes-{}", std::process::id()));
    let repo = dir.join("repo");
    let bin = dir.join("bin");
    fs::create_dir_all(&repo).unwrap();
    fs::create_dir_all(&bin).unwrap();
    // `gh release view <tag>` succeeds only for v0.1.
    let gh = bin.join("gh");
    fs::write(&gh, "#!/bin/sh\n[ \"$1 $2 $3\" = \"release view v0.1\" ]\n").unwrap();
    fs::set_permissions(&gh, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let git = |args: &[&str]| {
        let ok = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
            .args(args)
            .current_dir(&repo)
            .status()
            .unwrap()
            .success();
        assert!(ok, "git {args:?}");
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["commit", "-q", "--allow-empty", "-m", "start"]);
    // Each "PR" is a side branch merged with GitHub's message: subject, blank line, PR title.
    let merge = |n: u32, tag: Option<&str>| {
        git(&["checkout", "-q", "-b", &format!("pr{n}")]);
        git(&["commit", "-q", "--allow-empty", "-m", &format!("work {n}")]);
        git(&["checkout", "-q", "main"]);
        git(&[
            "merge",
            "-q",
            "--no-ff",
            &format!("pr{n}"),
            "-m",
            &format!("Merge pull request #{n} from x/pr{n}"),
            "-m",
            &format!("Title {n}"),
        ]);
        if let Some(t) = tag {
            git(&["tag", t]);
        }
    };
    merge(1, Some("v0.1")); // released
    merge(2, None);
    merge(3, Some("v0.2")); // its release run failed: no release
    merge(4, Some("v0.3")); // the release being made
    let out = std::process::Command::new(repo_root().join("scripts/release-notes.sh"))
        .arg("v0.3")
        .current_dir(&repo)
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .output()
        .unwrap();
    let notes = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{notes}{}",
        String::from_utf8_lossy(&out.stderr)
    );
    for want in ["Title 2 (#2)", "Title 3 (#3)", "Title 4 (#4)"] {
        assert!(notes.contains(want), "missing {want}:\n{notes}");
    }
    assert!(
        !notes.contains("Title 1"),
        "v0.1 was released before:\n{notes}"
    );
    fs::remove_dir_all(&dir).unwrap();
}
