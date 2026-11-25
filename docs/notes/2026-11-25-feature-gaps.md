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
5. Picture (aspect, deinterlacing): started 22:11
6. Last channel, CH keys: started 22:21
7. macOS media keys (started 22:48) (iOS and Android came with #62)
8. Auto frame rate (Android TV): started 22:50
9. Android TV home row: started 22:56
10. Custom groups, names, order (extends #62's long-hold menu)
11. TMDB
12. Simkl import, ids for Simkl and Trakt
13. OpenSubtitles (read its docs first: key and login model, quotas, terms; the Download page needs the Api-Key header always, the login names whose quota)
14. Recordings (first prove that an alarm can start the core on Android)
15. Cast and AirPlay (Spike C first)
16. Wrap-up

## State
Steps 0–8 done 22:56 (step 8 compiles for Android, 3 min 51 s; step 7's Swift is not compiled: no Mac here, no CI per commit) (integration 8 min 21 s; step 4: no languages for Apple's player, it reports none). Migration 11 is unreleased: later
features append to it. Next: step 9. Open questions: none blocking.
