import AppKit
import CoreGraphics
import PDFKit
import WebKit

/// A4 in PDF points; WebKit layout uses CSS pixels at 96 dpi.
enum PDFPageLayout {
    static let paperSize = CGSize(width: 595.28, height: 841.89)
    static let horizontalMargin: CGFloat = 42
    static let verticalMargin: CGFloat = 48
    static let scale: CGFloat = 72.0 / 96.0
    static let contentWidth = (paperSize.width - horizontalMargin * 2) / scale
    static let contentHeight = (paperSize.height - verticalMargin * 2) / scale

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
    static func slices(for measurement: Measurement) throws -> [CGRect] {
        guard measurement.height.isFinite, measurement.height >= 0,
              measurement.ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }) else {
            throw PDFExporter.PDFExportError.invalidLayout
        }
        guard measurement.height <= Double(contentHeight) * 1000 else {
            throw PDFExporter.PDFExportError.documentTooLarge
        }
        let height = max(1, measurement.height)
        let pageHeight = Double(contentHeight)
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
            pages.append(CGRect(x: 0, y: start, width: contentWidth, height: end - start))
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
                       timeout: TimeInterval = 60, progress: @escaping @MainActor (Double) -> Void = { _ in },
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> ExportTask {
        let job = ExportJob(title: title, options: options, destination: destination, progress: progress, completion: completion)
        jobs[job.id] = job
        // Always complete asynchronously, including validation errors and cancellation.
        DispatchQueue.main.async { job.start(markdown: markdown, baseURL: baseURL, timeout: timeout) }
        return ExportTask(id: job.id)
    }

    @MainActor private final class ExportJob: NSObject, WKNavigationDelegate {
        let id = UUID()
        let title: String
        let options: PDFExportOptions
        let destination: URL
        let webView: WKWebView
        let progress: @MainActor (Double) -> Void
        let completion: @MainActor (Result<Void, Error>) -> Void
        private var renderTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var started = false
        private var finished = false
        private var scoped = false

        init(title: String, options: PDFExportOptions, destination: URL, progress: @escaping @MainActor (Double) -> Void,
             completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            self.title = title
            self.options = options
            self.destination = destination
            self.progress = progress
            self.completion = completion
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: PDFPageLayout.contentWidth, height: PDFPageLayout.contentHeight), configuration: configuration)
            webView.appearance = NSAppearance(named: .aqua)
        }

        func start(markdown: String, baseURL: URL?, timeout: TimeInterval) {
            guard !finished else { return }
            guard destination.isFileURL, destination.pathExtension.lowercased() == "pdf" else {
                finish(.failure(PDFExportError.invalidDestination))
                return
            }
            scoped = destination.startAccessingSecurityScopedResource()
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.001, min(120, timeout)))) }
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
            let slices = try PDFPageLayout.slices(for: measurement)
            // Explicit capture rectangles must be inside the web view's full bounds,
            // not just its initial screen-sized viewport.
            webView.setFrameSize(CGSize(width: PDFPageLayout.contentWidth, height: max(PDFPageLayout.contentHeight, measurement.height + 1)))
            _ = try await webView.evaluateJavaScript("document.body.offsetHeight")
            try checkActive()
            progress(0.15)

            let output = NSMutableData()
            var paper = CGRect(origin: .zero, size: PDFPageLayout.paperSize)
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
                let target = CGRect(x: PDFPageLayout.horizontalMargin,
                                    y: paper.height - PDFPageLayout.verticalMargin - slice.height * PDFPageLayout.scale,
                                    width: PDFPageLayout.contentWidth * PDFPageLayout.scale, height: slice.height * PDFPageLayout.scale)
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
                context.endPDFPage()
                progress(0.15 + 0.8 * Double(index + 1) / Double(slices.count))
            }
            context.closePDF()
            closed = true
            try checkActive()
            guard let verified = PDFDocument(data: output as Data), verified.pageCount == slices.count else { throw PDFExportError.couldNotCreateFile }
            // Failed rendering or cancellation never touches an existing PDF.
            try (output as Data).write(to: destination, options: .atomic)
            progress(1)
            finish(.success(()))
        }

        func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            renderTask?.cancel()
            timeoutTask?.cancel()
            webView.stopLoading()
            webView.navigationDelegate = nil
            if scoped { destination.stopAccessingSecurityScopedResource() }
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
        let components: [CGFloat]
        switch self {
        case .clean: components = [1, 1, 1, 1]
        case .paper: components = [252.0/255, 246.0/255, 233.0/255, 1]
        case .book: components = [1, 253.0/255, 248.0/255, 1]
        case .night: components = [29.0/255, 35.0/255, 45.0/255, 1]
        }
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
    }
}
