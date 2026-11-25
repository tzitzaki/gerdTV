# Feature gaps (branch feat/feature-gaps)

Started 20:43. One PR, one release at the end. Progress: each step gets its start time here.

## Owner decisions
- At the connection limit a recording asks 1 min ahead, then wins. Recordings go to a folder the user chooses.
- Cast: the provider's URL first (the login reaches the receiver), then gerdTV's server on the LAN.
- DEVICE_CHECKS may have 90 lines; no existing check is touched (housekeeping is a later round).
- Simkl: send ids when known, import watched marks and paused positions (Trakt gets the ids). OpenSubtitles with the user's own key.
- Old database backups are deleted: each profile keeps its newest; a removed profile keeps none.
- No CI per commit: commits stay local, one push at the wrap-up (21:49).

## Steps
0. Set-up: started 20:43
1. Schema 11 and backups: started 20:46 (baseline `just test`: green, 2 min 16 s); atomic migrations and
   backup pruning done 20:49. Open: the schema 11 tables, as one migration with the first feature that needs one (step 3).
2. Account info, User-Agent: started 20:49; done 21:06 (integration tests green, 9 min 31 s).
3. Watched marks, next episode: started 21:19
4. Track settings: started 21:43
5. Picture (aspect, deinterlacing)
6. Last channel, CH keys
7. macOS media keys (iOS and Android came with #62)
8. Auto frame rate (Android TV)
9. Android TV home row
10. Custom groups, names, order (extends #62's long-hold menu)
11. TMDB
12. Simkl import, ids for Simkl and Trakt
13. OpenSubtitles (read its docs first: key and login model, quotas, terms; the Download page needs the Api-Key header always, the login names whose quota)
14. Recordings (first prove that an alarm can start the core on Android)
15. Cast and AirPlay (Spike C first)
16. Wrap-up

## State
Steps 0–3 done 21:43 (integration 8 min 22 s, the journey plays an episode to its end). Migration 11 is unreleased: later
features append to it. Next: step 4. Open questions: none blocking.
