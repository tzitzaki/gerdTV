# Host self-update and version (task note; deleted by the PR that finishes it)

Started 15:13.

## Steps
1. `gerdtv-host --version` and the version in the start log (15:13).
2. `gerdtv-host update`: signed latest.json (gerdtv-core `update`), swap the binary, keep `.prev`, restart the unit,
   roll back when the new one does not stay up; `--before <command>` runs first (the owner's Proxmox snapshot).
3. Tests: extend the mock release with the `host` platform; one test for the update's outcomes.
4. Docs: INSTALL.md (update timer, `--version`), ARCHITECTURE.md if it lists the host's commands, DECISIONS.md.
5. `just ready`, PR, merge, wrap-up release.

## Decisions
- The snapshot is a `--before` hook, not Proxmox code in the repo: the home-specific part (token, VM id) stays in
  the private runbook.
- Healthy = the unit is active 30 s after the restart and systemd restarted it no further time (NRestarts).
