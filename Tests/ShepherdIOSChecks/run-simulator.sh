#!/bin/bash
# Renders iOS screens from fixture data on a simulator, headless, and saves a screenshot of each.
#
#
#   run-simulator.sh -d <udid> -o <dir> [options] <screen>...
#   run-simulator.sh --platform <iphone|ipad|duo> --set <dir> -o <dir> [options] <screen>...
#
#   -d <udid>        the simulator (create your own: xcrun simctl --set <set> create "Shepherd <label>" …)
#   --platform <p>   create the platform's device (iphone, ipad, duo) and delete it after the run;
#                    prints "not run" and exits 0 when the device cannot be created
#   --set <dir>      custom simulator set for every simctl call (or SHEPHERD_SIMULATOR_SET);
#                    required with --platform so created devices stay out of the default set
#   -o <dir>         where the PNGs go: <screen>-<device>-<scheme>[-landscape][-<pose>][-sidebar][-<text size>].png
#   -p <products>    Debug-iphonesimulator products of the 'Shepherd iOS' scheme; built here when absent
#   -s <scheme>      light, dark, or both (default both)
#   -r <orientation> portrait (default) or landscape
#   -f <pose>        iPhone Duo only: closed, book or open, held as -r says; the shot is of the display in use.
#                    Poses need SwiftUI 8.0.85 or newer: under an older toolchain the run exits
#                    non-zero and names DEVELOPER_DIR (Duo renders use Xcode 27.1).
#   -t <size>        a Dynamic Type category for simctl ui content_size (e.g. extra-extra-large)
#   -n <label>       the device part of file names (default: the simulator's name)
#   --sidebar        open the iPad sidebar over a portrait thread
#   -w               an app that supports multiple windows, as the shipped app does (the windows-* screens)
#   --list           print the screen names and exit
#
# FIXTURE_WAIT_STEPS=<n> gives each screen n waits of 0.2 s to become ready (default 300, one minute); raise it on a loaded machine.
#
# iPhone and iPad render on the iOS 27.0 runtime, iPhone Duo on iOS 27.1 (see SIMULATORS.md).
# Screens: any name in Tests/ShepherdIOSChecks/Fixtures (home, thread, question, newthread, …), or "all" (not tail-frames).
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD

device="" out="" products="" schemes="both" orientation="portrait" text_size="" label="" sidebar="" list="" windows=false pose=""
platform="" simctl_set="${SHEPHERD_SIMULATOR_SET:-}"
screens=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) device=$2; shift 2 ;;
        -o) out=$2; shift 2 ;;
        --platform) platform=$2; shift 2 ;;
        --set) simctl_set=$2; shift 2 ;;
        -p) products=$2; shift 2 ;;
        -s) schemes=$2; shift 2 ;;
        -r) orientation=$2; shift 2 ;;
        -f) pose=$2; shift 2 ;;
        -t) text_size=$2; shift 2 ;;
        -n) label=$2; shift 2 ;;
        --sidebar) sidebar=shown; shift ;;
        -w) windows=true; shift ;;
        --list) list=1; shift ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) screens+=("$1"); shift ;;
    esac
done
if [[ -n "$list" ]]; then
    grep -ho 'FixtureScreen(name: "[^"]*"' Tests/ShepherdIOSChecks/Fixtures/*.swift | sed 's/.*"\(.*\)"/\1/'
    exit 0
fi
[[ -n "$out" && ${#screens[@]} -gt 0 ]] || { sed -n '2,29p' "$0"; exit 64; }
# Exactly one of -d (a device you own) and --platform (a device the script owns for the run).
if [[ -n "$device" && -n "$platform" ]] || [[ -z "$device" && -z "$platform" ]]; then sed -n '2,29p' "$0"; exit 64; fi
case "$platform" in ""|iphone|ipad|duo) ;; *) echo "bad platform $platform (iphone, ipad or duo)"; exit 64 ;; esac
if [[ -n "$platform" && -z "$simctl_set" ]]; then echo "--platform needs --set <dir> or SHEPHERD_SIMULATOR_SET"; exit 64; fi
case "$pose" in ""|closed|book|open) ;; *) echo "bad pose $pose (closed, book or open)"; exit 64 ;; esac
fold_check=false
[[ "$windows:$pose:$orientation" == true:open:portrait ]] && fold_check=true
if [[ "${screens[0]}" == all ]]; then
    screens=()
    while IFS= read -r screen; do
        # tail-frames measures and never fails (about 35 s): ask for it by name.
        [[ "$screen" == tail-frames ]] && continue
        if [[ "$screen" != windows-fold || "$fold_check" == true ]]; then screens+=("$screen"); fi
    done < <(grep -ho 'FixtureScreen(name: "[^"]*"' Tests/ShepherdIOSChecks/Fixtures/*.swift | sed 's/.*"\(.*\)"/\1/')
fi
if [[ " ${screens[*]} " == *" windows-fold "* && "$fold_check" != true ]]; then
    echo "windows-fold requires -w -f open -r portrait on iPhone Duo"; exit 64
fi
case "$schemes" in both) schemes=(light dark) ;; light|dark) schemes=("$schemes") ;; *) echo "bad scheme $schemes"; exit 64 ;; esac
simctl=(xcrun simctl)
[[ -n "$simctl_set" ]] && simctl+=(--set "$simctl_set")

work=$(mktemp -d "${TMPDIR:-/tmp}/shepherd-ios-fixture.XXXXXX")
booted_by_us=false
# One trap owns every exit: success, failure and Ctrl-C. It opens with set +e so a failing
# shutdown (e.g. a device that never booted) can never abort the trap before delete and
# the work-dir removal run. --platform owns its device: shut it down and delete it. A -d
# device is yours: shut it down only when this run booted it.
cleanup() {
    set +e
    if [[ -n "$platform" && -n "$device" ]]; then
        "${simctl[@]}" shutdown "$device" >/dev/null 2>&1
        "${simctl[@]}" delete "$device" >/dev/null 2>&1
    elif [[ "$booted_by_us" == true && -n "$device" ]]; then
        "${simctl[@]}" shutdown "$device" >/dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT

# Poses drive the hinge through duopose and render fold-aware views, whose code compiles in only
# with SwiftUI 8.0.85 or newer (Xcode 27.1). Refuse early so a pose run never silently renders
# without the fold code. The probe compiles the same canImport check the app uses (Fold.swift).
if [[ -n "$pose" ]]; then
    probe="$work/probe.swift"
    cat > "$probe" <<'EOF'
#if canImport(SwiftUI, _version: 8.0.85)
#else
#error("poses need SwiftUI 8.0.85 or newer (Xcode 27.1)")
#endif
EOF
    sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
    sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version 2>/dev/null || true)
    [[ -n "$sdk_version" ]] || sdk_version=$(basename "$sdk_path" .sdk | grep -o '[0-9.]*$' || true)
    if [[ -z "$sdk_version" ]] || ! xcrun --sdk iphonesimulator swiftc -sdk "$sdk_path" \
        -target "arm64-apple-ios${sdk_version}-simulator" -typecheck "$probe" 2>"$probe.log"; then
        swiftui_version=$(grep -o 'user-module-version [^ ]*' \
            "$sdk_path/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/"*.swiftinterface \
            2>/dev/null | head -1 | awk '{print $2}' || true)
        echo "pose runs (-f) need SwiftUI 8.0.85 or newer; the active toolchain has SwiftUI ${swiftui_version:-unknown}." >&2
        echo "Set DEVELOPER_DIR to an Xcode 27.1 or newer toolchain (now DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)})." >&2
        exit 69 # EX_UNAVAILABLE: the toolchain cannot render poses
    fi
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)

# --platform owns its device: create it in the custom set; the EXIT trap shuts it down
# and deletes it, so success, failure and Ctrl-C leave no new booted devices behind.
if [[ -n "$platform" ]]; then
    case "$platform" in
        iphone) device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro; runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0 ;;
        ipad) device_type=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB; runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-0 ;;
        duo) device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-Duo; runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-1 ;;
    esac
    mkdir -p "$simctl_set"
    if ! device=$("${simctl[@]}" create "Shepherd $platform" "$device_type" "$runtime" 2>"$work/create.log"); then
        reason=$(tail -1 "$work/create.log")
        echo "not run: $platform (${reason:-the device could not be created})"
        exit 0
    fi
fi

name=$("${simctl[@]}" list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x['name'] for v in d.values() for x in v if x['udid']=='$device'), ''))")
[[ -n "$name" ]] || { echo "no simulator $device"; exit 66; }
[[ -n "$label" ]] || label=$(echo "$name" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//')

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
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UIRequiresFullScreen</key><FULL_SCREEN/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><MULTIPLE_WINDOWS/></dict>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
<key>UISupportedInterfaceOrientations~ipad</key><array><string>UIInterfaceOrientationPortrait</string><string>UIInterfaceOrientationPortraitUpsideDown</string><string>UIInterfaceOrientationLandscapeLeft</string><string>UIInterfaceOrientationLandscapeRight</string></array>
</dict></plist>
PLIST
full_screen=true; if [[ "$windows" == true ]]; then full_screen=false; fi
sed -i '' -e "s|<MULTIPLE_WINDOWS/>|<$windows/>|" -e "s|<FULL_SCREEN/>|<$full_screen/>|" "$app/Info.plist"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find App/iOS App/Glance App/NotificationContent -name '*.swift' ! -path 'App/NotificationContent/NotificationViewController.swift' ! -path 'App/iOS/App/ShepherdIOSApp.swift' | sort)
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios27.0-simulator -swift-version 5 \
    -Onone -D DEBUG -I "$products" \
    "$products/ShepherdCore.o" "$products/ShepherdProtocol.o" "$products/ShepherdRemote.o" "$products/ShepherdUI.o" \
    "$products/SwiftTerm.o" "$products/DesignSurfaceKit.o" \
    "${sources[@]}" Sources/ShepherdApp/Thread/ComposerMentions.swift Tests/ShepherdIOSChecks/ThreadSimulatorFixture.swift Tests/ShepherdIOSChecks/FixtureHost.swift \
    Tests/ShepherdIOSChecks/Fixtures/*.swift Tests/ShepherdTestSupport/MarkdownFixtures.swift \
    -o "$app/ShepherdFixture"
cp -R "$products/ShepherdUI_ShepherdUI.bundle" "$app/"
if [[ -d "$products/SwiftTerm_SwiftTerm.bundle" ]]; then cp -R "$products/SwiftTerm_SwiftTerm.bundle" "$app/"; fi
# The board renderer's runtime (Bundle.module), for the Design tool's screens.
for bundle in "$products"/*_DesignSurfaceKit.bundle; do [[ -d "$bundle" ]] && cp -R "$bundle" "$app/"; done
codesign --force --sign - "$app" >/dev/null 2>&1

# iPhone Duo's poses: SpringBoard's display tool sweeps the hinge as Device Hub does (DuoPose/).
# Closed shows the outer display (screen 1), book and open the inner one (screen 3).
if [[ -n "$pose" ]]; then
    xcrun --sdk iphonesimulator clang -fobjc-arc -target arm64-apple-ios27.0-simulator -framework Foundation \
        Tests/ShepherdIOSChecks/DuoPose/duopose.m -o "$work/duopose" \
        -Wl,-sectcreate,__TEXT,__entitlements,Tests/ShepherdIOSChecks/DuoPose/duopose.entitlements
    codesign --force --sign - "$work/duopose" >/dev/null 2>&1
    [[ "$orientation" == landscape ]] && device_orientation=landscapeLeft || device_orientation=portrait
    [[ "$pose" == closed ]] && display=1 || display=3
fi

state=$("${simctl[@]}" list devices -j | python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; print(next((x.get('state','') for v in d.values() for x in v if x['udid']=='$device'), ''))")
[[ "$state" == Booted ]] || booted_by_us=true
"${simctl[@]}" bootstatus "$device" -b >/dev/null
if [[ -n "$pose" ]]; then
    parse_status=0
    "${simctl[@]}" spawn "$device" "$work/duopose" -position=invalid >"$work/invalid-pose.log" 2>&1 || parse_status=$?
    [[ $parse_status -eq 64 ]] || { echo "FAIL: duopose must reject invalid arguments with exit 64"; exit 1; }
    # Posed before the app starts, as someone opens the phone and then the app.
    "${simctl[@]}" spawn "$device" "$work/duopose" -position="$pose" -deviceOrientation="$device_orientation" -duration=0 -wait
    sleep 2
fi
[[ -n "$text_size" ]] && "${simctl[@]}" ui "$device" content_size "$text_size"

status=0
# A posed Duo turns the app itself; only a plain device asks the fixture to turn its window.
fixture_orientation=$orientation
[[ -n "$pose" ]] && fixture_orientation=portrait
for screen in "${screens[@]}"; do
    for scheme in "${schemes[@]}"; do
        suffix="$scheme"
        [[ "$orientation" == landscape ]] && suffix+="-landscape"
        [[ -n "$pose" ]] && suffix+="-$pose"
        [[ -n "$sidebar" ]] && suffix+="-sidebar"
        [[ -n "$text_size" ]] && suffix+="-$text_size"
        shot="$out/$screen-$label-$suffix.png"
        log="$work/$screen-$scheme.log"
        # Every case starts with fresh fixture scenes. Duo rejects UIKit's iPad-only scene
        # destruction request, so a window from the previous case must not be restored.
        "${simctl[@]}" terminate "$device" com.shepherd.ios-fixture >/dev/null 2>&1 || true
        "${simctl[@]}" uninstall "$device" com.shepherd.ios-fixture >/dev/null 2>&1 || true
        "${simctl[@]}" install "$device" "$app"
        "${simctl[@]}" ui "$device" appearance "$scheme"
        SIMCTL_CHILD_FIXTURE_SCREEN="$screen" SIMCTL_CHILD_FIXTURE_SCHEME="$scheme" \
        SIMCTL_CHILD_FIXTURE_ORIENTATION="$fixture_orientation" SIMCTL_CHILD_FIXTURE_SIDEBAR="$sidebar" \
            "${simctl[@]}" launch --console --terminate-running-process "$device" com.shepherd.ios-fixture >"$log" 2>&1 &
        console=$!
        pose_requests=0
        for _ in $(seq 1 "${FIXTURE_WAIT_STEPS:-300}"); do
            # A real-scene regression waits at each hinge checkpoint, then verifies navigation
            # and fresh rendering after the system has moved the windows between displays.
            requests=$(grep -c '^FIXTURE POSE ' "$log" 2>/dev/null || true)
            if [[ ${requests:-0} -gt $pose_requests && -n "$pose" ]]; then
                requested=$(grep '^FIXTURE POSE ' "$log" | tail -1 | cut -d' ' -f3)
                case "$requested" in closed|open)
                    "${simctl[@]}" spawn "$device" "$work/duopose" -position="$requested" -deviceOrientation="$device_orientation" -duration=1 -wait
                    ;; esac
                pose_requests=$requests
            fi
            grep -q "^FIXTURE \(READY\|FAILED\|CHECK FAILED\|MUTATION\)" "$log" 2>/dev/null && break
            sleep 0.2
        done
        if grep -q "^FIXTURE READY $screen$" "$log" 2>/dev/null &&
           ! grep -q "^FIXTURE \(FAILED\|CHECK FAILED\|MUTATION\)" "$log" 2>/dev/null; then
            if [[ -n "$pose" ]]; then
                # The device turns the app itself (no FIXTURE_ORIENTATION), and a display shoots
                # the way it is seen.
                "${simctl[@]}" io "$device" screenshot --display="$display" "$shot" >/dev/null 2>&1
            else
                "${simctl[@]}" io "$device" screenshot "$shot" >/dev/null 2>&1
                # The framebuffer stays portrait; turn a landscape shot the way it is seen.
                [[ "$orientation" == landscape ]] && sips -r 270 "$shot" >/dev/null
            fi
            echo "$shot"
        else
            echo "FAIL: $screen ($scheme) never became ready"; tail -20 "$log" 2>/dev/null; status=1
        fi
        # Whether the window offers a new window (iPhone Duo: only open and upright).
        [[ -n "$pose" ]] && { grep "^FIXTURE WINDOWS AVAILABLE" "$log" | tail -1 | sed "s/^/$screen ($scheme): /" || true; }
        # A screen that measures what it shows prints "FIXTURE CHECK ok|FAILED: …".
        grep "^FIXTURE CHECK" "$log" 2>/dev/null | sed "s/^/$screen ($scheme): /" || true
        if grep -q "^FIXTURE CHECK FAILED" "$log" 2>/dev/null; then status=1; fi
        if grep -q "^FIXTURE MUTATION" "$log" 2>/dev/null; then
            echo "FAIL: $screen ($scheme) asked a host to change something:"; grep "^FIXTURE MUTATION" "$log"; status=1
        fi
        "${simctl[@]}" terminate "$device" com.shepherd.ios-fixture >/dev/null 2>&1 || true
        wait "$console" 2>/dev/null || true
    done
done
[[ -n "$text_size" ]] && "${simctl[@]}" ui "$device" content_size large
exit $status
