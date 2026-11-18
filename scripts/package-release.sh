#!/bin/sh
# Packages a release disk image for the Homebrew cask: RambleFlow.app plus the timed-runtime folder
# (Python and the Phonon sidecar). Model weights stay out: the app downloads them on first launch, which
# keeps the image under GitHub's 2 GiB limit for a release file.
#
# Usage: scripts/package-release.sh VERSION APP TIMED_RUNTIME OUTPUT_DIR
#   APP            a signed app built with app/build.py --bundle --fast-runtime --refiner-url ...
#   TIMED_RUNTIME  a folder holding python/ and Phonon.app/ (an asr-model/ folder in it is left out)
# Set NOTARY_PROFILE to a notarytool keychain profile to notarize and staple the image.
set -eu
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 VERSION APP TIMED_RUNTIME OUTPUT_DIR" >&2
  exit 2
fi
version=$1 app=$2 runtime=$3 output=$4
limit=2147483648
case "$version" in *[!0-9.]*|'') echo "VERSION must look like 0.1.0" >&2; exit 2 ;; esac
[ -x "$app/Contents/MacOS/RambleFlow" ] || { echo "No RambleFlow app at $app" >&2; exit 1; }
[ -x "$runtime/python/bin/python" ] && [ -d "$runtime/Phonon.app" ] || { echo "TIMED_RUNTIME needs python/ and Phonon.app/" >&2; exit 1; }
# A release app must download its refiner, not carry it.
manifest="$app/Contents/Resources/runtime/app/default-refiner.json"
grep -q '"url"' "$manifest" || { echo "The app bundles its refiner. Build it with --refiner-url." >&2; exit 1; }
find "$app/Contents/Resources/runtime/models" -name '*.gguf' | grep -q . && { echo "The app still contains model weights." >&2; exit 1; }
codesign --verify --deep --strict "$app"
codesign --verify --deep --strict "$runtime/Phonon.app"

mkdir -p "$output"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/RambleFlow.app"
mkdir "$stage/timed-runtime"
ditto "$runtime/python" "$stage/timed-runtime/python"
ditto "$runtime/Phonon.app" "$stage/timed-runtime/Phonon.app"
# Byte-code caches and weights never ship: caches break the helper's signature, weights are downloaded.
find "$stage/timed-runtime" \( -name '__pycache__' -o -name '*.pyc' \) -prune -exec rm -rf {} +
# Checked again on the staged copies: removing a file that was part of a signature would break it here.
codesign --verify --deep --strict "$stage/RambleFlow.app"
codesign --verify --deep --strict "$stage/timed-runtime/Phonon.app"
if find "$stage/timed-runtime" \( -name '*.gguf' -o -name '*.safetensors' \) | grep -q .; then
  echo "Model weights found in the staged timed runtime." >&2
  exit 1
fi

image="$output/RambleFlow-$version.dmg"
rm -f "$image"
hdiutil create -volname "RambleFlow $version" -srcfolder "$stage" -fs APFS -format ULFO -quiet "$image"
identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)
if [ -z "$identity" ]; then
  echo "The app is not signed with a Developer ID, so the image would not pass Gatekeeper." >&2
  exit 1
fi
codesign --force --sign "$identity" --timestamp "$image"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$image" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$image"
fi
size=$(stat -f %z "$image")
if [ "$size" -ge "$limit" ]; then
  echo "$image is $size bytes, over GitHub's 2 GiB release file limit." >&2
  exit 1
fi
echo "image=$image"
echo "bytes=$size"
echo "sha256=$(shasum -a 256 "$image" | cut -d ' ' -f 1)"
