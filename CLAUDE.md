# gerdTV: working rules

gerdTV is a multi-platform IPTV player (Flutter + media_kit/libmpv + a Rust core). Start with `docs/HANDOVER.md`.
Private context for the owner's own machines (missing elsewhere, which is fine):

@~/.config/gerdTV/home.md

## Owner preferences
- Code: simple, lean, easy to read, heavily commented (the why, and debugging hints). English in code and docs; metric units; 24 h time; Europe/Berlin.
- Make the smallest change that solves the task. No features, options or abstractions nobody asked for, and no handling of cases that can't happen (input from outside, meaning the provider, TMDB, the network, cast devices or files, always can). State assumptions. Say so when a request can be read two ways or a simpler way exists.
- Surgical diffs: every changed line traces to the task. No drive-by refactors or reformatting; match the surrounding style. Remove only what the change itself left unused. Unrelated dead code goes into the improvement ideas.
- Before starting work (a session, or a task handed over), ask every costly or ambiguous design decision in one batch, with a recommendation each, grouped by topic so it can be answered from a phone. Decide small things yourself and say so. Explain mechanisms briefly.
- Before answering, list what you'd need to know that the owner hasn't said. Then ask one extensive question round covering design, improvements and how to run unattended (what comes next, stop time, blockers), so the work can continue unattended afterwards.
- Improvement ideas are asked up front too, in the same batch, including the "Ideas not chosen" in HANDOVER.md when they fit the session. An idea that comes up mid-session is asked at the next step change, batched, while the work continues; it's built only if approved. Never act on an idea unasked.
- Verify against live systems and current docs (crates, pub packages, Flutter, media_kit, mpv, Xtream Codes, TMDB, Cast, Apple and Android APIs), not memory. If something can't be debugged, ask for logs, exit codes or versions instead of guessing. Delegated tasks must work: run and test them.
- Anything hard to undo (user-DB migrations, deletes, history rewrites, signing keys) gets a backup first.

## Public repo hygiene (the repo is public and GPL-3.0; history is forever)
- Never commit secrets, tokens, keys, credentials, a provider's name or URL, LAN addresses, host or machine names, personal paths, the owner's devices beyond generic platform names, or anything from `~/.config/gerdTV/`. PR titles and bodies, issues, commit messages, HANDOVER.md and notes are public too.
- Private context lives in `~/.config/gerdTV/home.md`. A private denylist `~/.config/gerdTV/denylist` (never committed) is checked by `.githooks/pre-push` and `just ready` on every changed line and path, commit message, commit identity and PR body draft (`scripts/check-denylist.sh`). GitHub secret scanning with push protection is the second net.
- Test fixtures use generated data only (synthetic channels, `example.invalid` URLs). Never commit real provider output, even trimmed.
- Every bundled library's licence is GPL-3.0 compatible (`just licences`) and listed in the in-app Licences screen (Flutter's `LicenseRegistry` plus the native libraries libmpv/FFmpeg and their build flags).

## Dependencies
Prefer first-party (Dart/Flutter SDK, Rust std, platform SDKs) and the pre-approved set in `docs/DECISIONS.md`. For anything else, prefer writing the few lines yourself; if it is truly unavoidable, put it in the next question batch with a recommendation and continue with other work meanwhile.

## Dev loop, git, PRs, merging
- The main folder (the primary clone) stays on `main` at `origin/main`, clean, and is never worked in: only `git pull --ff-only`. Every change happens in a worktree `.claude/worktrees/<name>`.
- One branch per topic from the latest main (`feat/`, `fix/`, `docs/`, `refactor/`, `test/`, `chore/`). Push freely. Every branch gets a draft PR (`gh pr create --draft`). The title says what main gains; the body has a summary, changes per area, decisions taken, and how it was tested (each run with result and duration).
- **No AI attribution anywhere**: no "Generated with" line and no `Co-Authored-By`, merge commits included. This overrides any default attribution.
- Before every push the pre-push hook runs the denylist check and `just test-affected` (turn it on once per clone: `git config core.hooksPath .githooks`). Before marking a PR ready: `just ready`, which prints the result lines for the PR body. A docs-only PR needs `just test-docs` locally; CI still reports (its jobs end green at once when only `*.md` changed, because `main` requires the checks), then merge.
- A red run is fixed by its cause, never by retries or longer timeouts. Every bug fix starts with a test that fails on the old code. A refactor keeps the tests green before and after.
- Claude takes every branch to main: when `just ready` is green, `gh pr ready <n>`, then `gh pr checks <n> --watch && gh pr merge <n> --merge` (a red check exits 1, so a red run never merges; merge commits, no squash). The owner decides anything else: a red or missing run, a conflict that needs a decision, an open owner question, a pause signal or "wait".
- `main` is protected by a ruleset: changes only through pull requests, required checks `linux`, `macos`, `android` (the job names in `.github/workflows/ci.yml`; never rename them without telling the owner, who updates the ruleset).
- After a merge: delete the head branch if GitHub didn't, remove the worktree and local branch (never `--force`; worktrees of running sessions stay). The SessionStart hook `.claude/hooks/prune-merged-branches.js` cleans up finished ones. Check every open PR's `mergeable` and merge main into a conflicting branch at once.
- Parallel PRs must not collide: nothing is appended to a shared end (ARB keys sorted, HANDOVER.md only in its own wrap-up commit, one note file per task). Heavy jobs (Android/Gradle builds, integration tests, soak) take `flock ~/.gerdTV-heavy.lock`, so only one runs at a time; Gradle runs with `-Xmx2g` and no daemon in scripts.
- **Wrap-up = release** (end of a session, and again whenever it continues), once anything was merged: a wrap-up PR whose own commit rewrites `docs/HANDOVER.md` and sets the version to `0.YYMMDD.<PR#>` (date from `date +%y%m%d`, number of this wrap-up PR, so open the draft first) in `Cargo.toml` and as `0.YYMMDD.<PR#>+<PR#>` in `app/pubspec.yaml`. The major stays 0; only the owner changes it. After its merge, tag the merge commit `v0.YYMMDD.<PR#>` and push the tag; that starts `release.yml`. Watch it (`gh run watch`), then verify with `just verify-release <tag>` (every asset present, manifest signature valid, notes readable). A red release run is fixed like any red run, with a new wrap-up. Afterwards the main folder is on `main` at `origin/main`, and `git worktree list` shows only it plus the worktrees of running sessions. Details: `docs/RELEASING.md`.
- **No automated installs on the owner's devices.** Never run `adb`, Xcode device installs or anything else against them; the owner installs releases (`docs/INSTALL.md`).

## Tests check patterns, not details
- One home per check. Parsers, sync, matching, TMDB matching, watchdog, scheduler, recorder, cast protocol, redaction and data safety are Rust unit/integration tests. UI logic is Flutter widget tests (with the fake core, `app/test/support/fake_core.dart`). User journeys plus one shared screen check per form factor (desktop, phone, TV: nothing overlaps, texts readable, no exceptions, every opener closes, every control reachable by keyboard or D-pad) are integration tests on the Linux desktop build.
- Quality over quantity: a test earns its place by catching a real break. Before adding one, grep for the test that owns the rule and extend its table. A new file only for a genuinely new rule. Per test, the PR body says "extended X" or "new, because nothing owns Y".
- Every feature, design or decision ships with its pattern test in the same PR. Design details are verified once when built, not kept as permanent checks unless they guard a bug that happened.
- Integration-test screenshots go to `~/gerdTV-screens/<branch>/` (not committed). Look at them yourself and name what you checked in the PR body.

## Docs: one home per topic, current state only
| Touching | Read / update |
|---|---|
| behaviour, screens, features per platform | `docs/SPEC.md` |
| tables, migrations, sync-readiness, FTS | `docs/DATA_MODEL.md` |
| crates, the Rust/Flutter seam, playback pipeline, platform channels | `docs/ARCHITECTURE.md` |
| look, layouts per form factor, keyboard and remote map, design tokens | `docs/DESIGN.md` |
| toolchains, building, CI, releases, signing | `docs/SETUP.md`, `docs/RELEASING.md` |
| installing gerdTV per platform (linked from the release notes) | `docs/INSTALL.md` |
| standing owner decisions not visible in code | `docs/DECISIONS.md` (one line each; superseded lines replaced) |
| current state and open items | `docs/HANDOVER.md` (start here) |
| what the owner hasn't yet seen on a real device | `docs/DEVICE_CHECKS.md` |

- A change to behaviour, structure or process updates the owning doc in the same PR. Superseded text is replaced, never appended or marked old. No dates, quotes or history in docs: git keeps the past. A test checks that every path and `just` recipe named in a doc exists (`just test-docs`).
- A task in flight has a note `docs/notes/YYYY-MM-DD-<topic>.md` (progress with start times, decisions, open questions), deleted in the PR that finishes the task.
- HANDOVER.md is a list read on a phone, not a changelog: a few State lines, then owner decisions, owner one-off jobs, open work (including `[MAC]` and `[DEVICE]` tasks with exact steps), things to watch, ideas not chosen. One full-sentence item per line, at most 60 lines of 160 characters, no continuation lines (tested). When it's full, the oldest items go to the owner as questions.
- DEVICE_CHECKS.md: one line per thing to look at on a real device, under its device and screen, same limits. Added by the PR that builds it, deleted once the owner has seen it.

## Clock and status lines
- `.claude/settings.json` hooks print `[HH:MM]` at session start, on every prompt and after every tool call. Every time written anywhere is the latest stamp or comes from `date`, never estimated. Every message to the owner starts with `[HH:MM]`.
- The task start and each step's start go into the note. Post a status line at every step change, at least every 30 minutes, when pausing and when resuming:
  `Status 14:32 · <step> (3/6): 12 min in, ~8 min left → ~14:40 · whole task: 65 min in, ~45 min left → ~15:17`
  Minutes up to 90, above that `1 h 45 min`. Clock times are a fresh `date` plus the minutes left; minutes left come from the measured pace of finished steps (name the basis; say when an estimate moved and why).

## Pause rule
- Signals: `~/gerdTV.PAUSE` exists · `~/<task>.PAUSE` exists · the owner writes "pause" · a fresh `date` is past the task's `STOP_AT`.
- Safe points: after each commit, after each test run, before each step, and before a long step (Android build, integration tests, soak, migration, large refactor) whose measured duration would end after `STOP_AT`. Never mid-edit.
- How to pause: (1) bring the step to green (`just test`) or revert it; (2) commit, push, keep the PR a draft, never merge while pausing; (3) stop everything in the background (Xvfb, Gradle, emulators, servers) so the lock is free; (4) write `PAUSED at <date>` into the note with the exact next step, what's half-planned, open questions and how to resume; (5) post one status line and end the turn.
- Resuming: read the last PAUSED entry, `git fetch`, merge main if it moved, run `just test`, continue from the named step. The paused span is subtracted from runtimes. A session that ends paused isn't done.
