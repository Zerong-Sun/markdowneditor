import Foundation
import UniformTypeIdentifiers

/// File decoding and writes are shared by every document-opening entry point.
enum MarkdownFileIO {
    static let markdownExtensions = ["md", "markdown", "mdown", "mkdn", "mkd"]
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    static var openableTypes: [UTType] {
        [markdownType, .plainText] + markdownExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    struct LoadedFile {
        let text: String
        let encoding: String.Encoding
    }

    enum FileError: LocalizedError {
        case nonLocalURL, unsupportedExtension, notAFile, invalidEncoding

        var errorDescription: String? {
            switch self {
            case .nonLocalURL: "请选择本机上的 Markdown 文件。"
            case .unsupportedExtension: "支持 .md、.markdown、.mdown、.mkdn、.mkd 和 .txt 文件。"
            case .notAFile: "请选择文件，不能打开文件夹。"
            case .invalidEncoding: "文件不是有效的 UTF-8 或带 BOM 的 UTF-16/UTF-32 文本。"
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
        let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw FileError.notAFile }
        let data = try Data(contentsOf: resolvedURL)
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
        return LoadedFile(text: text, encoding: encoding)
    }

    static func write(_ text: String, to url: URL, encoding: String.Encoding = .utf8) throws {
        try validate(url)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try text.write(to: url.resolvingSymlinksInPath(), atomically: true, encoding: encoding)
    }

    static func createNote(in directory: URL, text: String, date: Date = Date()) throws -> URL {
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
