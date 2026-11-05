#!/bin/sh
# Stress-profile the Dev app with no model: N stub agents stream markdown at once, one on screen
# with a 150-turn history, while Instruments records the SwiftUI and Animation Hitches templates.
#
#   xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
#     -derivedDataPath /tmp/shepherd-perf/dd -onlyUsePackageVersionsFromResolvedFile build
#   scripts/perf/stress.sh <label> [agents=8] [rows,rounds,deltas,ms=150,200,600,30]
#   python3 scripts/perf/summarize_traces.py <label>      # from the work dir
#
# Work dir: /tmp/shepherd-perf/stress (support dir, traces). Needs the Dev remote listener on
# (Settings ▸ Remote, port 7435) and System Events access for the window resize. Nothing here
# touches the user's Shepherd support directories or pi home.
set -e
REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=/tmp/shepherd-perf/stress; LABEL=$1; N=${2:-8}; STRESS=${3:-150,200,600,30}
APP=${SHEPHERD_STRESS_APP:-/tmp/shepherd-perf/dd/Build/Products/Debug/Shepherd.app}
mkdir -p "$WORK/bin" "$WORK/space"; cd "$WORK"
[ -d space/.git ] || git -C space init -q
cat > bin/pi <<EOF
#!/bin/sh
if [ "\$1" = "--list-models" ]; then printf 'provider   model                      context  max-out  thinking  images\nanthropic  claude-sonnet-4-5          1M       64K      yes       yes\n'; exit 0; fi
exec /usr/bin/env python3 '$REPO/Tests/ShepherdTestSupport/Resources/stub-pi.py' "\$@"
EOF
chmod +x bin/pi
pkill -f "$APP/Contents/MacOS/Shepherd" 2>/dev/null || true; sleep 2
rm -rf support && mkdir -p support/pi
# A copied import state skips the first-launch sheet.
python3 -c "import json,datetime;json.dump({'version':2,'copied':True,'copiedAt':datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ')},open('support/pi/.shepherd-imports.json','w'))"
SHEPHERD_SUPPORT_DIR="$WORK/support" SHEPHERD_PI_ENGINE="$WORK/bin/pi" STUB_PI_STRESS="$STRESS" \
  nohup "$APP/Contents/MacOS/Shepherd" > "app-$LABEL.log" 2>&1 &
sleep 8
PID=$(pgrep -f "$APP/Contents/MacOS/Shepherd")
python3 "$REPO/scripts/perf/remote_drive.py" 7435 support/remote-token "$WORK/space" "$N" > /dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  osascript -e "tell application \"System Events\" to set size of window 1 of (first process whose unix id is $PID) to {1600, 1000}" 2>/dev/null && break
  sleep 2
done
sleep 10
rm -rf "swiftui-$LABEL.trace" "hitches-$LABEL.trace"
xctrace record --template 'SwiftUI' --time-limit 20s --output "swiftui-$LABEL.trace" --attach "$PID" > /dev/null 2>&1
sleep 2
xctrace record --template 'Animation Hitches' --time-limit 30s --output "hitches-$LABEL.trace" --attach "$PID" > /dev/null 2>&1
kill "$PID"
echo "done $LABEL (traces in $WORK)"
