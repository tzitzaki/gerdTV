# Settings categories and search, logo mockups

Plan: owner-approved (categories with master-detail and search; four logos drawn in code, picked in Settings, switching
the launcher icon; the choice stored app-wide in the core).

## Progress
- 16:25 start step 1/4: settings categories, master-detail, search (PR 1).
- 16:48 step 1 green locally (widget tests, journey, screen check on phone/desktop/TV); PR opened.

## Decisions
- App-wide store is `app.json` beside `profiles.json` (atomic rewrite), not a new SQLite table: no app-level DB exists.
- Guide settings split into separate entry widgets; they share state through the session's notifications, no extra notifier.

## Open questions
- Which of the four logos is the default (preview sheet goes to the owner in step 2).
