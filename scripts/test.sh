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
  "$PROJECT_DIR/Sources/MarkdownNavigation.swift" \
  "$PROJECT_DIR/Sources/PDFExporter.swift" \
  "$PROJECT_DIR/Sources/PDFExportOptions.swift" \
  "$PROJECT_DIR/Sources/PDFExportOptionsPanel.swift" \
  "$PROJECT_DIR/Sources/MarkdownStudioApp.swift" \
  "$BUILD_DIR/MarkdownStudio.build/DerivedSources/resource_bundle_accessor.swift" \
  "$PROJECT_DIR/Tests/DocumentLifecycleTests.swift" -o "$TEST_DIR/document-tests"
"$TEST_DIR/document-tests"
swiftc -D DOCUMENT_LIFECYCLE_TESTING \
  "$PROJECT_DIR/Sources/MarkdownFileIO.swift" \
  "$PROJECT_DIR/Sources/MarkdownNavigation.swift" \
  "$PROJECT_DIR/Sources/PDFExporter.swift" \
  "$PROJECT_DIR/Sources/PDFExportOptions.swift" \
  "$PROJECT_DIR/Sources/PDFExportOptionsPanel.swift" \
  "$PROJECT_DIR/Sources/MarkdownStudioApp.swift" \
  "$BUILD_DIR/MarkdownStudio.build/DerivedSources/resource_bundle_accessor.swift" \
  "$PROJECT_DIR/Tests/PDFExportIntegrationTests.swift" -o "$TEST_DIR/pdf-tests"
PDF_TEST_APP="$TEST_DIR/Markdown Studio Export Tests.app"
mkdir -p "$PDF_TEST_APP/Contents/MacOS" "$PDF_TEST_APP/Contents/Resources"
cp "$TEST_DIR/pdf-tests" "$PDF_TEST_APP/Contents/MacOS/MarkdownStudioPDFTests"
cp "$PROJECT_DIR/Tests/Support/PDFTests-Info.plist" "$PDF_TEST_APP/Contents/Info.plist"
cp -R "$BUILD_DIR/MarkdownStudio_MarkdownStudio.bundle" "$PDF_TEST_APP/Contents/Resources/"
codesign --force --deep --sign - "$PDF_TEST_APP" >/dev/null
"$PDF_TEST_APP/Contents/MacOS/MarkdownStudioPDFTests" "${MARKDOWNSTUDIO_PDF_TEST_OUTPUT:-$TEST_DIR/pdfs}"
swiftc -D DOCUMENT_LIFECYCLE_TESTING \
  "$PROJECT_DIR/Sources/MarkdownFileIO.swift" \
  "$PROJECT_DIR/Sources/MarkdownNavigation.swift" \
  "$PROJECT_DIR/Sources/PDFExporter.swift" \
  "$PROJECT_DIR/Sources/PDFExportOptions.swift" \
  "$PROJECT_DIR/Sources/PDFExportOptionsPanel.swift" \
  "$PROJECT_DIR/Sources/MarkdownStudioApp.swift" \
  "$BUILD_DIR/MarkdownStudio.build/DerivedSources/resource_bundle_accessor.swift" \
  "$PROJECT_DIR/Tests/EditorQualityIntegrationTests.swift" -o "$TEST_DIR/editor-quality-tests"
cp "$TEST_DIR/editor-quality-tests" "$PDF_TEST_APP/Contents/MacOS/MarkdownStudioPDFTests"
codesign --force --deep --sign - "$PDF_TEST_APP" >/dev/null
"$PDF_TEST_APP/Contents/MacOS/MarkdownStudioPDFTests"
