#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=${1:-all}
case "$mode" in all|--sidebar-only) ;; *) echo "Unknown check selection: $mode" >&2; exit 2 ;; esac
build=$(mktemp -d /tmp/shepherd-ios-check.XXXXXX)
if [ -n "${GITHUB_ENV:-}" ]; then printf 'MOBILE_CLIENT_CHECK_BUILD=%s\n' "$build" >> "$GITHUB_ENV"; fi
# Retain compiler outputs on failure; CI collects this owned root with the failing log.
trap 'result=$?; if [ "$result" -ne 0 ]; then echo "Retained failed client check: $build"; fi' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macos26.0" -swift-version 5 -I "$build" -L "$build")
xcrun swiftc "${flags[@]}" -parse-as-library Tests/ShepherdIOSChecks/Fixtures/FixtureCheck.swift \
    Tests/ShepherdIOSChecks/FixtureReadinessCheck.swift -o "$build/readiness-check"
"$build/readiness-check" success | grep -q '^FIXTURE READY readiness-check$'
for failure in timeout failed-check cancelled; do
    if "$build/readiness-check" "$failure" > "$build/readiness.log" 2>&1; then
        echo "FAIL: readiness $failure succeeded"; exit 1
    fi
    grep -q '^FIXTURE FAILED .*snapshot\|^FIXTURE FAILED .*proposal pins' "$build/readiness.log"
    if grep -q '^FIXTURE READY' "$build/readiness.log"; then
        echo "FAIL: readiness $failure emitted READY"; exit 1
    fi
done
echo 'PASS: fixture readiness failures exit without READY'

for module in ShepherdCore ShepherdProtocol ShepherdRemote; do
    links=(-L "$build")
    if [[ "$module" != ShepherdCore ]]; then links+=(-lShepherdCore); fi
    if [[ "$module" == ShepherdRemote ]]; then links+=(-lShepherdProtocol); fi
    xcrun swiftc "${flags[@]}" "${links[@]}" -enable-testing -emit-library -emit-module \
        -module-name "$module" -emit-module-path "$build/$module.swiftmodule" \
        Sources/"$module"/*.swift -o "$build/lib$module.dylib"
done
xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Support/AgentRef.swift \
    Tests/ShepherdIOSChecks/MobileHostsCheck.swift -o "$build/hosts-check"
DYLD_LIBRARY_PATH="$build" "$build/hosts-check"

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Support/AgentRef.swift \
    App/iOS/Home/SidebarThreads.swift App/iOS/Search/AgentActions.swift \
    App/iOS/Review/ReviewErrors.swift App/iOS/Terminal/MobileTerminals.swift \
    Tests/ShepherdIOSChecks/TerminalActivityCheck.swift Tests/ShepherdIOSChecks/SidebarThreadsCheck.swift -o "$build/sidebar-check"
DYLD_LIBRARY_PATH="$build" "$build/sidebar-check"
echo 'SIDEBAR CHECK COMPLETE'
if [ "$mode" = --sidebar-only ]; then exit 0; fi

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Hosts/MobilePairing.swift App/iOS/Support/AgentRef.swift \
    Tests/ShepherdIOSChecks/FakeFleetMacs.swift Tests/ShepherdIOSChecks/FleetDevicePairingCheck.swift -o "$build/fleet-device-check"
DYLD_LIBRARY_PATH="$build" "$build/fleet-device-check"

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Hosts/MobilePairing.swift App/iOS/Support/AgentRef.swift \
    Tests/ShepherdIOSChecks/FakeFleetMacs.swift Tests/ShepherdIOSChecks/FleetViewCheck.swift -o "$build/fleet-view-check"
DYLD_LIBRARY_PATH="$build" "$build/fleet-view-check"

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Support/AgentRef.swift \
    Tests/ShepherdIOSChecks/FakeFleetMacs.swift Tests/ShepherdIOSChecks/FleetFollowCheck.swift -o "$build/fleet-follow-check"
DYLD_LIBRARY_PATH="$build" "$build/fleet-follow-check"

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Support/AgentRef.swift \
    App/iOS/Files/ThreadFilesStores.swift App/iOS/Review/ReviewRetention.swift \
    Tests/ShepherdIOSChecks/FilesRetentionCheck.swift -o "$build/files-retention-check"
DYLD_LIBRARY_PATH="$build" "$build/files-retention-check" | tee "$build/files-retention.log"
grep -q '^FILES RETENTION CHECK COMPLETE$' "$build/files-retention.log"

xcrun swiftc "${flags[@]}" -D DEBUG -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Automations/AutomationsStore.swift Tests/ShepherdIOSChecks/AutomationsStoreCheck.swift -o "$build/automations-check"
DYLD_LIBRARY_PATH="$build" "$build/automations-check"
echo 'AUTOMATIONS CHECK COMPLETE'

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Forge/ForgeRows.swift Tests/ShepherdIOSChecks/ForgeRowsCheck.swift -o "$build/forge-rows-check"
DYLD_LIBRARY_PATH="$build" "$build/forge-rows-check"

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Support/AgentRef.swift \
    App/iOS/Thread/ThreadStores.swift App/iOS/Thread/ThreadRecovery.swift \
    Tests/ShepherdIOSChecks/MobileRecoveryCheck.swift -o "$build/recovery-check"
DYLD_LIBRARY_PATH="$build" "$build/recovery-check"
xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote \
    -parse-as-library Tests/ShepherdIOSChecks/ThreadStoreCheck.swift \
    -o "$build/thread-check"
DYLD_LIBRARY_PATH="$build" "$build/thread-check"
xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote \
    -parse-as-library Tests/ShepherdIOSChecks/RemoteConnectCheck.swift -o "$build/connect-check"
DYLD_LIBRARY_PATH="$build" "$build/connect-check"
xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote \
    -parse-as-library Tests/ShepherdIOSChecks/RemoteClientBackpressureCheck.swift -o "$build/backpressure-check"
DYLD_LIBRARY_PATH="$build" "$build/backpressure-check"
xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote -parse-as-library \
    App/iOS/Hosts/MobileHosts.swift App/iOS/Hosts/HostTokens.swift App/iOS/Support/AgentRef.swift \
    App/iOS/Home/HomeFeed.swift App/iOS/App/MobileReadiness.swift App/iOS/Review/ReviewRetention.swift \
    App/iOS/Thread/ThreadStores.swift App/iOS/Thread/ThreadRecovery.swift App/iOS/Hosts/ThreadRevisionHints.swift \
    Tests/ShepherdIOSChecks/MobileFreshnessCheck.swift -o "$build/freshness-check"
DYLD_LIBRARY_PATH="$build" "$build/freshness-check"
