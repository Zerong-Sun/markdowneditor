import Foundation
import AppKit

/// Compile the production models directly; no mock file-opening implementation.
@main
enum DocumentLifecycleTests {
    @MainActor static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MarkdownStudio-document-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let first = directory.appendingPathComponent("中文 文档.md")
        let second = directory.appendingPathComponent("second.MD")
        let missing = directory.appendingPathComponent("missing.md")
        try MarkdownFileIO.write("# First", to: first)
        try MarkdownFileIO.write("# Second", to: second)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw NSError(domain: "DocumentLifecycleTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1
        }

        let workspace = MarkdownWorkspace()
        workspace.openDocuments([first])
        try check(workspace.documents.count == 1, "Replace untouched welcome")
        try check(workspace.selectedDocument.text == "# First", "Load real file content")
        let document = workspace.selectedDocument
        document.text = "# Unsaved"
        document.isDirty = true
        workspace.openDocuments([second, first])
        try check(workspace.documents.count == 2, "Duplicate file reuses tab")
        try check(workspace.selectedDocument === document, "Select existing document")
        try check(document.text == "# Unsaved" && document.isDirty, "Reopen preserves unsaved text")
        let alias = directory.appendingPathComponent("alias.md")
        try manager.createSymbolicLink(at: alias, withDestinationURL: first)
        workspace.openDocuments([alias])
        try check(workspace.documents.count == 2 && workspace.selectedDocument === document, "Symlink reuses tab")
        let hardLink = directory.appendingPathComponent("hard-link.md")
        try manager.linkItem(at: first, to: hardLink)
        workspace.openDocuments([hardLink])
        try check(workspace.documents.count == 2 && workspace.selectedDocument === document, "Hard link reuses tab")
        let caseVariant = directory.appendingPathComponent("SECOND.md")
        if manager.fileExists(atPath: caseVariant.path) {
            workspace.openDocuments([caseVariant])
            try check(workspace.documents.count == 2 && workspace.selectedDocument.fileURL == second, "Case-insensitive filename reuses tab")
            workspace.openDocuments([first])
        }
        workspace.openDocuments([missing])
        try check(workspace.documents.count == 2 && document.text == "# Unsaved", "Failed open preserves documents")
        try check(document.errorMessage?.contains("missing.md") == true, "Failed open names bad input")
        document.errorMessage = nil
        try check(document.save(), "Save succeeds")
        try check(!document.isDirty && document.notice == "已保存", "Successful save clears dirty state")
        try check(try MarkdownFileIO.read(first).text == "# Unsaved", "Save persists real content")
        let priorText = document.text
        try check(!document.load(missing), "Load reports failure")
        try check(document.text == priorText && document.fileURL == first, "Failed load preserves path and content")
        document.fileURL = directory.appendingPathComponent("absent/note.md")
        document.isDirty = true
        try check(!document.save(), "Save reports write failure")
        try check(document.isDirty && document.text == priorText, "Failed save preserves dirty text")
        document.fileURL = first
        document.isDirty = false
        document.errorMessage = nil
        workspace.close(document)
        try check(workspace.documents.count == 1 && workspace.selectedDocument.fileURL == second, "Close selects neighbor")
        workspace.close(workspace.selectedDocument)
        try check(workspace.documents.count == 1 && workspace.selectedDocument.fileURL == nil, "Last tab restores welcome")

        let editedWelcome = MarkdownWorkspace()
        editedWelcome.selectedDocument.text = "Unsaved welcome"
        editedWelcome.selectedDocument.isDirty = true
        editedWelcome.openDocuments([first, second, missing])
        try check(editedWelcome.documents.count == 3, "Keep edited welcome when opening files")
        try check(editedWelcome.documents[0].text == "Unsaved welcome", "Welcome draft not overwritten")
        try check(editedWelcome.selectedDocument.fileURL == second, "Mixed input keeps last successful file")
        try check(editedWelcome.selectedDocument.errorMessage != nil, "Mixed input reports rejected file")
        editedWelcome.close(editedWelcome.documents[1])
        try check(editedWelcome.selectedDocument.fileURL == second, "Closing background tab preserves selection")

        let encoded = directory.appendingPathComponent("encoded.md")
        try MarkdownFileIO.write("中文", to: encoded, encoding: .utf16)
        let encodedDocument = MarkdownDocument()
        try check(encodedDocument.load(encoded), "Load UTF-16 document")
        encodedDocument.text += " 已修改"
        encodedDocument.isDirty = true
        try check(encodedDocument.save(), "Save UTF-16 document")
        try check(try MarkdownFileIO.read(encoded).encoding == .utf16, "Document save retains encoding")
        try check(EditorDisplayMode.source.showsSource && !EditorDisplayMode.source.showsPreview, "Source-only mode")
        try check(EditorDisplayMode.split.showsSource && EditorDisplayMode.split.showsPreview, "Split mode")
        try check(!EditorDisplayMode.reading.showsSource && EditorDisplayMode.reading.showsPreview, "Read-only mode hides source")
        try check(EditorDisplayMode(rawValue: EditorDisplayMode.reading.rawValue) == .reading, "Reading mode can be persisted")
        let defaultsName = "MarkdownStudio-options-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        try check(PDFExportOptions.load(from: defaults).normalizedFontSize == 16, "Default PDF font size")
        PDFExportOptions(style: .darkSans, fontSize: 22).save(to: defaults)
        let remembered = PDFExportOptions.load(from: defaults)
        try check(remembered.style == .darkSans && remembered.fontSize == 22, "Remember PDF options")
        try check(PDFExportOptions(style: .lightSans, fontSize: .nan).normalizedFontSize == 16, "Reject non-finite font size")
        try check(PDFExportOptions(style: .lightSans, fontSize: 100).normalizedFontSize == 32, "Clamp large font size")
        try check(PDFExportOptions(style: .lightSans, fontSize: 0).normalizedFontSize == 8, "Clamp small font size")
        defaults.removeObject(forKey: "pdf.titleFontSize")
        defaults.set("book", forKey: "pdf.style")
        try check(PDFExportOptions.load(from: defaults).titleFontSize == 44 && PDFExportOptions.load(from: defaults).style == .lightSerif, "Legacy body size preserves its two-times H1 size during migration")
        try check(PDFExportStyle.allCases.count == 4 && Set(PDFExportStyle.allCases.map { "\($0.isDark)-\($0.isSerif)" }).count == 4, "Four presets cover every light/dark and serif/sans combination")
        try check(PDFExportStyle.migrated("clean") == .lightSans && PDFExportStyle.migrated("book") == .lightSerif && PDFExportStyle.migrated("night") == .darkSans && PDFExportStyle.migrated("paper") == .lightSerif, "Migrate the previous four style preferences")
        let customized = PDFExportOptions(style: .darkSerif, fontSize: 13, titleFontSize: 48, topMargin: .large, bottomMargin: .small, horizontalMargin: .large, paperSize: .letter, orientation: .landscape, lineSpacing: .relaxed, showsHeader: true, showsPageNumbers: false, decorationSize: .large)
        customized.save(to: defaults)
        try check(PDFExportOptions.load(from: defaults) == customized, "Remember every print and typography setting")
        try check(PDFExportOptions(titleFontSize: .nan).normalizedTitleFontSize == 32, "Non-finite title size uses default")
        try check(PDFExportOptions(titleFontSize: 100).normalizedTitleFontSize == 72 && PDFExportOptions(titleFontSize: 0).normalizedTitleFontSize == 16, "Bound title font separately from body font")
        try check(customized.appearance.additionalCSS.contains("font-size:48pt") && customized.appearance.additionalCSS.contains("Georgia"), "Custom title font and serif family reach export CSS")
        defaults.set("invalid", forKey: "pdf.topMargin")
        defaults.set("invalid", forKey: "pdf.paperSize")
        try check(PDFExportOptions.load(from: defaults).topMargin == .medium && PDFExportOptions.load(from: defaults).paperSize == .a4, "Invalid stored options fall back safely")
        for paper in PDFPaperSize.allCases {
            for orientation in PDFOrientation.allCases {
                for top in PDFMarginSize.allCases {
                    for bottom in PDFMarginSize.allCases {
                        let options = PDFExportOptions(topMargin: top, bottomMargin: bottom, horizontalMargin: .large, paperSize: paper, orientation: orientation)
                        let geometry = PDFPageLayout.Geometry(options: options)
                        try check(geometry.contentWidth > 0 && geometry.contentHeight > 0, "Positive printable area for every paper/orientation/margin combination")
                        let pages = try PDFPageLayout.slices(for: .init(height: 2300, ranges: []), layout: geometry)
                        try check(pages.allSatisfy { abs($0.width - geometry.contentWidth) < 0.01 } && abs(pages.last!.maxY - 2300) < 0.01, "Custom page geometry covers the whole document without gaps")
                    }
                }
            }
        }
        let plannerHeight = Double(PDFPageLayout.contentHeight)
        let plainPages = try PDFPageLayout.slices(for: .init(height: plannerHeight * 2 + 10, ranges: []))
        try check(plainPages.count == 3, "Paginate full document")
        try check(abs(plainPages.last!.maxY - (plannerHeight * 2 + 10)) < 0.01, "Pagination includes last pixels")
        let paragraphPages = try PDFPageLayout.slices(for: .init(height: plannerHeight + 120, ranges: [.init(start: plannerHeight - 60, end: plannerHeight + 60)]))
        try check(paragraphPages.first!.maxY == plannerHeight - 60, "Avoid splitting a paragraph or table row")
        try check(paragraphPages[0].maxY == paragraphPages[1].minY, "Page slices remain contiguous")
        try check(try PDFPageLayout.slices(for: .init(height: 0, ranges: [])).count == 1, "Empty document still has one page")
        do {
            _ = try PDFPageLayout.slices(for: .init(height: .infinity, ranges: []))
            throw NSError(domain: "DocumentLifecycleTests", code: 2)
        } catch PDFExporter.PDFExportError.invalidLayout { checks += 1 }

        let conflictWorkspace = MarkdownWorkspace()
        conflictWorkspace.openDocuments([first, second])
        let conflict = conflictWorkspace.documents[0]
        conflict.edit("my local edit")
        let localText = conflict.text
        try MarkdownFileIO.write("external edit", to: first)
        try check(!conflict.save(), "Saving rejects external changes")
        try check(conflict.isDirty && conflict.text == localText, "Conflict retains local draft")
        try check(try MarkdownFileIO.read(first).text == "external edit", "Conflict retains external version")
        try check(conflict.errorMessage?.contains("其他程序") == true, "Conflict explains recovery")
        let copy = directory.appendingPathComponent("recovered.md")
        try check(conflict.save(to: copy), "Save As to new path recovers draft")
        try check(!conflict.isDirty && conflict.fileURL == copy, "Save As updates path only on success")
        conflict.edit("another edit")
        try check(!conflict.save(to: second), "Save As rejects another open tab's file")
        try check(conflict.isDirty && conflict.fileURL == copy, "Duplicate target rejection preserves local state")
        try check(try MarkdownFileIO.read(second).text == "# Second", "Duplicate target rejection preserves other file")
        if manager.fileExists(atPath: caseVariant.path) {
            try check(!conflict.save(to: caseVariant), "Save As detects a case variant of another open tab")
        }
        try check(conflict.load(copy), "Load resets baseline")
        conflict.edit("temporary change")
        conflict.edit(localText)
        try check(!conflict.isDirty, "Editing/undoing back to saved text clears dirty state")
        let external = URL(string: "https://example.com/help")!
        let local = URL(fileURLWithPath: "/tmp/another.md")
        try check(MarkdownLinkDestination.resolve(external, currentURL: nil) == .external(external), "HTTP links use external browser")
        try check(MarkdownLinkDestination.resolve(local, currentURL: nil) == .markdown(local), "Markdown file links route to document workspace")
        try check(MarkdownLinkDestination.resolve(URL(string: "x-apple.systempreferences:settings")!, currentURL: nil) == .blocked, "Arbitrary app schemes cannot launch")
        try check(MarkdownLinkDestination.resolve(URL(string: "https://example.com/help#section")!, currentURL: external) == .anchor, "Same-document anchors remain in preview")
        try check(MarkdownLinkDestination.resolve(URL(fileURLWithPath: "/tmp/program.command"), currentURL: nil) == .blocked, "Non-Markdown local programs cannot launch")
        let closing = MarkdownWorkspace()
        closing.openDocuments([first])
        let draft = closing.selectedDocument
        closing.windowCloseApproved = true
        draft.edit("unsaved close test")
        try check(!closing.windowCloseApproved, "New edits revoke any earlier window-close approval")
        draft.confirmUnsavedChanges = { _ in .cancel }
        closing.close(draft)
        try check(closing.selectedDocument === draft && draft.isDirty, "Cancel close retains draft and selection")
        try check(!closing.canCloseAllDocuments(), "Cancel blocks window close/quit")
        let lifecycleDelegate = MarkdownStudioAppDelegate()
        lifecycleDelegate.attach(closing)
        try check(lifecycleDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "App delegate refuses quit on cancellation")
        closing.windowCloseApproved = true
        _ = lifecycleDelegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        try check(!closing.windowCloseApproved, "Reopening revokes stale close approval")
        draft.confirmUnsavedChanges = { _ in .save }
        draft.fileURL = directory.appendingPathComponent("absent/cannot-save.md")
        closing.close(draft)
        try check(closing.selectedDocument === draft && draft.isDirty, "Save failure blocks close and retains draft")
        draft.fileURL = first
        try check(draft.shouldDiscardChanges(), "Successful save permits close")
        try check(try MarkdownFileIO.read(first).text == "unsaved close test", "Close's Save decision actually writes data")
        draft.edit("discarded version")
        draft.confirmUnsavedChanges = { _ in .discard }
        try check(closing.canCloseAllDocuments(), "Explicit discard permits close")
        try check(lifecycleDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow, "App delegate permits quit after explicit discard")
        closing.close(draft)
        try check(closing.selectedDocument !== draft, "Discard closes the dirty tab")
        try check(try MarkdownFileIO.read(first).text == "unsaved close test", "Discard never writes discarded edits")
        print("Document lifecycle tests passed: \(checks) checks.")
    }
}
