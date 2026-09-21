#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Build the iOS scheme first. This separate fixture app never saves a real credential.
products=${1:-/tmp/shepherd-ios-thread-build/Build/Products/Debug-iphonesimulator}
device=${2:-95546A5A-7C50-42F4-A978-77C99A3CE6A4}
fixture=$(mktemp -d /tmp/shepherd-thread-fixture.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/ThreadFixture.app"
cat > "$fixture/ThreadFixture.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.shepherd.thread-fixture</string>
<key>CFBundleExecutable</key><string>ThreadFixture</string>
<key>CFBundleName</key><string>Thread Fixture</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UILaunchScreen</key><dict/>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict></plist>
PLIST
xcrun swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios27.0-simulator -swift-version 5 -I "$products" \
    "$products/ShepherdCore.o" "$products/ShepherdProtocol.o" "$products/ShepherdRemote.o" \
    App/iOS/HostConnection.swift App/iOS/MobileTokens.swift App/iOS/Thread*.swift App/iOS/FleetView.swift App/iOS/HostSettingsView.swift \
    Tests/ShepherdIOSChecks/ThreadSimulatorFixture.swift \
    -o "$fixture/ThreadFixture.app/ThreadFixture"
python3 - "$device" "$fixture/ThreadFixture.app" <<'PY'
import json, os, socket, subprocess, sys, threading, time

device, app = sys.argv[1:]
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen()
listener.settimeout(20)
errors, seen = [], []

def serve():
    try:
        conn, _ = listener.accept()
        conn.settimeout(20)
        with conn, conn.makefile('r') as stream:
            for line in stream:
                request = json.loads(line)
                kind, rid = request['type'], request.get('id')
                seen.append(kind)
                if kind == 'hello':
                    assert request['token'] == 'fixture-only'
                    reply = dict(type='helloOk', id=rid, protocolVersion=1, capabilities=['native.thread.v1'])
                elif kind == 'stateFetch':
                    agents = [dict(id='fixture-agent', name='verify native thread', spaceID='fixture-space', tabID='fixture-tab', status='blocked')]
                    if os.environ.get('FIXTURE_SCREEN') == 'fleet':
                        agents += [dict(id='a%d' % i, name=n, spaceID='fixture-space', tabID='t%d' % i, status=st) for i, (n, st) in enumerate([
                            ('Plan shepherd extensions', 'working'), ('Dock review pane', 'working'), ('Fix remote subagent deletion', 'idle'),
                            ('Fix terminal output buffer', 'idle'), ('Fix agent deletion workflow', 'done'), ('Investigate SwiftUI live preview', 'idle')])]
                    reply = dict(type='state', id=rid, state=dict(spaces=[dict(id='fixture-space', name='Shepherd', path='/tmp', order=0)], tabs=[], agents=agents,
                                                                 automations=[dict(id='auto1', name='Merge PR #24 after CI', prompt='watch', cwd='/tmp', enabled=False)]))
                elif kind == 'nativeThread':
                    action = request['request']
                    assert 'snapshot' in action, 'fixture unexpectedly mutated'
                    # FIXTURE_DIALOG=none renders an idle thread with no sheet (composer and body visible).
                    snap = dict(piSessionID='fixture-session', generation='fixture-generation', revision=1,
                                running=os.environ.get('FIXTURE_DIALOG') != 'none',
                                supportedActions=['send', 'abort', 'answer'], dialogsSupported=True,
                                dialogs=[] if os.environ.get('FIXTURE_DIALOG') == 'none' else [{
                                    'select': dict(id='q1', kind='select', title='Which suite first?', options=['ShepherdIOSChecks', 'ShepherdProtocolTests', 'Everything']),
                                    'input': dict(id='q1', kind='input', title='Name the release tag', placeholder='v0.3.0-beta.1', unavailable=os.environ.get('FIXTURE_UNAVAILABLE')),
                                }.get(os.environ.get('FIXTURE_DIALOG'), dict(id='q1', kind='confirm', title='Run the focused checks?', message='The host is waiting for your answer.'))],
                                widgets=[dict(namespace='fixture.build', key='status', kind='status', title='Build status', text='Focused checks passed'),
                                         dict(namespace='fixture.review', key='notes', kind='text', title='Review notes', text='Plain text only: **not bold**\nNo callbacks or controls.')],
                                messages=[
                                    dict(entryID='m1', role='user', blocks=[dict(kind='text', text='Check the reconnect fix.')], truncated=False),
                                    dict(entryID='m2', role='assistant', blocks=[dict(kind='thinking', text='Inspect the pending connection before authenticating.'), dict(kind='text', text='Cancelled socket opens now close without sending hello. I traced `RemoteHostClient.open` and the **cancel path** returns before the handshake.\n\n```swift\nguard !cancelled else { socket.close(); return }\n```')], truncated=False),
                                    dict(entryID='m3', role='toolResult', toolName='bash', status='complete', blocks=[dict(kind='text', text='PASS: stale hello blocked')], truncated=False),
                                    dict(entryID='m4', role='toolResult', toolName='read', status='complete', isError=True, blocks=[dict(kind='text', text='ENOENT: Sources/ShepherdRemote/Missing.swift')], truncated=False),
                                    dict(entryID='m5', role='user', blocks=[dict(kind='text', text='Run the focused checks and summarize.')], truncated=False),
                                    dict(entryID='m6', role='assistant', blocks=[dict(kind='text', text='## Summary\n\nThree checks cover the change:\n\n- `RemoteConnectCheck` for cancelled handshakes\n- `ThreadStoreCheck` for stale sessions\n- `HostConnectionCheck` for reconnect backoff\n\nWant me to run them now?')], truncated=False),
                                ], provisional=[], clipped=False)
                    result = {'snapshot': {'value': snap}}
                    if 'afterRevision' in action['snapshot']:
                        result = {'unchanged': dict(piSessionID='fixture-session', generation='fixture-generation', revision=1)}
                    reply = dict(type='nativeThread', id=rid, result=result)
                else:
                    raise AssertionError('Unexpected transport request: ' + kind)
                conn.sendall((json.dumps(reply) + '\n').encode())
    except Exception as error:
        errors.append(str(error))

thread = threading.Thread(target=serve)
thread.start()
try:
    subprocess.run(['xcrun', 'simctl', 'install', device, app], check=True)
    env = dict(os.environ, SIMCTL_CHILD_FIXTURE_PORT=str(listener.getsockname()[1]), SIMCTL_CHILD_FIXTURE_SCHEME=os.environ.get('FIXTURE_SCHEME', 'dark'), SIMCTL_CHILD_FIXTURE_SCREEN=os.environ.get('FIXTURE_SCREEN', 'thread'))
    subprocess.run(['xcrun', 'simctl', 'launch', device, 'com.shepherd.thread-fixture'], env=env, check=True)
    time.sleep(6)
    subprocess.run(['xcrun', 'simctl', 'io', device, 'screenshot', os.environ.get('FIXTURE_SHOT', '/tmp/shepherd-ios-thread-fixture.png')], check=True)
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', device, 'com.shepherd.thread-fixture'], check=False)
    listener.close()
    thread.join(timeout=22)
assert not errors, errors
assert not any(kind in seen for kind in ['attach', 'input', 'resize']), seen
if os.environ.get('FIXTURE_SCREEN') == 'fleet':
    assert 'stateFetch' in seen, seen
    print('PASS: simulator rendered the agents list over real TCP')
else:
    assert seen.count('nativeThread') >= 2, seen
    print('PASS: simulator rendered native thread over real TCP and polled without terminal attachment')
PY
