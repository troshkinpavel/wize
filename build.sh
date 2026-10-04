#!/bin/sh
# Builds build/Wize.app. Signs with the first "Apple Development" identity if present
# (keeps the Accessibility grant stable across rebuilds), otherwise ad-hoc.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Wize.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Wize "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
