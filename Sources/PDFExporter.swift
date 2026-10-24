import AppKit
import CoreGraphics
import CoreText
import PDFKit
import WebKit

/// A4 in PDF points; WebKit layout uses CSS pixels at 96 dpi.
enum PDFPageLayout {
    static let scale: CGFloat = 72.0 / 96.0
    struct Geometry {
        let paperSize: CGSize
        let horizontalMargin: CGFloat
        let topMargin: CGFloat
        let bottomMargin: CGFloat
        var contentWidth: CGFloat { (paperSize.width - horizontalMargin * 2) / PDFPageLayout.scale }
        var contentHeight: CGFloat { (paperSize.height - topMargin - bottomMargin) / PDFPageLayout.scale }
        init(options: PDFExportOptions) {
            let portrait = options.paperSize.points
            paperSize = options.orientation == .portrait ? portrait : CGSize(width: portrait.height, height: portrait.width)
            horizontalMargin = options.horizontalMargin.points
            topMargin = options.topMargin.points
            bottomMargin = options.bottomMargin.points
        }
    }
    static var contentWidth: CGFloat { Geometry(options: .default).contentWidth }
    static var contentHeight: CGFloat { Geometry(options: .default).contentHeight }

    struct ProtectedRange: Codable {
        let start: Double
        let end: Double
    }

    struct Measurement: Codable {
        let height: Double
        let ranges: [ProtectedRange]
    }

    /// Contiguous slices cover every pixel once. Prefer paragraph/row boundaries;
    /// unusually tall blocks fall back to individual text-line boundaries.
    static func slices(for measurement: Measurement, layout: Geometry = Geometry(options: .default)) throws -> [CGRect] {
        guard measurement.height.isFinite, measurement.height >= 0,
              measurement.ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }) else {
            throw PDFExporter.PDFExportError.invalidLayout
        }
        guard measurement.height <= Double(layout.contentHeight) * 1000 else {
            throw PDFExporter.PDFExportError.documentTooLarge
        }
        let height = max(1, measurement.height)
        let pageHeight = Double(layout.contentHeight)
        let ranges = measurement.ranges.filter { $0.end - $0.start < pageHeight && $0.end > $0.start }
        var start = 0.0
        var pages: [CGRect] = []
        while start < height {
            guard pages.count < 1000 else { throw PDFExporter.PDFExportError.documentTooLarge }
            var end = min(height, start + pageHeight)
            if end < height {
                // Moving a break upwards can expose a preceding overlapping block.
                while let crossing = ranges.filter({ $0.start > start + 0.5 && $0.start < end - 0.5 && $0.end > end + 0.01 }).map(\.start).min() {
                    end = crossing
                }
            }
            guard end > start else { throw PDFExporter.PDFExportError.invalidLayout }
            pages.append(CGRect(x: 0, y: start, width: layout.contentWidth, height: end - start))
            start = end
        }
        return pages
    }
}

/// Generates vector PDFs directly with WebKit. No printer, print modal, or editor
/// window is required, so export also works from the read-only display mode.
@MainActor
enum PDFExporter {
    private static var jobs: [UUID: ExportJob] = [:]
    static var activeJobCount: Int { jobs.count }

    struct ExportTask {
        fileprivate let id: UUID
        @MainActor func cancel() { jobs[id]?.finish(.failure(PDFExportError.cancelled)) }
    }

    enum PDFExportError: LocalizedError, Equatable {
        case cancelled, timedOut, invalidDestination, invalidLayout, documentTooLarge, couldNotCreateFile
        var errorDescription: String? {
            switch self {
            case .cancelled: "已取消 PDF 导出。"
            case .timedOut: "导出超时，请检查文档中无法加载的图片或字体后重试。"
            case .invalidDestination: "请选择本机上的 .pdf 文件保存位置。"
            case .invalidLayout: "无法计算文档分页，请尝试使用较小字号。"
            case .documentTooLarge: "文档超过 1000 页，请拆分后导出。"
            case .couldNotCreateFile: "无法生成有效的 PDF 文件。"
            }
        }
    }

    @discardableResult
    static func export(markdown: String, title: String, baseURL: URL?, options: PDFExportOptions, to destination: URL,
                       timeout: TimeInterval = 60, preparedData: Data? = nil, progress: @escaping @MainActor (Double) -> Void = { _ in },
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> ExportTask {
        let job = ExportJob(title: title, options: options, destination: destination, preparedData: preparedData, progress: progress) { result in completion(result.map { _ in () }) }
        jobs[job.id] = job
        // Start and validation complete asynchronously; explicit cancellation
        // finishes immediately so callers can discard obsolete previews safely.
        DispatchQueue.main.async { job.start(markdown: markdown, baseURL: baseURL, timeout: timeout) }
        return ExportTask(id: job.id)
    }

    /// Preview uses exactly the same pagination and PDF composition as export,
    /// without creating temporary files or requesting a save destination.
    @discardableResult
    static func render(markdown: String, title: String, baseURL: URL?, options: PDFExportOptions,
                       timeout: TimeInterval = 60, completion: @escaping @MainActor (Result<Data, Error>) -> Void) -> ExportTask {
        let job = ExportJob(title: title, options: options, destination: nil, preparedData: nil, progress: { _ in }, completion: completion)
        jobs[job.id] = job
        DispatchQueue.main.async { job.start(markdown: markdown, baseURL: baseURL, timeout: timeout) }
        return ExportTask(id: job.id)
    }

    @MainActor private final class ExportJob: NSObject, WKNavigationDelegate {
        let id = UUID()
        let title: String
        let options: PDFExportOptions
        let destination: URL?
        let preparedData: Data?
        let layout: PDFPageLayout.Geometry
        let webView: WKWebView
        let progress: @MainActor (Double) -> Void
        let completion: @MainActor (Result<Data, Error>) -> Void
        private var renderTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var started = false
        private var finished = false
        private var scoped = false

        init(title: String, options: PDFExportOptions, destination: URL?, preparedData: Data?, progress: @escaping @MainActor (Double) -> Void,
             completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
            self.title = title
            self.options = options
            self.destination = destination
            self.preparedData = preparedData
            layout = PDFPageLayout.Geometry(options: options)
            self.progress = progress
            self.completion = completion
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: layout.contentWidth, height: layout.contentHeight), configuration: configuration)
            webView.appearance = NSAppearance(named: .aqua)
        }

        func start(markdown: String, baseURL: URL?, timeout: TimeInterval) {
            guard !finished else { return }
            if let destination {
                guard destination.isFileURL, destination.pathExtension.lowercased() == "pdf" else {
                    finish(.failure(PDFExportError.invalidDestination))
                    return
                }
                scoped = destination.startAccessingSecurityScopedResource()
            }
            if let preparedData {
                do { try write(preparedData); progress(1); finish(.success(preparedData)) }
                catch { finish(.failure(error)) }
                return
            }
            let safeTimeout = timeout.isFinite ? max(0.001, min(120, timeout)) : 60
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(safeTimeout)) }
                catch { return }
                self?.finish(.failure(PDFExportError.timedOut))
            }
            progress(0.02)
            webView.navigationDelegate = self
            webView.loadHTMLString(MarkdownRenderer.documentHTML(markdown: markdown, title: title, appearance: options.appearance), baseURL: baseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !started, !finished else { return }
            started = true
            renderTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.render() }
                catch is CancellationError { self.finish(.failure(PDFExportError.cancelled)) }
                catch { self.finish(.failure(error)) }
            }
        }

        private func checkActive() throws {
            try Task.checkCancellation()
            if finished { throw CancellationError() }
        }

        private func render() async throws {
            try checkActive()
            let value = try await webView.callAsyncJavaScript(Self.measureScript, arguments: [:], in: nil, contentWorld: .page)
            try checkActive()
            guard let json = value as? String, let jsonData = json.data(using: .utf8) else { throw PDFExportError.invalidLayout }
            let measurement = try JSONDecoder().decode(PDFPageLayout.Measurement.self, from: jsonData)
            let slices = try PDFPageLayout.slices(for: measurement, layout: layout)
            // Explicit capture rectangles must be inside the web view's full bounds,
            // not just its initial screen-sized viewport.
            webView.setFrameSize(CGSize(width: layout.contentWidth, height: max(layout.contentHeight, measurement.height + 1)))
            _ = try await webView.evaluateJavaScript("document.body.offsetHeight")
            try checkActive()
            progress(0.15)

            let output = NSMutableData()
            var paper = CGRect(origin: .zero, size: layout.paperSize)
            guard let consumer = CGDataConsumer(data: output),
                  let context = CGContext(consumer: consumer, mediaBox: &paper, [kCGPDFContextTitle: title, kCGPDFContextCreator: "Markdown Studio"] as CFDictionary) else {
                throw PDFExportError.couldNotCreateFile
            }
            var closed = false
            defer { if !closed { context.closePDF() } }
            for (index, slice) in slices.enumerated() {
                try checkActive()
                let configuration = WKPDFConfiguration()
                configuration.rect = slice
                configuration.allowTransparentBackground = true
                let data = try await webView.pdf(configuration: configuration)
                try checkActive()
                guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
                    throw PDFExportError.couldNotCreateFile
                }
                context.beginPDFPage(nil)
                context.setFillColor(options.style.pageBackground)
                context.fill(paper)
                let target = CGRect(x: layout.horizontalMargin,
                                    y: paper.height - layout.topMargin - slice.height * PDFPageLayout.scale,
                                    width: layout.contentWidth * PDFPageLayout.scale, height: slice.height * PDFPageLayout.scale)
                let transform = page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true)
                context.saveGState()
                context.clip(to: target)
                context.concatenate(transform)
                context.drawPDFPage(page)
                context.restoreGState()
                // Drawing vector content alone does not copy clickable PDF links.
                if let capturedPage = PDFDocument(data: data)?.page(at: 0) {
                    for annotation in capturedPage.annotations {
                        if let url = annotation.url {
                            context.setURL(url as CFURL, for: annotation.bounds.applying(transform))
                        }
                    }
                }
                drawDecorations(in: context, page: index + 1, count: slices.count)
                context.endPDFPage()
                progress(0.15 + 0.8 * Double(index + 1) / Double(slices.count))
            }
            context.closePDF()
            closed = true
            try checkActive()
            guard let verified = PDFDocument(data: output as Data), verified.pageCount == slices.count else { throw PDFExportError.couldNotCreateFile }
            // Failed rendering or cancellation never touches an existing PDF.
            try write(output as Data)
            progress(1)
            finish(.success(output as Data))
        }

        private func write(_ data: Data) throws {
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0, pdf.pageCount <= 1000 else { throw PDFExportError.couldNotCreateFile }
            if let destination { try data.write(to: destination, options: .atomic) }
        }

        private func drawDecorations(in context: CGContext, page: Int, count: Int) {
            let size = options.decorationSize.points
            let font = options.style.isSerif ? (NSFont(name: "Songti SC", size: size) ?? .systemFont(ofSize: size)) : .systemFont(ofSize: size)
            let color = options.style.isDark ? NSColor(calibratedWhite: 0.86, alpha: 1) : NSColor(calibratedWhite: 0.33, alpha: 1)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            func draw(_ text: String, centerY: CGFloat, centered: Bool) {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                let width = layout.contentWidth * PDFPageLayout.scale
                let fitted = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let measuredWidth = CGFloat(CTLineGetTypographicBounds(fitted, &ascent, &descent, nil))
                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: layout.horizontalMargin + (centered ? max(0, (width - measuredWidth) / 2) : 0), y: centerY - (ascent - descent) / 2)
                CTLineDraw(fitted, context)
                context.restoreGState()
            }
            // Keep small-margin decorations away from the printer's edge zone.
            let edgeDistance = 18 + size / 2
            if options.showsHeader { draw(documentTitleForHeader, centerY: layout.paperSize.height - max(layout.topMargin / 2, edgeDistance), centered: false) }
            if options.showsPageNumbers { draw("第 \(page) / \(count) 页", centerY: max(layout.bottomMargin / 2, edgeDistance), centered: true) }
        }

        private var documentTitleForHeader: String { title.components(separatedBy: .newlines).joined(separator: " ") }

        func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            renderTask?.cancel()
            timeoutTask?.cancel()
            webView.stopLoading()
            webView.navigationDelegate = nil
            // An image/font promise may otherwise retain an obsolete preview's
            // JS context after cancellation. Navigating away resolves that wait.
            if case .failure = result, started { webView.loadHTMLString("", baseURL: nil) }
            if scoped { destination?.stopAccessingSecurityScopedResource() }
            jobs.removeValue(forKey: id)
            completion(result)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(PDFExportError.couldNotCreateFile)) }

        private static let measureScript = #"""
        document.querySelectorAll('details').forEach(node => { node.open = true; });
        document.querySelectorAll('img').forEach(node => { node.loading = 'eager'; });
        await document.fonts.ready;
        await Promise.all(Array.from(document.images).map(img => img.complete ? Promise.resolve() : new Promise(resolve => {
          img.addEventListener('load', resolve, {once:true});
          img.addEventListener('error', resolve, {once:true});
        })));
        const content = document.getElementById('content');
        // A long unbreakable equation must fit horizontally, not be clipped by
        // the A4 capture rectangle. Ordinary text/tables wrap through export CSS.
        content.querySelectorAll('[data-markdown-math]').forEach(node => {
          const math = node.querySelector('.katex');
          if (!math) return;
          const available = Math.min(content.clientWidth, node.parentElement.clientWidth);
          const width = Math.max(math.scrollWidth, math.getBoundingClientRect().width);
          if (width > available && available > 0) math.style.fontSize = `${available / width * 0.98}em`;
        });
        const ranges = [];
        function add(rect) {
          if (rect.height > 0 && rect.width > 0) ranges.push({start: Math.max(0, rect.top + scrollY), end: Math.max(0, rect.bottom + scrollY)});
        }
        content.querySelectorAll('p,pre,tr,li,blockquote,img,.katex-display,h1,h2,h3,h4,h5,h6').forEach(node => {
          const rect = node.getBoundingClientRect();
          if (/^H[1-6]$/.test(node.tagName) && node.nextElementSibling) {
            const next = node.nextElementSibling;
            const first = (next.tagName === 'TABLE' ? next.querySelector('tr') : next)?.getBoundingClientRect();
            if (first) { add({top:rect.top,bottom:first.bottom,height:first.bottom-rect.top,width:rect.width}); return; }
          }
          add(rect);
        });
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (!node.textContent.trim() || node.parentElement.closest('.katex-mathml')) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          Array.from(range.getClientRects()).forEach(add);
        }
        return JSON.stringify({height:Math.max(1, Math.ceil(content.getBoundingClientRect().bottom + scrollY + 1)), ranges});
        """#
    }
}

extension PDFExportStyle {
    var pageBackground: CGColor {
        let components: [CGFloat] = isDark ? [29.0/255, 35.0/255, 45.0/255, 1] : [1, 1, 1, 1]
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
    }
}
