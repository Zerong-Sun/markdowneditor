import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// File decoding and writes are shared by every document-opening entry point.
enum MarkdownFileIO {
    static let maximumFileSize = 20 * 1024 * 1024
    static let markdownExtensions = ["md", "markdown", "mdown", "mkdn", "mkd"]
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    static var openableTypes: [UTType] {
        [markdownType, .plainText] + markdownExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func refersToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.isFileURL, rhs.isFileURL else { return false }
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left == right { return true }
        // APFS commonly ignores case; URL string equality does not. Resource
        // identity also prevents opening a hard link as a second editable copy.
        guard let leftID = (try? left.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject,
              let rightID = (try? right.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject else { return false }
        return leftID.isEqual(rightID)
    }

    struct LoadedFile {
        let text: String
        let encoding: String.Encoding
        let revision: Revision
    }

    struct Revision: Equatable {
        fileprivate let digest: SHA256.Digest
        init(data: Data) { digest = SHA256.hash(data: data) }
    }

    enum FileError: LocalizedError {
        case nonLocalURL, unsupportedExtension, notAFile, invalidEncoding, tooLarge, changedOnDisk

        var errorDescription: String? {
            switch self {
            case .nonLocalURL: "请选择本机上的 Markdown 文件。"
            case .unsupportedExtension: "支持 .md、.markdown、.mdown、.mkdn、.mkd 和 .txt 文件。"
            case .notAFile: "请选择文件，不能打开文件夹。"
            case .invalidEncoding: "文件不是有效的 UTF-8 或带 BOM 的 UTF-16/UTF-32 文本。"
            case .tooLarge: "文件超过 20 MiB，请拆分后打开或保存。"
            case .changedOnDisk: "文件已被其他程序修改、替换或删除。为保护磁盘上的版本，本次未保存。请另存为其他文件，或重新载入后再编辑。"
            }
        }
    }

    private static func validate(_ url: URL) throws {
        guard url.isFileURL else { throw FileError.nonLocalURL }
        let ext = url.pathExtension.lowercased()
        guard ext.isEmpty || markdownExtensions.contains(ext) || ext == "txt" else {
            throw FileError.unsupportedExtension
        }
    }

    static func read(_ url: URL) throws -> LoadedFile {
        try validate(url)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let resolvedURL = url.resolvingSymlinksInPath()
        let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw FileError.notAFile }
        guard (values.fileSize ?? 0) <= maximumFileSize else { throw FileError.tooLarge }
        let data = try Data(contentsOf: resolvedURL)
        guard data.count <= maximumFileSize else { throw FileError.tooLarge }
        let encoding: String.Encoding
        // Test UTF-32 before UTF-16: their little-endian BOM prefixes overlap.
        if data.starts(with: [0xff, 0xfe, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xfe, 0xff]) {
            encoding = .utf32
        } else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            encoding = .utf16
        } else {
            encoding = .utf8
        }
        guard var text = String(data: data, encoding: encoding), !text.contains("\0") else {
            throw FileError.invalidEncoding
        }
        if text.first == "\u{feff}" { text.removeFirst() }
        return LoadedFile(text: text, encoding: encoding, revision: Revision(data: data))
    }

    @discardableResult
    static func write(_ text: String, to url: URL, encoding: String.Encoding = .utf8, expectedRevision: Revision? = nil) throws -> Revision {
        try validate(url)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = text.data(using: encoding), !text.contains("\0") else { throw FileError.invalidEncoding }
        guard data.count <= maximumFileSize else { throw FileError.tooLarge }
        let destination = url.resolvingSymlinksInPath()
        if let expectedRevision {
            // Compare bytes, not timestamps: an external editor can preserve dates.
            guard let current = try? read(destination), current.revision == expectedRevision else { throw FileError.changedOnDisk }
        }
        try data.write(to: destination, options: .atomic)
        return Revision(data: data)
    }

    static func createNote(in directory: URL, text: String, date: Date = Date()) throws -> URL {
        guard directory.isFileURL else { throw FileError.nonLocalURL }
        guard text.utf8.count <= maximumFileSize else { throw FileError.tooLarge }
        guard !text.contains("\0") else { throw FileError.invalidEncoding }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "note_\(formatter.string(from: date))"
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)_\(suffix)"
            let candidate = directory.appendingPathComponent(name).appendingPathExtension("md")
            do {
                // Do not overwrite a note created concurrently by another process.
                try Data(text.utf8).write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                suffix += 1
            }
        }
    }
}
