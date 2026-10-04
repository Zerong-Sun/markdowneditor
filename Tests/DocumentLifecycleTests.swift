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
        print("Document lifecycle tests passed: \(checks) checks.")
    }
}
