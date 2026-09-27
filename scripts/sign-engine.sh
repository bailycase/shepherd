#!/usr/bin/env bash
# Signs the pi engine's node (Contents/Helpers/node) one slice at a time, each with its own
# entitlements, and joins the slices again. Under the hardened runtime V8 needs allow-jit on
# arm64; the x86_64 slice (Intel, or Rosetta) also needs allow-unsigned-executable-memory, or it
# aborts at startup ("Check failed: 12 == (*__error())" in CodeRange::InitReservation). Signing
# the fat file once would give arm64 the x86_64 exception too.
#
# Called by scripts/sign-app.sh and by the Mac target's "Embed pi engine" phase.
#
# usage: scripts/sign-engine.sh [--runtime] <node> <identity|-> <entitlements> <x86_64-entitlements>
#   --runtime   sign with the hardened runtime (and a secure timestamp unless ad-hoc)
set -euo pipefail

runtime=0
if [[ ${1:-} == --runtime ]]; then
  runtime=1
  shift
fi
if [[ $# -ne 4 ]]; then
  echo "usage: $0 [--runtime] <node> <identity|-> <entitlements> <x86_64-entitlements>" >&2
  exit 64
fi
node=$1
identity=$2
arm64_entitlements=$3
x86_64_entitlements=$4

[[ -f "$node" ]] || { echo "error: no node at $node" >&2; exit 66; }
for plist in "$arm64_entitlements" "$x86_64_entitlements"; do
  [[ -f "$plist" ]] || { echo "error: no entitlements file: $plist" >&2; exit 66; }
  plutil -lint "$plist" >/dev/null
done

sign=(codesign --force --sign "$identity")
if (( runtime )); then
  sign+=(--options runtime)
  [[ "$identity" != "-" ]] && sign+=(--timestamp)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/sign-engine.XXXXXX")
trap 'rm -rf "$work"' EXIT

read -r -a archs <<<"$(lipo -archs "$node")"
thin=()
for arch in "${archs[@]}"; do
  case $arch in
    arm64) entitlements=$arm64_entitlements ;;
    x86_64) entitlements=$x86_64_entitlements ;;
    *) echo "error: $node has an unexpected $arch slice" >&2; exit 65 ;;
  esac
  if (( ${#archs[@]} == 1 )); then
    cp "$node" "$work/node-$arch"
  else
    lipo "$node" -thin "$arch" -output "$work/node-$arch"
  fi
  echo "sign ${node##*/} ($arch) with ${entitlements##*/}"
  "${sign[@]}" --entitlements "$entitlements" "$work/node-$arch"
  thin+=("$work/node-$arch")
done

if (( ${#thin[@]} == 1 )); then
  mv "${thin[0]}" "$work/node"
else
  lipo -create "${thin[@]}" -output "$work/node"
fi
chmod 755 "$work/node"
# A new file, never a rewrite in place: the kernel caches a signature per vnode.
mv -f "$work/node" "$node"
codesign --verify --strict "$node"
