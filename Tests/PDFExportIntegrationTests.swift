import AppKit
import PDFKit
import SwiftUI
import WebKit

/// Runs the real WebKit renderer and PDF writer without an editor or printer window.
@main
enum PDFExportIntegrationTests {
    @MainActor static func main() {
        do { try runTests() }
        catch {
            FileHandle.standardError.write(Data("PDF integration FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func runTests() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let marker = directory.appendingPathComponent(".markdownstudio-test-output")
        if FileManager.default.fileExists(atPath: directory.path),
           !FileManager.default.fileExists(atPath: marker.path),
           !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty {
            throw NSError(domain: "PDFIntegrationTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "请选择空的测试输出目录，避免覆盖已有文件。"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Generated Markdown Studio test artifacts\n".utf8).write(to: marker)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw NSError(domain: "PDFIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        try check(Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("MarkdownStudio_MarkdownStudio.bundle").path) } == true, "Run with real packaged application resources, not only a build-cache fallback")
        defer { UserDefaults.standard.removePersistentDomain(forName: "local.zero.markdownstudio.pdf-tests") }
        func wait(_ completed: () -> Bool, seconds: Double = 35) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !completed(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            try check(completed(), "Asynchronous export completed before deadline")
        }
        func run(_ markdown: String, name: String, style: PDFExportStyle = .clean, size: CGFloat = 16,
                 destination: URL? = nil, timeout: TimeInterval = 30, cancel: Bool = false) throws -> Result<Void, Error> {
            var result: Result<Void, Error>?
            var completions = 0
            var progress: [Double] = []
            let task = PDFExporter.export(markdown: markdown, title: name, baseURL: directory,
                                          options: PDFExportOptions(style: style, fontSize: size),
                                          to: destination ?? directory.appendingPathComponent(name + ".pdf"), timeout: timeout,
                                          progress: { progress.append($0) }) {
                result = $0
                completions += 1
            }
            if cancel { task.cancel() }
            try wait { result != nil }
            try check(completions == 1, "Complete once: \(name)")
            try check(PDFExporter.activeJobCount == 0, "Release export job: \(name)")
            try check(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 }, "Monotonic progress: \(name)")
            return result!
        }
        func document(_ name: String) throws -> PDFDocument {
            guard let pdf = PDFDocument(url: directory.appendingPathComponent(name + ".pdf")) else {
                throw NSError(domain: "PDFIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid PDF: \(name)"])
            }
            for index in 0..<pdf.pageCount {
                let size = pdf.page(at: index)!.bounds(for: .mediaBox).size
                try check(abs(size.width - 595.28) < 1 && abs(size.height - 841.89) < 1, "A4 page size: \(name)")
            }
            return pdf
        }
        func text(_ pdf: PDFDocument) -> String {
            (pdf.string ?? "").precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
        }

        for style in PDFExportStyle.allCases {
            let name = "style-\(style.rawValue)"
            let markdown = "# 中文 PDF 验证\n\nBEGIN-\(style.rawValue)\n\n| 项目 | 内容 |\n| --- | --- |\n| 表格 | **粗体** ~~删除线~~ |\n| 公式 | $E=mc^2$ |\n\n[可点击链接](https://example.com)\n\nEND-\(style.rawValue)\n"
            try run(markdown, name: name, style: style, size: style == .night ? 26 : 16).get()
            let pdf = try document(name)
            try check(text(pdf).contains("BEGIN-\(style.rawValue)") && text(pdf).contains("END-\(style.rawValue)"), "Both markers for \(style.rawValue)")
            try check(pdf.page(at: 0)!.annotations.contains { $0.url?.host == "example.com" }, "Preserve clickable links")
            print("Exported style:", style.rawValue, "pages:", pdf.pageCount)
        }
        let long = try String(contentsOfFile: "Tests/Fixtures/pdf-long.md", encoding: .utf8)
        try run(long, name: "long", style: .book, size: 22).get()
        let longPDF = try document("long")
        let longText = text(longPDF)
        try check(longPDF.pageCount > 1, "Long document is paginated")
        try check(longText.contains("BEGIN-MARKDOWNSTUDIO-PDF") && longText.contains("END-MARKDOWNSTUDIO-PDF"), "Long document start/end markers")
        for section in 1...65 { try check(longText.contains("第\(section)节"), "Long document section \(section)") }
        print("Long document:", longPDF.pageCount, "pages; all 65 sections present")

        let rows = (1...80).map { "| ROW-\($0)-END | 第\($0)行内容 |" }.joined(separator: "\n")
        let lines = (1...90).map { "LINE-\($0)-END: code block" }.joined(separator: "\n")
        let edge = "# 长表格与跨页代码\n\n| ID | 内容 |\n| --- | --- |\n\(rows)\n\n```text\n\(lines)\n```\n\n" + String(repeating: "长段落 word ", count: 600) + "\n\nEDGE-END"
        try run(edge, name: "edge", size: 11).get()
        let edgeText = text(try document("edge"))
        for row in 1...80 { try check(edgeText.contains("ROW-\(row)-END"), "Table row \(row)") }
        for line in 1...90 { try check(edgeText.contains("LINE-\(line)-END"), "Code line \(line)") }
        try check(edgeText.contains("EDGE-END"), "Very long paragraph retains end")

        try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/local-image.svg")).write(to: directory.appendingPathComponent("本地 图片.svg"), options: .atomic)
        try run("# 本地图片\n\n![LOCAL-IMAGE-UNAVAILABLE](<本地 图片.svg>)\n\nLOCAL-IMAGE-END", name: "local-image").get()
        let imageText = text(try document("local-image"))
        try check(imageText.contains("LOCAL-IMAGE-END") && !imageText.contains("LOCAL-IMAGE-UNAVAILABLE"), "Relative image with a Chinese/space path loads instead of rendering broken-image alt text")

        try run("", name: "empty").get()
        try check(try document("empty").pageCount == 1, "Empty Markdown exports one valid page")
        let protected = directory.appendingPathComponent("protected.pdf")
        try Data("ORIGINAL".utf8).write(to: protected)
        let cancelled = try run(long, name: "cancelled", destination: protected, cancel: true)
        if case .failure(PDFExporter.PDFExportError.cancelled) = cancelled { checks += 1 }
        else { throw NSError(domain: "PDFIntegrationTests", code: 3) }
        try check(try Data(contentsOf: protected) == Data("ORIGINAL".utf8), "Cancellation does not overwrite existing output")
        let timedOut = try run(long, name: "timeout", destination: protected, timeout: 0.001)
        if case .failure(PDFExporter.PDFExportError.timedOut) = timedOut { checks += 1 }
        else { throw NSError(domain: "PDFIntegrationTests", code: 4) }
        try check(try Data(contentsOf: protected) == Data("ORIGINAL".utf8), "Timeout does not overwrite existing output")
        let failed = try run("write failure", name: "failed", destination: directory.appendingPathComponent("absent/test.pdf"))
        if case .failure = failed { checks += 1 }
        else { throw NSError(domain: "PDFIntegrationTests", code: 5) }
        let badExtension = try run("must not overwrite", name: "invalid", destination: directory.appendingPathComponent("source.md"))
        if case .failure(PDFExporter.PDFExportError.invalidDestination) = badExtension { checks += 1 }
        else { throw NSError(domain: "PDFIntegrationTests", code: 6) }

        let model = MarkdownDocument()
        model.text = "# Document export\n\nMODEL-END"
        let modelOutput = directory.appendingPathComponent("model.pdf")
        model.beginPDFExport(to: modelOutput, options: .init(style: .clean, fontSize: 16))
        try check(model.isExportingPDF, "Document enters exporting state")
        try wait { !model.isExportingPDF }
        try check(model.errorMessage == nil && model.exportProgress == nil, "Successful document export clears progress without error")
        try check(PDFDocument(url: modelOutput)?.string?.contains("MODEL-END") == true, "Document writes actual PDF")
        try check(model.exportedPDFURL == modelOutput, "Expose the generated file for the Open PDF action")
        model.beginPDFExport(to: protected, options: .init(style: .clean, fontSize: 16))
        model.cancelPDFExport()
        try check(!model.isExportingPDF && model.errorMessage == nil && model.exportedPDFURL == nil && model.notice == "已取消 PDF 导出", "Cancellation resets document state without an error alert")

        // Exercise the same options -> save -> export path as the app, using an
        // isolated offscreen document window and test-only preference domain.
        let defaultsName = "MarkdownStudio-sheet-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let flow = MarkdownDocument(pdfDefaults: defaults)
        flow.fileURL = directory.appendingPathComponent("source.md")
        flow.text = "# Native export flow\n\nNATIVE-FLOW-END"
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button(_ title: String, in sheet: NSWindow) throws -> NSButton {
            guard let root = sheet.contentView, let button = descendants(root).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
                throw NSError(domain: "PDFIntegrationTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing native button: \(title)"])
            }
            return button
        }
        flow.exportPDF()
        try wait { window.attachedSheet is PDFExportOptionsPanel }
        try check(NSApp.modalWindow == nil, "Options sheet does not enter app-wide blocking modal loop")
        try button("取消", in: window.attachedSheet!).performClick(nil)
        try wait { !flow.isExportingPDF }
        try check(flow.errorMessage == nil, "Cancelling options is not an error")

        flow.exportPDF()
        try wait { window.attachedSheet is PDFExportOptionsPanel }
        guard let optionsSheet = window.attachedSheet as? PDFExportOptionsPanel,
              let root = optionsSheet.contentView,
              let slider = descendants(root).compactMap({ $0 as? NSSlider }).first,
              let popup = descendants(root).compactMap({ $0 as? NSPopUpButton }).first else {
            throw NSError(domain: "PDFIntegrationTests", code: 8)
        }
        slider.doubleValue = 22
        if let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
        popup.selectItem(at: 2)
        try check(optionsSheet.options.fontSize == 22 && optionsSheet.options.style == .book, "Native slider and style popup update actual export options")
        try check(!optionsSheet.isMovableByWindowBackground, "Controls are not a draggable window background")
        try button("继续", in: optionsSheet).performClick(nil)
        try wait { window.attachedSheet is NSSavePanel }
        let remembered = PDFExportOptions.load(from: defaults)
        try check(remembered.style == .book && remembered.fontSize == 22, "Native confirmation persists selected options")
        (window.attachedSheet as! NSSavePanel).cancel(nil)
        try wait { !flow.isExportingPDF }
        try check(flow.errorMessage == nil, "Cancelling save panel resets state without error")

        flow.exportPDF()
        try wait { window.attachedSheet is PDFExportOptionsPanel }
        try button("继续", in: window.attachedSheet!).performClick(nil)
        try wait { window.attachedSheet is NSSavePanel }
        let savePanel = window.attachedSheet as! NSSavePanel
        try check(savePanel.allowedContentTypes.contains(.pdf) && !savePanel.isExtensionHidden, "Native save panel is configured for PDF")
        // Modern NSSavePanel confirms in a remote system view; ok(_:) is a throwing
        // legacy stub on macOS 26. Test its cancellation and the URL callback's
        // production export method separately instead of calling that stub.
        savePanel.cancel(nil)
        try wait { !flow.isExportingPDF }
        flow.beginPDFExport(to: directory.appendingPathComponent("native-flow.pdf"), options: remembered)
        try wait { !flow.isExportingPDF }
        try check(flow.errorMessage == nil, "Export following options/save cancellation remains usable")
        try check(PDFDocument(url: directory.appendingPathComponent("native-flow.pdf"))?.string?.contains("NATIVE-FLOW-END") == true, "Destination callback method produces a real PDF")

        let workspace = MarkdownWorkspace()
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        window.setContentSize(hosting.frame.size)
        window.contentView = hosting
        for mode in EditorDisplayMode.allCases {
            defaults.set(mode.rawValue, forKey: "editor.displayMode")
            hosting.rootView = AnyView(ContentView().environmentObject(workspace).environmentObject(flow).defaultAppStorage(defaults))
            hosting.layoutSubtreeIfNeeded()
            try wait {
                hosting.layoutSubtreeIfNeeded()
                let views = descendants(hosting)
                let source = views.compactMap { $0 as? NSTextView }.first
                let preview = views.compactMap { $0 as? WKWebView }.first
                guard (source != nil) == mode.showsSource && (preview != nil) == mode.showsPreview else { return false }
                switch mode {
                case .source: return (source?.enclosingScrollView?.frame.width ?? 0) >= hosting.bounds.width - 2
                case .split: return (preview?.frame.width ?? 0) >= 380 && (preview?.frame.width ?? hosting.bounds.width) < hosting.bounds.width - 300
                case .reading: return (preview?.frame.width ?? 0) >= hosting.bounds.width - 2
                }
            }
            try check(!flow.isDirty, "Switching display mode does not modify the file")
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("view-\(mode.rawValue).png"))
                }
            }
            if mode.showsPreview, let reader = descendants(hosting).compactMap({ $0 as? WKWebView }).first {
                try wait { reader.estimatedProgress >= 1 && !reader.isLoading }
                var readOnly: Bool?
                reader.evaluateJavaScript("!document.getElementById('content').isContentEditable") { value, _ in readOnly = value as? Bool }
                try wait { readOnly != nil }
                try check(readOnly == true, "Only-render mode uses a genuinely read-only web view")
                var snapshotDone = false
                reader.takeSnapshot(with: nil) { image, error in
                    if error == nil, let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: directory.appendingPathComponent("preview-\(mode.rawValue).png"))
                    }
                    snapshotDone = true
                }
                try wait { snapshotDone }
            }
        }

        print("PDF integration tests passed: \(checks) checks. Artifacts: \(directory.path)")
    }
}
