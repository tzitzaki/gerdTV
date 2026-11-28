# Compact UI (feat/compact-ui)

Task start 08:20. Owner decisions: settings in seven categories (Streaming, Guide, Services, Devices, Playback,
Appearance, About), each subcategory a card with one open at a time; compact density on desktop and small section
labels everywhere; rare actions behind ⋮ (provider card, rows, paired devices, guide's Sort and 20:15); the player's
top bar hides with the controls; codes (pairing, web login) big on one shared card.

## Steps
1. 08:27 Settings regroup + cards (done 08:35).
2. Density + SectionLabel.
3. Sort into the search row.
4. Code card.
5. Row actions into ⋮.
6. Guide controls in one row.
7. Player top bar auto-hides.
8. Docs, integration screenshots, wrap-up.

## Decisions taken
- Your data stays a card of its own (Streaming), not in the ⋮: it shows the export/import result under its buttons.
- The User-Agent field left the settings: the provider's edit form already has it.
- Devices and About stay flat lists (their rows open pages; a card around one row is a second tap).
- No state summary in card headers yet (proposal for later).
