#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build=$(mktemp -d /tmp/shepherd-ios-check.XXXXXX)
trap 'rm -rf "$build"' EXIT
sdk=$(xcrun --sdk macosx --show-sdk-path)
flags=(-sdk "$sdk" -target "$(uname -m)-apple-macos26.0" -swift-version 5 -I "$build" -L "$build")
for module in ShepherdCore ShepherdProtocol ShepherdRemote; do
    links=()
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

xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote \
    -parse-as-library Tests/ShepherdIOSChecks/ThreadStoreCheck.swift \
    -o "$build/thread-check"
DYLD_LIBRARY_PATH="$build" "$build/thread-check"
xcrun swiftc "${flags[@]}" -lShepherdCore -lShepherdProtocol -lShepherdRemote \
    -parse-as-library Tests/ShepherdIOSChecks/RemoteConnectCheck.swift -o "$build/connect-check"
DYLD_LIBRARY_PATH="$build" "$build/connect-check"
