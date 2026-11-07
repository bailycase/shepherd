#!/bin/bash
# Writes the background host's LaunchAgent plist for SMAppService.agent(plistName:): the app's own
# executable run with --host, labelled <bundle id>.host and listed under the app in Login Items.
# Usage: host-launch-agent.sh <output plist> <bundle id> <executable name>
set -euo pipefail
out="$1" id="$2" executable="$3"
mkdir -p "$(dirname "$out")"
cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${id}.host</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/${executable}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${executable}</string>
		<string>--host</string>
	</array>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>${id}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ExitTimeOut</key>
	<integer>30</integer>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$out" >/dev/null
