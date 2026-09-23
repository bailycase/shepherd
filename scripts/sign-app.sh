#!/usr/bin/env bash
# Signs a built Shepherd.app inside-out: every nested code item first, deepest
# path first, then the app itself with the app's entitlements. Nested items keep
# the entitlements they were built with (Sparkle's Autoupdate carries one; its
# Downloader.xpc does when Sparkle is built sandboxed) and never receive the
# app's. That is why this does not sign with `codesign --deep`, which would
# stamp one set of entitlements on everything.
#
# usage: scripts/sign-app.sh <Shepherd.app> <identity> <entitlements.plist>
#   identity "-" signs ad-hoc, without the hardened runtime or a secure timestamp.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <app> <identity|-> <entitlements.plist>" >&2
  exit 64
fi
app=$1
identity=$2
entitlements=$3

[[ -d "$app/Contents" ]] || { echo "error: not an app bundle: $app" >&2; exit 66; }
[[ -f "$entitlements" ]] || { echo "error: no entitlements file: $entitlements" >&2; exit 66; }
plutil -lint "$entitlements" >/dev/null

# Physical path of a file, so paths reached through a framework's
# Versions/Current symlink compare equal to the paths `find` reports.
physical() {
  printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

app=$(physical "$app")

# Ad-hoc signatures carry no Team ID, so under the hardened runtime library
# validation would refuse the app's own ad-hoc frameworks and dyld would abort
# at launch. Ad-hoc builds therefore skip the runtime, as Xcode's Sign to Run
# Locally does; the app's entitlements still apply without it.
sign=(codesign --force --sign "$identity")
if [[ "$identity" != "-" ]]; then
  sign+=(--options runtime --timestamp)
fi

# The main executable of a bundle, or nothing when the bundle has no code
# (resource bundles are sealed by the enclosing bundle's signature instead).
main_executable() {
  local bundle=$1 info dir exe
  case "$bundle" in
    *.framework) dir="$bundle/Versions/Current"; info="$dir/Resources/Info.plist" ;;
    *)           dir="$bundle/Contents/MacOS";   info="$bundle/Contents/Info.plist" ;;
  esac
  [[ -f "$info" ]] || return 0
  exe=$(plutil -extract CFBundleExecutable raw -o - "$info" 2>/dev/null) || return 0
  if [[ -f "$dir/$exe" ]]; then physical "$dir/$exe"; fi
}

# Every nested code item: bundles that contain code, plus loose Mach-O files
# that are not some bundle's main executable (Sparkle's Autoupdate, the
# embedded shepherd-cli, dylibs). `find` does not follow symlinks, so each
# framework version is visited once, at its real path.
nested_code() {
  local bundle exe file owned
  owned=$(main_executable "$app")$'\n'
  while IFS= read -r bundle; do
    exe=$(main_executable "$bundle")
    [[ -n "$exe" ]] || continue
    echo "$bundle"
    owned+="$exe"$'\n'
  done < <(find "$app/Contents" -type d \( -name '*.framework' -o -name '*.xpc' \
    -o -name '*.app' -o -name '*.appex' -o -name '*.bundle' -o -name '*.plugin' \
    -o -name '*.systemextension' \))

  while IFS= read -r file; do
    [[ "$(file -b "$file")" == Mach-O* ]] || continue
    grep -Fxq -- "$file" <<<"$owned" && continue
    echo "$file"
  done < <(find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \))
}

# Deepest first: anything inside a bundle is signed before the bundle seals it.
items=$(nested_code | awk -F/ '{ print NF "\t" $0 }' | sort -rn -k1,1 | cut -f2-)

while IFS= read -r item; do
  [[ -n "$item" ]] || continue
  echo "sign ${item#"$app"/}"
  "${sign[@]}" --preserve-metadata=entitlements "$item"
done <<<"$items"

echo "sign $(basename "$app") with $entitlements"
"${sign[@]}" --entitlements "$entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
