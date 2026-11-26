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

/// The CI area map (scripts/ci-scope.sh): a change runs the areas it can break, a wrap-up's version bump and docs run
/// only the repo rules, and anything the map doesn't know runs everything. One commit per case on a fresh branch
/// of a throwaway repo; the expected areas are the ones printed `=true`.
#[test]
fn ci_scope_maps_changes_to_areas() {
    let repo = std::env::temp_dir().join(format!("gerdtv-scope-{}", std::process::id()));
    fs::create_dir_all(&repo).unwrap();
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
    let write = |rel: &str, text: &str| {
        let p = repo.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    };
    let manifest = |version: &str, dep: &str| {
        format!(
            "[workspace.package]\nversion = \"{version}\"\n\n[dependencies]\nserde = \"{dep}\"\n"
        )
    };
    git(&["init", "-q", "-b", "main"]);
    write("Cargo.toml", &manifest("0.261123.52", "1.0.1"));
    write(
        "Cargo.lock",
        "[[package]]\nname = \"gerdtv-core\"\nversion = \"0.261123.52\"\n",
    );
    write(
        "app/pubspec.yaml",
        "name: gerdtv\nversion: 0.261123.52+52\n",
    );
    git(&["add", "-A"]);
    git(&["commit", "-q", "-m", "base"]);
    let all = "rust flutter linux macos android rules";
    let app = "flutter linux macos android";
    // (files written on the branch, areas expected on)
    let bump = manifest("0.261124.60", "1.0.1");
    let lock = "[[package]]\nname = \"gerdtv-core\"\nversion = \"0.261124.60\"\n";
    let dep = manifest("0.261123.52", "1.0.2");
    let cases: Vec<(Vec<(&str, &str)>, &str)> = vec![
        (vec![("docs/SPEC.md", "x")], "rules"),
        (
            vec![
                ("Cargo.toml", &bump),
                ("Cargo.lock", lock),
                (
                    "app/pubspec.yaml",
                    "name: gerdtv\nversion: 0.261124.60+60\n",
                ),
                ("docs/HANDOVER.md", "x"),
            ],
            "rules",
        ),
        (vec![("Cargo.toml", &dep)], all),
        (vec![("crates/gerdtv-core/src/lib.rs", "x")], all),
        (vec![("app/lib/main.dart", "x")], app),
        (
            vec![("app/lib/l10n/app_en.arb", "x")],
            "flutter linux macos android rules",
        ),
        (vec![("app/linux/CMakeLists.txt", "x")], "flutter linux"),
        (vec![("app/macos/Runner/x.swift", "x")], "macos"),
        (vec![("app/ios/Runner/x.swift", "x")], "macos"),
        (vec![("app/android/app/build.gradle.kts", "x")], "android"),
        (vec![("app/rust_builder/x", "x")], all),
        (vec![("scripts/build-libmpv.sh", "x")], "rust linux"),
        (vec![(".github/workflows/ci.yml", "x")], all),
        (vec![("justfile", "x")], all),
    ];
    for (n, (files, want)) in cases.iter().enumerate() {
        git(&["checkout", "-q", "-b", &format!("case{n}"), "main"]);
        for (rel, text) in files {
            write(rel, text);
        }
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "change"]);
        let out = std::process::Command::new(repo_root().join("scripts/ci-scope.sh"))
            .arg("main")
            .current_dir(&repo)
            .env_remove("GITHUB_OUTPUT")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let got: Vec<&str> = std::str::from_utf8(&out.stdout)
            .unwrap()
            .lines()
            .filter_map(|l| l.strip_suffix("=true"))
            .collect();
        let files: Vec<&str> = files.iter().map(|f| f.0).collect();
        assert_eq!(got.join(" "), *want, "ci-scope.sh for {files:?}");
    }
    fs::remove_dir_all(&repo).unwrap();
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

/// HANDOVER.md (≤ 60 lines) and DEVICE_CHECKS.md (≤ 90) are read on a phone: lines of ≤ 160 characters, no
/// continuation lines.
#[test]
fn phone_docs_stay_within_their_limits() {
    for (doc, max) in [("docs/HANDOVER.md", 60), ("docs/DEVICE_CHECKS.md", 90)] {
        let text = read(doc);
        let lines: Vec<&str> = text.lines().collect();
        assert!(
            lines.len() <= max,
            "{doc}: {} lines, at most {max}; send the oldest items to the owner",
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

/// Android TV: Impeller stays off (its Vulkan path garbled the Shield's picture; release builds ignore a backend choice),
/// and every banner the manifest names is a wide 320 × 180 PNG rendered by `just logos` (the square icon looked lost on
/// the Google TV home).
#[test]
fn android_renders_with_skia_and_has_wide_banners() {
    let manifest = read("app/android/app/src/main/AndroidManifest.xml");
    assert!(
        manifest.contains(
            "android:name=\"io.flutter.embedding.android.EnableImpeller\"\n            android:value=\"false\""
        ),
        "AndroidManifest.xml: EnableImpeller false"
    );
    let banners: Vec<&str> = manifest
        .split("android:banner=\"@drawable/")
        .skip(1)
        .map(|rest| rest.split('"').next().unwrap())
        .collect();
    assert!(!banners.is_empty(), "the manifest names no banner");
    for name in banners {
        let path = format!("app/android/app/src/main/res/drawable-xhdpi/{name}.png");
        let png = fs::read(repo_root().join(&path)).unwrap_or_else(|e| panic!("{path}: {e}"));
        // The PNG header's IHDR chunk: width and height, big-endian, at bytes 16..24.
        let size = |at: usize| u32::from_be_bytes(png[at..at + 4].try_into().unwrap());
        assert_eq!((size(16), size(20)), (320, 180), "{path}");
    }
}

/// The start never flashes white: Android's launch and window backgrounds are gerdTV's dark ink in light and dark
/// system modes (Flutter's template is white in light mode, which the Shield uses), and so is iOS's launch screen.
#[test]
fn launch_screens_are_dark() {
    let res = "app/android/app/src/main/res";
    assert!(
        read(&format!("{res}/values/colors.xml")).contains("<color name=\"ink\">#FF12121A</color>")
    );
    for file in [
        "drawable/launch_background.xml",
        "drawable-v21/launch_background.xml",
    ] {
        assert!(
            read(&format!("{res}/{file}")).contains("@color/ink"),
            "{file}: dark background"
        );
    }
    for file in ["values/styles.xml", "values-night/styles.xml"] {
        // LaunchTheme draws launch_background (above), NormalTheme the colour itself.
        assert!(
            read(&format!("{res}/{file}"))
                .contains("<item name=\"android:windowBackground\">@color/ink</item>"),
            "{file}: NormalTheme dark"
        );
    }
    assert!(
        !read("app/ios/Runner/Base.lproj/LaunchScreen.storyboard")
            .contains("red=\"1\" green=\"1\" blue=\"1\""),
        "LaunchScreen.storyboard: no white background"
    );
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
/// cut the PRs it carried out of the next notes. A fake `gh` knows which tags have a release. A PR with several
/// commits (a session) lists their subjects under its title, without the wrap-up's version commit.
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
    let merge = |n: u32, tag: Option<&str>, commits: &[&str]| {
        git(&["checkout", "-q", "-b", &format!("pr{n}")]);
        for c in commits {
            git(&["commit", "-q", "--allow-empty", "-m", c]);
        }
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
    merge(1, Some("v0.1"), &["work 1"]); // released
    merge(2, None, &["work 2"]);
    merge(3, Some("v0.2"), &["work 3"]); // its release run failed: no release
    // The release being made: a session's PR, features as commits, the wrap-up last.
    merge(
        4,
        Some("v0.3"),
        &["Feature A", "Feature B", "Version 0.261124.4"],
    );
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
    for want in [
        "- Title 3 (#3)\n- Title 2 (#2)\n",
        "- Title 4 (#4)\n  - Feature A\n  - Feature B\n",
    ] {
        assert!(notes.contains(want), "missing {want}:\n{notes}");
    }
    assert!(
        !notes.contains("Version"),
        "the version commit is listed:\n{notes}"
    );
    assert!(
        !notes.contains("Title 1"),
        "v0.1 was released before:\n{notes}"
    );
    fs::remove_dir_all(&dir).unwrap();
}
