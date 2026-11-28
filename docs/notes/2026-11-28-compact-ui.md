# Compact UI (feat/compact-ui)

Task start 08:20. Owner decisions: settings in seven categories (Streaming, Guide, Services, Devices, Playback,
Appearance, About), each subcategory a card with one open at a time; compact density on desktop and small section
labels everywhere; rare actions behind ⋮ (provider card, rows, paired devices, guide's Sort and 20:15); the player's
top bar hides with the controls; codes (pairing, web login) big on one shared card.

## Steps
1. 08:27 Settings regroup + cards (done 08:35).
2. 08:35 Density + SectionLabel (done 08:36).
3. 08:36 Sort into the search row (done 08:38).
4. 08:38 Code card (done 08:42).
5. 08:42 Row actions into ⋮ (done 08:45).
6. 08:45 Guide controls in one row (done 08:48).
7. 08:48 Player top bar auto-hides (done 08:51).
8. 08:51 Docs (done 08:55); just ready 08:55: integration journey failed (menu still closing), fixed; rerun 09:19.

## Decisions taken
- Your data stays a card of its own (Streaming), not in the ⋮: it shows the export/import result under its buttons.
- The User-Agent field left the settings: the provider's edit form already has it.
- Devices and About stay flat lists (their rows open pages; a card around one row is a second tap).
- No state summary in card headers yet (proposal for later).
- Episodes keep their watched toggle button (the only per-episode toggle).
- The ⋮ on rows shows on desktop under the pointer only; phones use the long press, the TV held OK.
