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
        func run(_ markdown: String, name: String, style: PDFExportStyle = .lightSans, size: CGFloat = 16,
                 destination: URL? = nil, timeout: TimeInterval = 30, cancel: Bool = false,
                 customOptions: PDFExportOptions? = nil, preparedData: Data? = nil) throws -> Result<Void, Error> {
            var result: Result<Void, Error>?
            var completions = 0
            var progress: [Double] = []
            let task = PDFExporter.export(markdown: markdown, title: name, baseURL: directory,
                                          options: customOptions ?? PDFExportOptions(style: style, fontSize: size),
                                          to: destination ?? directory.appendingPathComponent(name + ".pdf"), timeout: timeout,
                                          preparedData: preparedData,
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
            (pdf.string ?? "").precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }.replacingOccurrences(of: "第[0-9]+/[0-9]+页", with: "", options: .regularExpression)
        }
        var familyNames: [PDFExportStyle: String] = [:]

        for style in PDFExportStyle.allCases {
            let name = "style-\(style.rawValue)"
            let markdown = "# 中文 PDF 验证\n\nBEGIN-\(style.rawValue)\n\n| 项目 | 内容 |\n| --- | --- |\n| 表格 | **粗体** ~~删除线~~ |\n| 公式 | $E=mc^2$ |\n\n[可点击链接](https://example.com)\n\nEND-\(style.rawValue)\n"
            try run(markdown, name: name, style: style, size: style == .darkSans ? 26 : 16).get()
            let pdf = try document(name)
            try check(text(pdf).contains("BEGIN-\(style.rawValue)") && text(pdf).contains("END-\(style.rawValue)"), "Both markers for \(style.rawValue)")
            try check(pdf.page(at: 0)!.annotations.contains { $0.url?.host == "example.com" }, "Preserve clickable links")
            if let attributed = pdf.page(at: 0)!.attributedString {
                let range = (attributed.string as NSString).range(of: "BEGIN-")
                if range.location != NSNotFound, let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont { familyNames[style] = font.fontName }
            }
            print("Exported style:", style.rawValue, "pages:", pdf.pageCount)
        }
        try check(familyNames[.lightSerif] != nil && familyNames[.lightSerif] != familyNames[.lightSans] && familyNames[.darkSerif] != familyNames[.darkSans], "The four presets use genuinely different serif/sans fonts in the PDF")
        let long = try String(contentsOfFile: "Tests/Fixtures/pdf-long.md", encoding: .utf8)
        try run(long, name: "long", style: .lightSerif, size: 22).get()
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

        let wideWord = "WORD-BEGIN-" + String(repeating: "ABCDEFGHIJ", count: 100) + "-WORD-END"
        let wideTable = "CELL-BEGIN-" + String(repeating: "Z", count: 700) + "-CELL-END"
        let wideEquation = (1...32).map { "x_{\($0)}" }.joined(separator: "+")
        let wide = "# Horizontal overflow\n\n\(wideWord)\n\n| Wide | Value |\n| --- | --- |\n| \(wideTable) | retained |\n\n$$\n\(wideEquation)\n$$\n\nWIDE-END"
        try run(wide, name: "wide", size: 26).get()
        let wideText = text(try document("wide"))
        try check(wideText.contains(wideWord), "Unbreakable paragraph is wrapped instead of clipped horizontally")
        // PDF reading order can interleave the neighboring column mid-cell.
        // Count unique glyphs instead of requiring a contiguous multi-page string.
        try check(wideText.contains("CELL-BEGIN-") && wideText.contains("-CELL-END") && wideText.filter { $0 == "Z" }.count == 700, "Unbreakable table cell stays complete inside A4 width")
        try check(wideText.contains("WIDE-END"), "Wide content retains following document content")
        try check(wideText.contains("32") && wideText.filter { $0 == "x" }.count >= 32, "Wide equation retains all terms and final subscript")
        try check(wideText.components(separatedBy: "WORD-BEGIN-").count == 2, "Pagination does not duplicate paragraph start")

        var printOptions = PDFExportOptions(style: .lightSerif, fontSize: 14, titleFontSize: 46, topMargin: .large, bottomMargin: .small, horizontalMargin: .large, paperSize: .letter, orientation: .landscape, lineSpacing: .compact, showsHeader: true, showsPageNumbers: true, decorationSize: .large)
        let printText = "# TITLE-FONT-CHECK\n\nBODY-FONT-CHECK\n\n" + String(repeating: "打印排版边界 paragraph content.\n\n", count: 70) + "PRINT-END"
        try run(printText, name: "letter-landscape", customOptions: printOptions).get()
        let printed = PDFDocument(url: directory.appendingPathComponent("letter-landscape.pdf"))!
        let geometry = PDFPageLayout.Geometry(options: printOptions)
        try check(printed.pageCount > 1, "Landscape print fixture spans multiple pages")
        for index in 0..<printed.pageCount {
            let page = printed.page(at: index)!
            try check(abs(page.bounds(for: .mediaBox).width - 792) < 0.1 && abs(page.bounds(for: .mediaBox).height - 612) < 0.1, "Letter landscape media box")
            let pageText = (page.string ?? "").filter { !$0.isWhitespace }
            try check(pageText.contains("letter-landscape") && pageText.contains("第\(index + 1)/\(printed.pageCount)页"), "Document header and page / total footer on every page")
            let headerRange = ((page.string ?? "") as NSString).range(of: "letter-landscape")
            try check(headerRange.location != NSNotFound, "Header's selectable character index exists")
            let headerBounds = page.characterBounds(at: headerRange.location)
            try check(headerBounds.minY >= geometry.paperSize.height - geometry.topMargin && headerBounds.maxY <= geometry.paperSize.height - 17, "Header is outside body, away from the paper edge")
        }
        if let page = printed.page(at: 0), let attributed = page.attributedString {
            for (marker, expected) in [("TITLE-FONT-CHECK", 46.0), ("BODY-FONT-CHECK", 14.0)] {
                let range = (attributed.string as NSString).range(of: marker)
                try check(range.location != NSNotFound, "Font marker is selectable text")
                let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                try check(font != nil && abs(Double(font!.pointSize) - expected) < 0.5, "Actual PDF point size for \(marker)")
                let bounds = page.characterBounds(at: range.location)
                try check(bounds.minX >= geometry.horizontalMargin - 1 && bounds.maxY <= geometry.paperSize.height - geometry.topMargin + 1, "Body and title stay inside custom printable margins")
            }
        } else { throw NSError(domain: "PDFIntegrationTests", code: 12) }
        printOptions.showsHeader = false
        printOptions.showsPageNumbers = false
        try run("# Decorations disabled\n\nNO-DECORATION-END", name: "no-decorations", customOptions: printOptions).get()
        let plain = PDFDocument(url: directory.appendingPathComponent("no-decorations.pdf"))!
        try check(!text(plain).contains("no-decorations") && !text(plain).contains("第1/1页"), "Header and footer can be disabled independently of margins")
        for (paper, orientation) in [(PDFPaperSize.a4, PDFOrientation.landscape), (.letter, .portrait)] {
            let settings = PDFExportOptions(paperSize: paper, orientation: orientation)
            let name = "paper-\(paper.rawValue)-\(orientation.rawValue)"
            try run("# Paper check\n\nPAPER-END", name: name, customOptions: settings).get()
            let pdf = PDFDocument(url: directory.appendingPathComponent(name + ".pdf"))!
            let expected = PDFPageLayout.Geometry(options: settings).paperSize
            try check(pdf.page(at: 0)!.bounds(for: .mediaBox).size == expected && text(pdf).contains("PAPER-END"), "Actual PDF bounds for \(paper.rawValue) \(orientation.rawValue)")
        }

        var previewResult: Result<Data, Error>?
        PDFExporter.render(markdown: printText, title: "PREVIEW-EXACT", baseURL: directory, options: printOptions) { previewResult = $0 }
        try wait { previewResult != nil }
        let exactPreview = try previewResult!.get()
        try run("MUST-NOT-RERENDER", name: "exact-preview", preparedData: exactPreview).get()
        try check(try Data(contentsOf: directory.appendingPathComponent("exact-preview.pdf")) == exactPreview, "Export writes precisely the bytes shown in preview, with no rerender")
        try check(PDFExporter.activeJobCount == 0, "In-memory preview releases its WebKit job")

        let spacingText = String(repeating: "打印边距与行距验证，paragraph content with multiple words and lines.\n\n", count: 130) + "MARGIN-END"
        let narrow = PDFExportOptions(fontSize: 14, topMargin: .small, bottomMargin: .small, horizontalMargin: .small)
        let generous = PDFExportOptions(fontSize: 14, topMargin: .large, bottomMargin: .large, horizontalMargin: .large, lineSpacing: .relaxed)
        try run(spacingText, name: "small-margins", customOptions: narrow).get()
        try run(spacingText, name: "large-margins", customOptions: generous).get()
        let smallPDF = try document("small-margins"), largePDF = try document("large-margins")
        try check(largePDF.pageCount > smallPDF.pageCount, "Larger margins and spacing materially change actual pagination")
        try check(text(smallPDF).contains("MARGIN-END") && text(largePDF).contains("MARGIN-END"), "Both margin presets retain the document end")

        try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/local-image.svg")).write(to: directory.appendingPathComponent("本地 图片.svg"), options: .atomic)
        try run("# 本地图片\n\n![LOCAL-IMAGE-UNAVAILABLE](<本地 图片.svg>)\n\nLOCAL-IMAGE-END", name: "local-image").get()
        let imageText = text(try document("local-image"))
        try check(imageText.contains("LOCAL-IMAGE-END") && !imageText.contains("LOCAL-IMAGE-UNAVAILABLE"), "Relative image with a Chinese/space path loads instead of rendering broken-image alt text")

        try run("", name: "empty").get()
        try check(try document("empty").pageCount == 1, "Empty Markdown exports one valid page")
        try run("# Safe timeout\n\nNONFINITE-END", name: "nonfinite-timeout", timeout: .nan).get()
        try check(text(try document("nonfinite-timeout")).contains("NONFINITE-END"), "Non-finite timeout uses a safe default without trapping")
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
        let invalidPreview = try run("must not overwrite", name: "invalid-preview", destination: protected, preparedData: Data("not a PDF".utf8))
        if case .failure(PDFExporter.PDFExportError.couldNotCreateFile) = invalidPreview { checks += 1 }
        else { throw NSError(domain: "PDFIntegrationTests", code: 13) }
        try check(try Data(contentsOf: protected) == Data("ORIGINAL".utf8), "Invalid preview data cannot damage an existing file")

        let model = MarkdownDocument()
        model.text = "# Document export\n\nMODEL-END"
        let modelOutput = directory.appendingPathComponent("model.pdf")
        model.beginPDFExport(to: modelOutput, options: .init(style: .lightSans, fontSize: 16))
        try check(model.isExportingPDF, "Document enters exporting state")
        try wait { !model.isExportingPDF }
        try check(model.errorMessage == nil && model.exportProgress == nil, "Successful document export clears progress without error")
        try check(PDFDocument(url: modelOutput)?.string?.contains("MODEL-END") == true, "Document writes actual PDF")
        try check(model.exportedPDFURL == modelOutput, "Expose the generated file for the Open PDF action")
        model.beginPDFExport(to: protected, options: .init(style: .lightSans, fontSize: 16))
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
        popup.selectItem(at: 1)
        if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        try check(optionsSheet.options.fontSize == 22 && optionsSheet.options.style == .lightSerif, "Native slider and style popup update actual export options")
        try check(!optionsSheet.isMovableByWindowBackground, "Controls are not a draggable window background")
        try wait { optionsSheet.isPreviewReady }
        func control<T: NSView>(_ identifier: String, as type: T.Type, in root: NSView) throws -> T {
            guard let found = descendants(root).first(where: { $0.identifier?.rawValue == identifier }) as? T else {
                throw NSError(domain: "PDFIntegrationTests", code: 14, userInfo: [NSLocalizedDescriptionKey: "Missing control: \(identifier)"])
            }
            return found
        }
        func select(_ identifier: String, index: Int) throws {
            let popup = try control(identifier, as: NSPopUpButton.self, in: root)
            popup.selectItem(at: index)
            if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        }
        let oldPreview = optionsSheet.previewData
        try select("pdf.topMargin", index: 2)
        try select("pdf.bottomMargin", index: 0)
        try select("pdf.horizontalMargin", index: 2)
        try select("pdf.paperSize", index: 1)
        try select("pdf.orientation", index: 1)
        try select("pdf.decorationSize", index: 2)
        let titleSlider = try control("pdf.titleFontSize", as: NSSlider.self, in: root)
        titleSlider.doubleValue = 46
        if let action = titleSlider.action { NSApp.sendAction(action, to: titleSlider.target, from: titleSlider) }
        try check(!optionsSheet.isPreviewReady && !(try button("继续", in: optionsSheet)).isEnabled, "Changing controls immediately disables exporting a stale preview")
        for value in [12.0, 18.0, 22.0] {
            slider.doubleValue = value
            if let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
        }
        try wait { optionsSheet.isPreviewReady }
        try check(optionsSheet.options.titleFontSize == 46 && optionsSheet.options.topMargin == .large && optionsSheet.options.bottomMargin == .small && optionsSheet.options.decorationSize == .large, "All native typography/margin controls feed real settings")
        let previewPDF = optionsSheet.previewView.document!
        try check(previewPDF.pageCount > 0 && previewPDF.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612), "Native PDFView displays actual Letter landscape PDF")
        try check(oldPreview != optionsSheet.previewData && optionsSheet.options.fontSize == 22, "Rapid setting changes only accept the latest preview")
        optionsSheet.contentView?.layoutSubtreeIfNeeded()
        let leftScroll = descendants(root).compactMap { $0 as? NSScrollView }.first(where: { $0.documentView is PDFExportOptionsView })!
        try check(leftScroll.documentView!.frame.width <= leftScroll.contentView.bounds.width + 1, "Settings are not clipped horizontally inside scroll container")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            optionsSheet.appearance = NSAppearance(named: appearance)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("pdf-settings-\(appearance.rawValue).png"))
            }
            try root.dataWithPDF(inside: root.bounds).write(to: directory.appendingPathComponent("pdf-settings-\(appearance.rawValue).pdf"))
        }
        optionsSheet.setContentSize(NSSize(width: 800, height: 500))
        root.layoutSubtreeIfNeeded()
        try check(leftScroll.documentView!.frame.width <= leftScroll.contentView.bounds.width + 1 && (try button("继续", in: optionsSheet)).frame.width >= 80, "Small window keeps controls usable with scrolling settings")
        try button("继续", in: optionsSheet).performClick(nil)
        try wait { window.attachedSheet is NSSavePanel }
        let remembered = PDFExportOptions.load(from: defaults)
        try check(remembered.style == .lightSerif && remembered.fontSize == 22, "Native confirmation persists selected options")
        try check(remembered.paperSize == .letter && remembered.orientation == .landscape && remembered.titleFontSize == 46, "Confirmation persists new print settings")
        (window.attachedSheet as! NSSavePanel).cancel(nil)
        try wait { !flow.isExportingPDF }
        try check(flow.errorMessage == nil, "Cancelling save panel resets state without error")

        flow.exportPDF()
        try wait { window.attachedSheet is PDFExportOptionsPanel }
        let resetSheet = window.attachedSheet as! PDFExportOptionsPanel
        try button("恢复默认设置", in: resetSheet).performClick(nil)
        try check(resetSheet.options == .default, "Restore defaults resets every option")
        try wait { resetSheet.isPreviewReady }
        try button("取消", in: resetSheet).performClick(nil)
        try wait { !flow.isExportingPDF }
        try check(PDFExportOptions.load(from: defaults) == remembered, "Cancel after resetting does not change saved preferences")
        try check(PDFExporter.activeJobCount == 0, "Cancel releases all preview jobs")

        flow.exportPDF()
        try wait { window.attachedSheet is PDFExportOptionsPanel }
        try wait { (window.attachedSheet as? PDFExportOptionsPanel)?.isPreviewReady == true }
        let acceptedPreview = (window.attachedSheet as! PDFExportOptionsPanel).previewData!
        try button("继续", in: window.attachedSheet!).performClick(nil)
        try wait { window.attachedSheet is NSSavePanel }
        let savePanel = window.attachedSheet as! NSSavePanel
        try check(savePanel.allowedContentTypes.contains(.pdf) && !savePanel.isExtensionHidden, "Native save panel is configured for PDF")
        // Modern NSSavePanel confirms in a remote system view; ok(_:) is a throwing
        // legacy stub on macOS 26. Test its cancellation and the URL callback's
        // production export method separately instead of calling that stub.
        savePanel.cancel(nil)
        try wait { !flow.isExportingPDF }
        flow.beginPDFExport(to: directory.appendingPathComponent("native-flow.pdf"), options: remembered, preparedData: acceptedPreview)
        try wait { !flow.isExportingPDF }
        try check(flow.errorMessage == nil, "Export following options/save cancellation remains usable")
        try check(PDFDocument(url: directory.appendingPathComponent("native-flow.pdf"))?.string?.contains("NATIVE-FLOW-END") == true, "Destination callback method produces a real PDF")
        try check(try Data(contentsOf: directory.appendingPathComponent("native-flow.pdf")) == acceptedPreview, "Document destination callback saves exactly the native preview")

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
