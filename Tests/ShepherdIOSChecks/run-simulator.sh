#!/bin/bash
# Renders iOS screens from fixture data on a simulator, headless, and saves a screenshot of each.
# See docs/ios/VALIDATION.md.
#
#   run-simulator.sh -d <udid> -o <dir> [options] <screen>...
#
#   -d <udid>        the simulator (create your own: xcrun simctl create "Shepherd <label>" …)
#   -o <dir>         where the PNGs go: <screen>-<device>-<scheme>[-landscape][-sidebar][-<text size>].png
#   -p <products>    Debug-iphonesimulator products of the 'Shepherd iOS' scheme; built here when absent
#   -s <scheme>      light, dark, or both (default both)
#   -r <orientation> portrait (default) or landscape
#   -t <size>        a Dynamic Type category for simctl ui content_size (e.g. extra-extra-large)
#   -n <label>       the device part of file names (default: the simulator's name)
#   --sidebar        open the iPad sidebar over a portrait thread
#   --list           print the screen names and exit
#
# Screens: any name in Tests/ShepherdIOSChecks/Fixtures (home, thread, question, newthread, …), or "all".
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD

device="" out="" products="" schemes="both" orientation="portrait" text_size="" label="" sidebar="" list=""
screens=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) device=$2; shift 2 ;;
        -o) out=$2; shift 2 ;;
        -p) products=$2; shift 2 ;;
        -s) schemes=$2; shift 2 ;;
        -r) orientation=$2; shift 2 ;;
        -t) text_size=$2; shift 2 ;;
        -n) label=$2; shift 2 ;;
        --sidebar) sidebar=shown; shift ;;
        --list) list=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) screens+=("$1"); shift ;;
    esac
done
if [[ -n "$list" ]]; then
    grep -ho 'FixtureScreen(name: "[^"]*"' Tests/ShepherdIOSChecks/Fixtures/*.swift | sed 's/.*"\(.*\)"/\1/'
    exit 0
fi
[[ -n "$device" && -n "$out" && ${#screens[@]} -gt 0 ]] || { sed -n '2,20p' "$0"; exit 64; }
if [[ "${screens[0]}" == all ]]; then
    screens=($(grep -ho 'FixtureScreen(name: "[^"]*"' Tests/ShepherdIOSChecks/Fixtures/*.swift | sed 's/.*"\(.*\)"/\1/'))
fi
case "$schemes" in both) schemes=(light dark) ;; light|dark) schemes=("$schemes") ;; *) echo "bad scheme $schemes"; exit 64 ;; esac
mkdir -p "$out"
out=$(cd "$out" && pwd)

name=$(xcrun simctl list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['name'] for v in d.values() for x in v if x['udid']=='$device'), ''))")
[[ -n "$name" ]] || { echo "no simulator $device"; exit 66; }
[[ -n "$label" ]] || label=$(echo "$name" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')

work=$(mktemp -d "${TMPDIR:-/tmp}/shepherd-ios-fixture.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [[ -z "$products" ]]; then
    derived=${SHEPHERD_IOS_DERIVED_DATA:-${TMPDIR:-/tmp}/shepherd-ios-fixture-dd}
    echo "Building Shepherd iOS into $derived"
    xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd iOS' -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived" -skipPackagePluginValidation -skipMacroValidation \
        -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build -quiet
    products="$derived/Build/Products/Debug-iphonesimulator"
fi

# The fixture app: the production views and stores, with the fixture entry point and hosts.
app="$work/ShepherdFixture.app"
mkdir "$app"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.shepherd.ios-fixture</string>
<key>CFBundleExecutable</key><string>ShepherdFixture</string>
<key>CFBundleName</key><string>Shepherd Fixture</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>27.0</string>
<key>UILaunchScreen</key><dict/>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIRequiresFullScreen</key><true/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find App/iOS -name '*.swift' ! -path 'App/iOS/App/ShepherdIOSApp.swift' | sort)
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios27.0-simulator -swift-version 5 \
    -Onone -I "$products" \
    "$products/ShepherdCore.o" "$products/ShepherdProtocol.o" "$products/ShepherdRemote.o" "$products/ShepherdUI.o" \
    "${sources[@]}" Tests/ShepherdIOSChecks/ThreadSimulatorFixture.swift Tests/ShepherdIOSChecks/FixtureHost.swift \
    Tests/ShepherdIOSChecks/Fixtures/*.swift \
    -o "$app/ShepherdFixture"
cp -R "$products/ShepherdUI_ShepherdUI.bundle" "$app/"
codesign --force --sign - "$app" >/dev/null 2>&1

xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"
[[ -n "$text_size" ]] && xcrun simctl ui "$device" content_size "$text_size"

status=0
for screen in "${screens[@]}"; do
    for scheme in "${schemes[@]}"; do
        suffix="$scheme"
        [[ "$orientation" == landscape ]] && suffix+="-landscape"
        [[ -n "$sidebar" ]] && suffix+="-sidebar"
        [[ -n "$text_size" ]] && suffix+="-$text_size"
        shot="$out/$screen-$label-$suffix.png"
        log="$work/$screen-$scheme.log"
        xcrun simctl ui "$device" appearance "$scheme"
        SIMCTL_CHILD_FIXTURE_SCREEN="$screen" SIMCTL_CHILD_FIXTURE_SCHEME="$scheme" \
        SIMCTL_CHILD_FIXTURE_ORIENTATION="$orientation" SIMCTL_CHILD_FIXTURE_SIDEBAR="$sidebar" \
            xcrun simctl launch --console --terminate-running-process "$device" com.shepherd.ios-fixture >"$log" 2>&1 &
        console=$!
        for _ in $(seq 1 300); do
            grep -q "^FIXTURE \(READY\|FAILED\)" "$log" 2>/dev/null && break
            sleep 0.2
        done
        if grep -q "^FIXTURE READY" "$log" 2>/dev/null; then
            xcrun simctl io "$device" screenshot "$shot" >/dev/null 2>&1
            # The framebuffer stays portrait; turn a landscape shot the way it is seen.
            [[ "$orientation" == landscape ]] && sips -r 270 "$shot" >/dev/null
            echo "$shot"
        else
            echo "FAIL: $screen ($scheme) never became ready"; tail -20 "$log" 2>/dev/null; status=1
        fi
        if grep -q "^FIXTURE MUTATION" "$log" 2>/dev/null; then
            echo "FAIL: $screen ($scheme) asked a host to change something:"; grep "^FIXTURE MUTATION" "$log"; status=1
        fi
        xcrun simctl terminate "$device" com.shepherd.ios-fixture >/dev/null 2>&1 || true
        wait "$console" 2>/dev/null || true
    done
done
[[ -n "$text_size" ]] && xcrun simctl ui "$device" content_size large
exit $status
