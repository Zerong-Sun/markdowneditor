import Foundation

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
        PDFExportOptions(style: .night, fontSize: 22).save(to: defaults)
        let remembered = PDFExportOptions.load(from: defaults)
        try check(remembered.style == .night && remembered.fontSize == 22, "Remember PDF options")
        try check(PDFExportOptions(style: .clean, fontSize: .nan).normalizedFontSize == 16, "Reject non-finite font size")
        try check(PDFExportOptions(style: .clean, fontSize: 100).normalizedFontSize == 26, "Clamp large font size")
        try check(PDFExportOptions(style: .clean, fontSize: 0).normalizedFontSize == 11, "Clamp small font size")
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
        print("Document lifecycle tests passed: \(checks) checks.")
    }
}
