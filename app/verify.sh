#!/bin/sh
set -eu
node --check app/core.mjs
node --check app/worker.mjs
node --check app/timed-asr.mjs
node --check scripts/refiner-common.mjs
node --check app/select-model.mjs
node --test app/tests/*.test.mjs
python3 -m py_compile app/build.py
swiftc -swift-version 5 -typecheck app/native/*.swift
selftest="$(mktemp -d)"
trap 'rm -r "$selftest"' EXIT
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon app/native/*.swift -o "$selftest/selftest"
"$selftest/selftest" --self-test
# Builds every page of the window off screen, in light and dark, with no models or microphone.
"$selftest/selftest" --ui-preview "$selftest" > /dev/null
for page in home review vocabulary settings; do for look in light dark; do test -s "$selftest/window-$page-$look.png"; done; done
for step in 1 2 3 4 1-downloading 3-downloading 3-loading; do for look in light dark; do test -s "$selftest/setup-$step-$look.png"; done; done
git diff --check
