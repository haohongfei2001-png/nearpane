#!/bin/bash
# Explicit device-only experiment: never invoked by build or regression scripts.
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 077
out=build/verification/p422
mkdir -p "$out"
apps="$(cat build/window-lab/apps-path.txt)"
session="$(mktemp -d "$apps/regular-XXXXXXXX")"
for name in NearpaneFrameController NearpaneRegularFixture; do
    /usr/bin/codesign --verify --strict --deep "-R=identifier org.nearpane.lab.$name" "$apps/$name.app"
    shasum -a 256 "$apps/$name.app/Contents/MacOS/$name"
done > "$session.seal"
# LaunchServices apps may not have access to Documents. Exchange only our own
# synthetic evidence in the private cache; copy it out after the bounded trial.
result=0
"$apps/NearpaneFrameController.app/Contents/MacOS/NearpaneFrameController" regular-compare "$session" > "$session.stdout" 2> "$session.stderr" || result=$?
mv "$session.seal" "$session.stdout" "$session.stderr" "$session/"
mv "$session" "$out/"
printf 'session=%s exit=%d\n' "$out/${session##*/}" "$result"
exit "$result"
