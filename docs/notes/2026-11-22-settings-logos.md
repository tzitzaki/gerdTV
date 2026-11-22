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

## Decisions
- App-wide store is `app.json` beside `profiles.json` (atomic rewrite), not a new SQLite table: no app-level DB exists.
- Guide settings split into separate entry widgets; they share state through the session's notifications, no extra notifier.
- Android TV banner set per activity alias (not listed in the alias docs, but aapt2 keeps it); Shield device check.
- macOS switches only the Dock icon while running; a changed bundle icon would break the code signature.

## Open questions
- Which of the four logos is the default (preview: app/build/logos/preview.png after `just logos`); "screen" until then.
- Bench gate vs parallel sessions' builds outside the heavy lock: owner decision.
