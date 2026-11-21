#!/usr/bin/env node
// SessionStart hook: removes the worktrees of finished sessions, then deletes the local branches whose work is already in
// main, so neither piles up on the dev machine (CLAUDE.md, "Dev loop, git, PRs, merging"). Sessions leave behind worktrees
// (.claude/worktrees/<name>, archived or deleted sessions), the app's own worktree branches (<prefix>/<name>) and branches
// a session pushed under a second name. Runs at every session start, in any worktree (worktrees and branches are shared
// by all worktrees of the repo); worktrees go first, so the branches they held are free to delete in the same run.
//
// Safe by construction, so it can run unattended:
//   - a worktree is removed only when it is clean (nothing uncommitted, nothing untracked), its HEAD is an ancestor of
//     origin/main, it is neither the main folder nor the session's own, and no live process holds it: a lock counts while
//     the pid in its reason ("claude agent <name> (pid N start M)") runs; a lock without a pid is never undone. A remote-control
//     bridge locks its sessions' worktrees with its own pid and outlives them, so a lock naming "bridge-cse_<id>" counts only
//     while a process with "--session-id cse_<id>" runs (the session's own child; `ps` unreadable: the pid rule). `git worktree
//     remove` runs without --force, so git itself refuses anything not clean. Folders deleted by hand are pruned from git's list;
//   - a branch is deleted only when its tip is an ancestor of origin/main (every commit of it is in main: nothing is lost);
//     a squash-merged branch is not an ancestor and stays (delete it by hand);
//   - never `main`, never a branch checked out in any worktree (another session may be working there);
//   - no network: it compares with the last fetched origin/main, so at worst it deletes less, never more;
//   - it never fails a session start: any error ends it silently (exit 0).
// It prints one plain line per kind only when it removed something (Claude Code adds SessionStart output to the context).
// Debug: node .claude/hooks/prune-merged-branches.js --dry-run   (prints what it would remove, removes nothing);
//        git worktree list --porcelain   (the locks and their reasons);  ps -A -o args= | grep -- --session-id   (running sessions)
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const git = (cwd, ...args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();

// True while a process with this pid exists (signal 0 only checks; EPERM: it exists but belongs to another user).
function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

// The command lines of all processes (Linux and macOS `ps`), or null when `ps` cannot be read.
function processList() {
  try {
    return execFileSync('ps', ['-A', '-o', 'args='], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).split('\n');
  } catch {
    return null;
  }
}

/**
 * Remove (or with dryRun only list) the worktrees of finished sessions; see the rules at the top.
 * @param {string} cwd any folder of the repository; the worktree it is in is never removed
 * @returns {string[]} the worktree paths removed (or that would be)
 */
export function pruneStaleWorktrees(cwd, { base = 'origin/main', dryRun = false, processes = processList() } = {}) {
  try {
    git(cwd, 'rev-parse', '--verify', '--quiet', base);
  } catch {
    return [];
  }
  const own = git(cwd, 'rev-parse', '--show-toplevel');
  // The porcelain listing: blocks separated by a blank line, the first block is the main folder.
  const [, ...others] = git(cwd, 'worktree', 'list', '--porcelain').split('\n\n').map((block) => {
    const lines = block.split('\n');
    const value = (key) => lines.find((l) => l === key || l.startsWith(key + ' '))?.slice(key.length + 1);
    return { path: value('worktree'), head: value('HEAD'), locked: value('locked'), prunable: value('prunable') !== undefined };
  });
  const removed = [];
  let prune = false;
  for (const w of others) {
    if (!w.path || w.path === own) continue;
    if (w.locked !== undefined) {
      const pid = Number(/\(pid (\d+)/.exec(w.locked)?.[1]);
      const session = /bridge-(cse_\w+)/.exec(w.locked)?.[1];
      if (!pid) continue; // locked by hand
      if (session && processes) {
        if (processes.some((args) => args.includes(`--session-id ${session}`))) continue; // its session still runs
      } else if (alive(pid)) continue; // held by a running process
    }
    if (w.prunable) {
      prune = true; // folder already gone: only git's entry is left
    } else {
      try {
        if (git(w.path, 'status', '--porcelain') !== '') continue; // uncommitted or untracked work
        git(cwd, 'merge-base', '--is-ancestor', w.head, base);
      } catch {
        continue; // not in main yet (or unreadable): kept
      }
    }
    if (!dryRun) {
      if (w.locked !== undefined) git(cwd, 'worktree', 'unlock', w.path);
      if (!w.prunable) git(cwd, 'worktree', 'remove', w.path);
    }
    removed.push(w.path);
  }
  if (prune && !dryRun) git(cwd, 'worktree', 'prune');
  return removed;
}

/**
 * Delete (or with dryRun only list) the local branches merged into `base`.
 * @param {string} cwd any folder of the repository (a worktree works too)
 * @returns {string[]} the branch names deleted (or that would be)
 */
export function pruneMergedBranches(cwd, { base = 'origin/main', dryRun = false } = {}) {
  try {
    git(cwd, 'rev-parse', '--verify', '--quiet', base);
  } catch {
    return []; // no origin/main yet (a fresh clone before its first fetch): nothing to compare with
  }
  // Branches checked out in a worktree ("branch refs/heads/<name>" lines of the porcelain listing) are never touched.
  const busy = new Set(git(cwd, 'worktree', 'list', '--porcelain').split('\n').filter((l) => l.startsWith('branch refs/heads/')).map((l) => l.slice('branch refs/heads/'.length)));
  const deleted = [];
  for (const name of git(cwd, 'for-each-ref', '--format=%(refname:short)', 'refs/heads/').split('\n').filter(Boolean)) {
    if (name === 'main' || busy.has(name)) continue;
    try {
      git(cwd, 'merge-base', '--is-ancestor', name, base); // exit 0: every commit of the branch is in main
    } catch {
      continue; // not merged (or merged as a squash): kept
    }
    if (!dryRun) git(cwd, 'branch', '-D', name); // -D: merged into origin/main (checked above), maybe not into this HEAD
    deleted.push(name);
  }
  return deleted;
}

// Run as a hook only (the unit test imports the function without deleting anything here).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const dryRun = process.argv.includes('--dry-run');
    const cwd = process.env.CLAUDE_PROJECT_DIR || process.cwd();
    const trees = pruneStaleWorktrees(cwd, { dryRun });
    if (trees.length) console.log(`${dryRun ? 'Would remove' : 'Removed'} ${trees.length} stale worktree${trees.length === 1 ? '' : 's'}: ${trees.join(', ')}.`);
    const gone = pruneMergedBranches(cwd, { dryRun });
    if (gone.length) console.log(`${dryRun ? 'Would delete' : 'Deleted'} ${gone.length} local branch${gone.length === 1 ? '' : 'es'} already in main: ${gone.join(', ')}.`);
  } catch {
    /* never fail a session start */
  }
}
