import Foundation

@main
enum FileIOTests {
    static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("MarkdownStudio-file-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw NSError(domain: "FileIOTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks += 1
        }
        func rejects(_ name: String, _ action: () throws -> Void) throws {
            do { try action() } catch { checks += 1; return }
            throw NSError(domain: "FileIOTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(name)"])
        }

        for ext in MarkdownFileIO.markdownExtensions + ["MD", "txt", ""] {
            let url = directory.appendingPathComponent("中文 文件 \(ext)").appendingPathExtension(ext)
            try MarkdownFileIO.write("# 标题\n\n中文 ✅", to: url)
            try check(try MarkdownFileIO.read(url).text == "# 标题\n\n中文 ✅", "Read extension \(ext)")
        }
        let empty = directory.appendingPathComponent("empty.md")
        try MarkdownFileIO.write("", to: empty)
        try check(try MarkdownFileIO.read(empty).text.isEmpty, "Empty file")

        let bom = directory.appendingPathComponent("bom.md")
        try (Data([0xef, 0xbb, 0xbf]) + Data("# BOM 中文".utf8)).write(to: bom)
        try check(try MarkdownFileIO.read(bom).text == "# BOM 中文", "UTF-8 BOM")
        for encoding in [String.Encoding.utf16, .utf32] {
            let url = directory.appendingPathComponent("encoding-\(encoding.rawValue).markdown")
            try MarkdownFileIO.write("# 中文 \(encoding.rawValue)", to: url, encoding: encoding)
            let loaded = try MarkdownFileIO.read(url)
            try check(loaded.text == "# 中文 \(encoding.rawValue)", "BOM decoding")
            try MarkdownFileIO.write(loaded.text + "\n已编辑", to: url, encoding: loaded.encoding)
            try check(try MarkdownFileIO.read(url).text.hasSuffix("已编辑"), "Encoding-preserving save")
        }
        let invalid = directory.appendingPathComponent("invalid.md")
        try Data([0xff, 0x80, 0x00, 0x01]).write(to: invalid)
        try rejects("Invalid UTF-8") { _ = try MarkdownFileIO.read(invalid) }
        let binary = directory.appendingPathComponent("binary.md")
        try Data([0x41, 0x00, 0x42]).write(to: binary)
        try rejects("Binary text") { _ = try MarkdownFileIO.read(binary) }
        try rejects("Folder") { _ = try MarkdownFileIO.read(directory) }
        try rejects("Missing file") { _ = try MarkdownFileIO.read(directory.appendingPathComponent("missing.md")) }
        try rejects("Network URL") { _ = try MarkdownFileIO.read(URL(string: "https://example.com/note.md")!) }
        try rejects("Wrong extension") { _ = try MarkdownFileIO.read(directory.appendingPathComponent("note.pdf")) }
        try rejects("Failed write") { try MarkdownFileIO.write("keep", to: directory.appendingPathComponent("missing/note.md")) }
        try rejects("Non-local write") { try MarkdownFileIO.write("keep", to: URL(string: "https://example.com/note.md")!) }
        try rejects("Unsupported save extension") { try MarkdownFileIO.write("keep", to: directory.appendingPathComponent("note.pdf")) }

        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try MarkdownFileIO.createNote(in: directory, text: "first", date: fixedDate)
        let second = try MarkdownFileIO.createNote(in: directory, text: "second", date: fixedDate)
        try check(first != second, "New note name collision")
        try check(first.lastPathComponent.hasPrefix("note_"), "New note date name")
        try check(try MarkdownFileIO.read(first).text == "first", "Existing note not overwritten")
        try check(try MarkdownFileIO.read(second).text == "second", "New note content")
        let link = directory.appendingPathComponent("link.md")
        try manager.createSymbolicLink(at: link, withDestinationURL: first)
        try check(try MarkdownFileIO.read(link).text == "first", "Read through symlink")
        try MarkdownFileIO.write("updated", to: link)
        try check(try MarkdownFileIO.read(first).text == "updated", "Save updates symlink target")
        try check(try manager.destinationOfSymbolicLink(atPath: link.path) == first.path, "Save preserves symlink")
        let snapshot = try MarkdownFileIO.read(first)
        let revision = try MarkdownFileIO.write("revision two", to: first, expectedRevision: snapshot.revision)
        try check(revision == MarkdownFileIO.read(first).revision, "Successful write returns new content fingerprint")
        try rejects("External change conflict") { try MarkdownFileIO.write("must not overwrite", to: first, expectedRevision: snapshot.revision) }
        try check(try MarkdownFileIO.read(first).text == "revision two", "Conflict preserves disk content")
        try manager.removeItem(at: first)
        try rejects("External delete conflict") { try MarkdownFileIO.write("must not recreate", to: first, expectedRevision: revision) }
        try check(!manager.fileExists(atPath: first.path), "Conflict does not recreate deleted file")
        try rejects("NUL save") { try MarkdownFileIO.write("a\0b", to: empty) }
        try check(try MarkdownFileIO.read(empty).text.isEmpty, "Rejected save preserves original bytes")
        let oversized = directory.appendingPathComponent("oversized.md")
        manager.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(MarkdownFileIO.maximumFileSize + 1))
        try handle.close()
        try rejects("Oversized sparse file") { _ = try MarkdownFileIO.read(oversized) }
        print("File lifecycle tests passed: \(checks) checks.")
    }
}
