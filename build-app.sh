#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/Markdown Studio.app"

cd "$SCRIPT_DIR"
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_PATH="$BUILD_DIR/MarkdownStudio"
RESOURCE_BUNDLE="$BUILD_DIR/MarkdownStudio_MarkdownStudio.bundle"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_PATH" "$APP_PATH/Contents/MacOS/MarkdownStudio"
cp "$SCRIPT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$SCRIPT_DIR/Assets/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
rm -rf "$APP_PATH/MarkdownStudio_MarkdownStudio.bundle"
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH" >/dev/null
echo "Built: $APP_PATH"
