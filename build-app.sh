#!/bin/zsh
# Builds dist/BMR1 Guard.app from the SwiftPM package (release config, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1

APP="dist/BMR1 Guard.app"
BIN=".build/release/BMR1Guard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BMR1Guard"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so macOS treats the bundle as a stable identity (TCC, login items).
codesign --force --sign - --identifier com.youhan.bmr1guard "$APP"

echo "Built: $PWD/$APP"
codesign -dv "$APP" 2>&1 | head -3
