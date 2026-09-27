#!/usr/bin/env bash
# Signs the pi engine's node (Contents/Helpers/node) with the engine's entitlements. Under the
# hardened runtime V8 needs allow-jit. Shepherd runs on Apple silicon only, so node is arm64 only,
# and a node with any other slice is refused.
#
# Called by scripts/sign-app.sh and by the Mac target's "Embed pi engine" phase.
#
# usage: scripts/sign-engine.sh [--runtime] <node> <identity|-> <entitlements>
#   --runtime   sign with the hardened runtime (and a secure timestamp unless ad-hoc)
set -euo pipefail

runtime=0
if [[ ${1:-} == --runtime ]]; then
  runtime=1
  shift
fi
if [[ $# -ne 3 ]]; then
  echo "usage: $0 [--runtime] <node> <identity|-> <entitlements>" >&2
  exit 64
fi
node=$1
identity=$2
entitlements=$3

[[ -f "$node" ]] || { echo "error: no node at $node" >&2; exit 66; }
[[ -f "$entitlements" ]] || { echo "error: no entitlements file: $entitlements" >&2; exit 66; }
plutil -lint "$entitlements" >/dev/null

archs=$(lipo -archs "$node")
if [[ "$archs" != arm64 ]]; then
  echo "error: $node is $archs; Shepherd ships node for arm64 only" >&2
  exit 65
fi

# Signed under its final name's identifier, never its temporary file's: a Developer ID seal on
# the app pins the identifier of nested code.
sign=(codesign --force --sign "$identity" --identifier node)
if (( runtime )); then
  sign+=(--options runtime)
  [[ "$identity" != "-" ]] && sign+=(--timestamp)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/sign-engine.XXXXXX")
trap 'rm -rf "$work"' EXIT

cp "$node" "$work/node"
echo "sign ${node##*/} with ${entitlements##*/}"
"${sign[@]}" --entitlements "$entitlements" "$work/node"
chmod 755 "$work/node"
# A new file, never a rewrite in place: the kernel caches a signature per vnode.
mv -f "$work/node" "$node"
codesign --verify --strict "$node"
