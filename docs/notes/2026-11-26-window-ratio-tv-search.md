# Window ratio and TV search

Task start 21:11. Branch: the cloud session's assigned branch.

## Steps
1. TV search by category (channels, Live now, Upcoming, Show earlier, group chips): started 21:12, committed 21:21.
2. Window follows the picture's aspect ratio (two remembered sizes, mini player ratio): started 21:21.
3. CI rule (PR only when ready) in CLAUDE.md and DECISIONS.md.
4. Guide sticky-titles test (HANDOVER open work).
5. Integration tests on Linux, `just ready`, draft PR, wrap-up, merge, release.

## Decisions
- Owner: ended programmes behind "Show earlier"; leaving the player animates between two remembered sizes; mini player at the video's ratio; channel names in programme search; title hits first; CI only once the PR is ready (standing rule).
- Mine: channel names matched through items_fts at query time (no migration); the guide's search starts across all groups, its chip limits it to the shown group.
