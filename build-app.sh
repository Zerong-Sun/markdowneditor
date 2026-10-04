#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Keep the signed product outside iCloud-synced Documents folders, which can add
# Finder metadata during codesigning. Override explicitly if a different output is needed.
APP_PATH="${MARKDOWNSTUDIO_APP_PATH:-$HOME/Library/Caches/MarkdownStudio/Markdown Studio.app}"
if [[ "$APP_PATH" != /*.app ]]; then
  echo "MARKDOWNSTUDIO_APP_PATH must be an absolute .app path." >&2
  exit 1
fi

cd "$SCRIPT_DIR"
BUILD_CACHE="${MARKDOWNSTUDIO_BUILD_CACHE:-$HOME/Library/Caches/MarkdownStudio/build}"
swift build -c release --scratch-path "$BUILD_CACHE"
BUILD_DIR="$(swift build -c release --scratch-path "$BUILD_CACHE" --show-bin-path)"
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
codesign --verify --deep --strict "$APP_PATH"
echo "Built: $APP_PATH"
