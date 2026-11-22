# Settings categories and search, logo mockups

Plan: owner-approved (categories with master-detail and search; four logos drawn in code, picked in Settings, switching
the launcher icon; the choice stored app-wide in the core).

## Progress
- 16:25 start step 1/4: settings categories, master-detail, search (PR 1).
- 16:48 step 1 green locally (widget tests, journey, screen check on phone/desktop/TV); PR #28 opened.
- 16:50 start step 2/4: logo mockups, app.json, picker, launcher icon switch (PR #29).
- 17:15 step 2 green locally (flutter test, journey, screen check); PR #29 opened.
- 17:16 start step 3/4: `just ready` for #28; bench red twice from load of parallel sessions (no Rust change in #28).
- 17:24 Android debug APK for #29 built (194 s), merged manifest has the four aliases; waiting for a quiet machine.
- 18:10 bench green for #28 (373 s); main moved (#26, #27): merged into both branches.
- 18:25 macOS CI found Settings beside the rail falling back to the phone layout (800 px window): regression test + fix.
- 18:41 #28 local gates all green, marked ready; #29 gates green up to integration.
- 18:51 integration red on #29 and CI red on #28, #29 and #31: main's guide grid, phone, "7 CH | Classic Nachrichten"
  overlaps "Sport Größe" (a cell starting before the visible window, title under the fixed channel column; depends on
  the clock). Not from these PRs; #31's session hits it too.

PAUSED at 2026-11-22 18:52: blocked on the guide-grid overlap in main (owner decision: who fixes it; #31 is affected too).
Next step: once main has the fix, merge main into feat/settings-categories, push, watch `gh pr checks 28` and merge; then
merge main into feat/app-logos, rerun `just test-integration`, `just build-linux` and `just bench` (quiet machine), mark
#29 ready, merge; then the wrap-up release. Nothing half-built.

## Decisions
- App-wide store is `app.json` beside `profiles.json` (atomic rewrite), not a new SQLite table: no app-level DB exists.
- Guide settings split into separate entry widgets; they share state through the session's notifications, no extra notifier.
- Android TV banner set per activity alias (not listed in the alias docs, but aapt2 keeps it); Shield device check.
- macOS switches only the Dock icon while running; a changed bundle icon would break the code signature.

## Open questions
- Default logo: the gTV wordmark, as the owner asked for gerdTV-aware logos.
- Bench gate vs parallel sessions' builds outside the heavy lock: owner decision.
