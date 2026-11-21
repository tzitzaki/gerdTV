#!/usr/bin/env bash
# Public-repo guard (CLAUDE.md, "Public repo hygiene"): refuses changes that contain a pattern from the private
# denylist (~/.config/gerdTV/denylist, one fixed string per line, matched case-insensitively, never committed).
#
# Usage: scripts/check-denylist.sh [<base-ref>] [<extra-file>...]
#   Checks, against <base-ref> (default origin/main): every added line and every changed path (committed, staged and
#   unstaged), the commit messages and author/committer names and emails of <base-ref>..HEAD, and each extra file
#   (e.g. a PR body draft). Called by .githooks/pre-push and `just ready`.
# Prints only where a match is (file:line or commit), never the pattern itself, so its output is safe to share.
# Missing denylist (any machine but the owner's): prints a notice and passes. Debug: GERDTV_DENYLIST=<file> overrides.
set -euo pipefail

denylist="${GERDTV_DENYLIST:-$HOME/.config/gerdTV/denylist}"
base="${1:-origin/main}"
shift || true

if [[ ! -r "$denylist" ]]; then
  echo "denylist: $denylist not found, check skipped"
  exit 0
fi
# Blank lines would match everything; drop them (and trailing CR from editors).
patterns="$(mktemp)"
trap 'rm -f "$patterns"' EXIT
sed -e 's/\r$//' -e '/^[[:space:]]*$/d' "$denylist" > "$patterns"

found=0
report() { echo "denylist: match in $1"; found=1; }

# Added lines, with their file and line number (git diff against the base, including uncommitted work). awk tags
# each added line with file:line, then one grep pass matches them all (a grep per line took half a minute).
while IFS= read -r hit; do
  report "${hit%%$'\t'*}"
done < <( { git diff --no-color --unified=0 "$base" -- . 2>/dev/null; git diff --no-color --unified=0 --cached "$base" -- . 2>/dev/null; } |
  awk '/^\+\+\+ b\//{f=substr($0,7); next} /^@@/{split($3,a,","); n=substr(a[1],2)-1; next}
       /^\+/{n++; print f ":" n "\t" substr($0,2)}' | grep -iF -f "$patterns" | sort -u || true)

# Changed paths (a file name can leak too) and untracked new files' contents.
while IFS= read -r path; do
  grep -qiF -f "$patterns" <<<"$path" && report "path $path"
done < <(git diff --name-only "$base" -- . ; git ls-files --others --exclude-standard)
while IFS= read -r path; do
  [[ -f "$path" ]] && grep -qiF -f "$patterns" "$path" && report "untracked file $path"
done < <(git ls-files --others --exclude-standard)

# Commit messages and identities of the commits being added.
while IFS= read -r sha; do
  git log -1 --format='%an%n%ae%n%cn%n%ce%n%B' "$sha" | grep -qiF -f "$patterns" && report "commit $(git log -1 --format='%h %s' "$sha")"
done < <(git rev-list "$base..HEAD")

for f in "$@"; do
  grep -qiF -f "$patterns" "$f" && report "$f"
done

if [[ $found -ne 0 ]]; then
  echo "denylist: refused; remove the private detail (the pattern list is $denylist)"
  exit 1
fi
echo "denylist: clean"
