#!/bin/bash
# Builds the app in release mode and wraps it in a macOS .app bundle, ad-hoc
# signed, zipped for download. Universal (Apple Silicon and Intel), macOS 14 or later.
#
#     tools/package/package-app.sh [OUTPUT_DIR] [VERSION]
#
# Without a Developer ID signature macOS warns on first launch: right-click
# the app and choose Open, or run `xattr -dr com.apple.quarantine "Audio Analyzer.app"`.
set -euo pipefail

OUT="${1:-dist}"
VERSION="${2:-0.1.0}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
APP_NAME="Audio Analyzer"
EXECUTABLE="AudioAnalyzer"
BUNDLE_ID="com.newconstellation.audioanalyzer"
HERE="$(cd "$(dirname "$0")" && pwd)"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product AnalyzerApp
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/AnalyzerApp"
lipo -info "$BIN"
lipo "$BIN" -verify_arch arm64 x86_64

APP="$OUT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
sed -e "s/__NAME__/$APP_NAME/g" -e "s/__EXECUTABLE__/$EXECUTABLE/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$HERE/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

codesign --force --sign - --entitlements "$HERE/AudioAnalyzer.entitlements" --timestamp=none "$APP"
codesign --verify --verbose "$APP"

(cd "$OUT" && ditto -c -k --keepParent "$APP_NAME.app" "AudioAnalyzer-$VERSION-$BUILD_NUMBER.zip")
echo "Built $OUT/AudioAnalyzer-$VERSION-$BUILD_NUMBER.zip"
