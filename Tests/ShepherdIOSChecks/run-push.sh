#!/bin/bash
# Usage: bash Tests/ShepherdIOSChecks/run-push.sh <Debug-iphonesimulator products> <booted simulator UDID>
# Compiles production code with an async check entry point; no app launch, network or permissions.
set -euo pipefail
cd "$(dirname "$0")/../.."
products=$1
device=$2
work=$(mktemp -d /tmp/shepherd-push-check.XXXXXX)
# Fixture-only access to capabilities; production keeps its fileprivate setter.
cp App/iOS/Hosts/MobileHosts.swift "$work/MobileHosts.swift"
printf '\nextension MobileHost { func enablePushFixture() { capabilities.insert(RemoteProtocol.pushNotificationsCapability) } }\n' >> "$work/MobileHosts.swift"
sources=("$work/MobileHosts.swift")
while IFS= read -r file; do sources+=("$file"); done < <(find App/iOS -name '*.swift' ! -path 'App/iOS/App/ShepherdIOSApp.swift' ! -path 'App/iOS/Hosts/MobileHosts.swift' | sort)
xcrun --sdk iphonesimulator swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios27.0-simulator -swift-version 5 -D DEBUG -Onone -I "$products" \
    "$products/ShepherdCore.o" "$products/ShepherdProtocol.o" "$products/ShepherdRemote.o" "$products/ShepherdUI.o" \
    "$products/SwiftTerm.o" "$products/DesignSurfaceKit.o" \
    "${sources[@]}" Tests/ShepherdIOSChecks/PushTests.swift -o "$work/PushChecks"
codesign --force --sign - "$work/PushChecks"
xcrun simctl spawn "$device" "$work/PushChecks"
