#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/Markdown Studio.app"
BUILD_PATH="$SCRIPT_DIR/.build/release/MarkdownStudio"

cd "$SCRIPT_DIR"
swift build -c release
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_PATH" "$APP_PATH/Contents/MacOS/MarkdownStudio"
cp "$SCRIPT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
rm -rf "$APP_PATH/MarkdownStudio_MarkdownStudio.bundle"
cp -R "$SCRIPT_DIR/.build/arm64-apple-macosx/release/MarkdownStudio_MarkdownStudio.bundle" "$APP_PATH/Contents/Resources/"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH" >/dev/null
xattr -cr "$APP_PATH"
echo "Built: $APP_PATH"
