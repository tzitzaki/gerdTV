#!/usr/bin/env bash
# Licence gate (CLAUDE.md, "Public repo hygiene"): every library bundled into the app must be GPL-3.0 compatible.
# Rust: the normal (shipped) dependency tree of gerdtv_api, by SPDX expression from Cargo metadata.
# Dart: every non-dev package the app resolves, by its LICENSE text. The native libraries (libmpv, FFmpeg) are
# checked by hand per Spike A and listed in docs/ARCHITECTURE.md until the in-app Licences screen lists them.
# Debug: a refused crate prints its name and licence; if it is genuinely compatible, add the SPDX id below.
set -euo pipefail
cd "$(dirname "$0")/.."

ok_spdx=" MIT Apache-2.0 BSD-2-Clause BSD-3-Clause ISC Zlib Unicode-3.0 Unicode-DFS-2016 MPL-2.0 CC0-1.0 0BSD Unlicense BSL-1.0 LGPL-2.1-or-later LGPL-3.0-or-later GPL-3.0-only GPL-3.0-or-later Apache-2.0 WITH LLVM-exception "
fail=0

# An SPDX expression is fine if, for some OR-alternative, every AND-part is in the list.
spdx_ok() {
  local expr="${1//(/}"; expr="${expr//)/}"; expr="${expr//\// OR }"
  local alt part good
  while IFS= read -r alt; do
    good=1
    while IFS= read -r part; do
      part="$(xargs <<<"$part")"
      [[ "$ok_spdx" == *" $part "* ]] || good=0
    done < <(sed 's/ AND /\n/g' <<<"$alt")
    [[ $good == 1 ]] && return 0
  done < <(sed 's/ OR /\n/g' <<<"$expr")
  return 1
}

n=0
while read -r name version licence; do
  n=$((n + 1))
  [[ "$name" == gerdtv* ]] && continue
  # No SPDX id (license-file crates): reviewed by hand and listed here with what the file says.
  case "$name" in allo-isolate) licence="Apache-2.0" ;; esac
  spdx_ok "$licence" || { echo "licences: Rust crate $name $version has licence '$licence'"; fail=1; }
done < <(cargo tree --color never -p gerdtv_api -e normal --prefix none --format '{p} {l}' | sed 's/ (\*)//g; s/ (proc-macro)//g; s/ v\([0-9]\)/ \1/' | sort -u)
echo "licences: $n Rust crates checked"

# Dart: package_config.json lists every resolved package; `flutter pub deps` says which are dev-only.
(cd app && flutter pub get >/dev/null)
dev="$(cd app && flutter pub deps --json | jq -r '.packages[] | select(.kind == "dev") | .name')"
m=0
while read -r name root; do
  grep -qx "$name" <<<"$dev" && continue
  [[ "$name" == gerdtv* ]] && continue
  m=$((m + 1))
  root="${root#file://}"; [[ "$root" == /* ]] || root="app/.dart_tool/$root"
  lic="$(cat "$root"/LICENSE* 2>/dev/null | head -c 4000 || true)"
  if [[ -z "$lic" && "$root" == *"/flutter/"* ]]; then continue; fi    # Flutter SDK packages: BSD-3-Clause (SDK LICENSE)
  if grep -qiE 'Permission is hereby granted, free of charge|Redistribution and use in source and binary forms|Apache License|Mozilla Public License' <<<"$lic"; then continue; fi
  echo "licences: Dart package $name has an unrecognised or missing licence ($root)"; fail=1
done < <(jq -r '.packages[] | "\(.name) \(.rootUri)"' app/.dart_tool/package_config.json)
echo "licences: $m Dart packages checked"
exit $fail
