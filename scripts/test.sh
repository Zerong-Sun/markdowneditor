#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"
BUILD_CACHE="${MARKDOWNSTUDIO_BUILD_CACHE:-$HOME/Library/Caches/MarkdownStudio/build}"
swift build -c release --scratch-path "$BUILD_CACHE"
node "$SCRIPT_DIR/smoke-test.js"
TEST_DIR="$(mktemp -d /tmp/markdownstudio-tests.XXXXXX)"
trap '[[ "$TEST_DIR" == /tmp/markdownstudio-tests.* ]] && rm -r -- "$TEST_DIR"' EXIT
swiftc "$PROJECT_DIR/Sources/MarkdownFileIO.swift" "$PROJECT_DIR/Tests/FileIOTests.swift" -o "$TEST_DIR/file-tests"
"$TEST_DIR/file-tests"
BUILD_DIR="$(swift build -c release --scratch-path "$BUILD_CACHE" --show-bin-path)"
swiftc -D DOCUMENT_LIFECYCLE_TESTING \
  "$PROJECT_DIR/Sources/MarkdownFileIO.swift" \
  "$PROJECT_DIR/Sources/MarkdownStudioApp.swift" \
  "$BUILD_DIR/MarkdownStudio.build/DerivedSources/resource_bundle_accessor.swift" \
  "$PROJECT_DIR/Tests/DocumentLifecycleTests.swift" -o "$TEST_DIR/document-tests"
"$TEST_DIR/document-tests"
