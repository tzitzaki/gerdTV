#!/usr/bin/env bash
# CI: installs Flutter at the pinned version (app/FLUTTER_VERSION) by cloning its tag, instead of a third-party
# setup action (only GitHub-owned actions are allowed). $HOME/flutter is cached by actions/cache between runs.
set -euo pipefail
version="$(cat app/FLUTTER_VERSION)"
dir="$HOME/flutter"
# A cache restored by prefix (restore-keys) can hold an older Flutter after a version bump: start over then.
if [[ -d "$dir" && "$(git -C "$dir" describe --tags --exact-match 2>/dev/null)" != "$version" ]]; then
  echo "cached Flutter is not $version: cloning again"
  rm -rf "${dir:?}"
fi
if [[ ! -x "$dir/bin/flutter" ]]; then
  git clone --depth 1 --branch "$version" https://github.com/flutter/flutter.git "$dir"
fi
echo "$dir/bin" >> "${GITHUB_PATH:-/dev/null}"
export PATH="$dir/bin:$PATH"
flutter config --no-analytics >/dev/null
dart --disable-analytics >/dev/null
flutter --version
