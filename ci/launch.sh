#!/bin/bash
# Builds the app for the simulator, launches it on a small and a large iPhone, checks it stays alive,
# and takes screenshots. The simulator has no camera, so it shows the first-run guide and the
# "camera not available" screen; this checks start-up, layout and that nothing crashes.
set -u
OUT=${1:-ci-out}
mkdir -p "$OUT"
xcodebuild -project Aimframe.xcodeproj -target Aimframe -configuration Debug -sdk iphonesimulator \
  SYMROOT="$PWD/simbuild" CODE_SIGNING_ALLOWED=NO build > sim-build.log 2>&1 || { echo "LAUNCH: simulator build failed"; tail -30 sim-build.log; exit 1; }
APP=simbuild/Debug-iphonesimulator/Aimframe.app
BID=com.aimframe.app
pick() {
  xcrun simctl list devices available -j | python3 -c "
import json,sys
want=sys.argv[1]
devs=[d for r,l in json.load(sys.stdin)['devices'].items() if 'iOS' in r for d in l]
m=[d for d in devs if want in d['name']]
print(m[-1]['udid'] if m else '')" "$1"
}
status=0
for NAME in "iPhone SE" "Pro Max"; do
  UDID=$(pick "$NAME")
  if [ -z "$UDID" ]; then echo "LAUNCH: no simulator matching $NAME"; continue; fi
  TAG=$(echo "$NAME" | tr ' ' '-' | tr 'A-Z' 'a-z')
  xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch "$UDID" "$BID" > /dev/null; sleep 8
  xcrun simctl io "$UDID" screenshot "$OUT/launch-$TAG-onboarding.png" > /dev/null 2>&1
  if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BID"; then echo "LAUNCH PASS $NAME: alive on the first-run guide"; else echo "LAUNCH FAIL $NAME: not running after start"; status=1; fi
  xcrun simctl terminate "$UDID" "$BID" > /dev/null 2>&1
  xcrun simctl spawn "$UDID" defaults write "$BID" onboardingDone -bool YES
  xcrun simctl privacy "$UDID" grant camera "$BID" > /dev/null 2>&1
  xcrun simctl launch "$UDID" "$BID" > /dev/null; sleep 8
  xcrun simctl io "$UDID" screenshot "$OUT/launch-$TAG-camera.png" > /dev/null 2>&1
  if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BID"; then echo "LAUNCH PASS $NAME: alive after the guide (no camera in the simulator)"; else echo "LAUNCH FAIL $NAME: crashed after the guide"; status=1; fi
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1
done
exit $status
