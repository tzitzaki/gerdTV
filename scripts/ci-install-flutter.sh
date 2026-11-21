#!/usr/bin/env bash
# CI: installs Flutter at the pinned version (app/FLUTTER_VERSION) by cloning its tag, instead of a third-party
# setup action (only GitHub-owned actions are allowed). $HOME/flutter is cached by actions/cache between runs.
set -euo pipefail
version="$(cat app/FLUTTER_VERSION)"
dir="$HOME/flutter"
if [[ ! -x "$dir/bin/flutter" ]]; then
  git clone --depth 1 --branch "$version" https://github.com/flutter/flutter.git "$dir"
fi
echo "$dir/bin" >> "${GITHUB_PATH:-/dev/null}"
export PATH="$dir/bin:$PATH"
flutter config --no-analytics >/dev/null
dart --disable-analytics >/dev/null
flutter --version
