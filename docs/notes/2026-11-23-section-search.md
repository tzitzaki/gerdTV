# Search in every section, then timeshift UI, Phase 3, Block C (unattended run)

Plan: the owner's answers from 10:08 to 10:26. Each topic is its own PR. The run has no STOP_AT, and I fix blockers until main is green.

## Decisions
- No Search tab. Live TV, Movies, Series and the Guide each get a field.
- A section's group list searches the whole section. Inside a group, the field searches the whole group, and a chip "All groups" widens it to the section.
- Live TV search lists channels, then 5 programmes and a "Show all" row. The Guide field lists programmes.
- Matching: group names count, mid-word matches use a trigram index, and typos are allowed (4+ letters: 1 edit; 7+: 2 edits; the first letter must be right).
- Ranking: favourites, then recents, then tiers in this order: channel number, whole word, word start, group name, mid-word, typo.
- Built too: type-to-search, groups as results, matched text in bold, and the last 5 searches per section. Each section keeps its query until it is cleared.
- Results use the section's display mode, with the group name on each result.
- Migration 6 rebuilds the search index from the database. The startup sync then adds the tvg-names back.

## Progress
- 10:33 #45 merged: CLAUDE.md rule "unknowns first, one extensive question round".
- 10:35 start step 1 (core: migration 6, index, tiers, typos, groups, history).
- 10:58 step 1 green (core + bridge): budgets hold (s 40 ms, sport 19 ms); "sport mu" was 1 s until the trigram arm used INTERSECT.
- 11:15 step 3 built; first integration run: screen check green on all sizes, journey's type-to-search step fixed (test-only).
