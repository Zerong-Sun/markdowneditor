import AppKit
import PDFKit

struct PDFExportSelection {
    let options: PDFExportOptions
    /// The exact bytes displayed by PDFView are written after choosing a path.
    let data: Data
}

private final class PDFSettingsBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

final class PDFExportOptionsView: NSView {
    private let stylePopup = NSPopUpButton()
    private let fontSlider = NSSlider(value: 16, minValue: 8, maxValue: 32, target: nil, action: nil)
    private let titleSlider = NSSlider(value: 32, minValue: 16, maxValue: 72, target: nil, action: nil)
    private let fontValue = NSTextField(labelWithString: "16 pt")
    private let titleValue = NSTextField(labelWithString: "32 pt")
    private let topPopup = NSPopUpButton(), bottomPopup = NSPopUpButton(), horizontalPopup = NSPopUpButton()
    private let paperPopup = NSPopUpButton(), orientationPopup = NSPopUpButton(), spacingPopup = NSPopUpButton(), decorationPopup = NSPopUpButton()
    private let headerCheck = NSButton(checkboxWithTitle: "页眉显示文档名", target: nil, action: nil)
    private let pagesCheck = NSButton(checkboxWithTitle: "页脚显示页码 / 总页数", target: nil, action: nil)
    var onChange: ((PDFExportOptions) -> Void)?
    override var isFlipped: Bool { true }

    var options: PDFExportOptions {
        PDFExportOptions(style: selected(stylePopup, PDFExportStyle.allCases), fontSize: CGFloat(fontSlider.doubleValue),
                         titleFontSize: CGFloat(titleSlider.doubleValue), topMargin: selected(topPopup, PDFMarginSize.allCases),
                         bottomMargin: selected(bottomPopup, PDFMarginSize.allCases), horizontalMargin: selected(horizontalPopup, PDFMarginSize.allCases),
                         paperSize: selected(paperPopup, PDFPaperSize.allCases), orientation: selected(orientationPopup, PDFOrientation.allCases),
                         lineSpacing: selected(spacingPopup, PDFLineSpacing.allCases), showsHeader: headerCheck.state == .on,
                         showsPageNumbers: pagesCheck.state == .on, decorationSize: selected(decorationPopup, PDFDecorationSize.allCases))
    }

    init(options: PDFExportOptions) {
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 540))
        autoresizingMask = [.width]
        let heading = NSTextField(labelWithString: "排版与打印")
        heading.font = .boldSystemFont(ofSize: 14)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        stack.addArrangedSubview(heading)
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 104).isActive = true
            let line = NSStackView(views: [label, control])
            line.spacing = 8
            line.alignment = .centerY
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            line.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        func configure(_ popup: NSPopUpButton, _ names: [String], _ identifier: String) {
            popup.addItems(withTitles: names)
            popup.target = self
            popup.action = #selector(changed)
            popup.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        func sizeControl(_ slider: NSSlider, _ value: NSTextField, _ identifier: String) -> NSView {
            slider.target = self
            slider.action = #selector(changed)
            slider.identifier = NSUserInterfaceItemIdentifier(identifier)
            slider.isContinuous = true
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let line = NSStackView(views: [slider, value])
            line.spacing = 5
            return line
        }
        configure(stylePopup, PDFExportStyle.allCases.map(\.name), "pdf.style")
        configure(spacingPopup, PDFLineSpacing.allCases.map(\.name), "pdf.lineSpacing")
        configure(paperPopup, PDFPaperSize.allCases.map(\.name), "pdf.paperSize")
        configure(orientationPopup, PDFOrientation.allCases.map(\.name), "pdf.orientation")
        configure(topPopup, PDFMarginSize.allCases.map(\.name), "pdf.topMargin")
        configure(bottomPopup, PDFMarginSize.allCases.map(\.name), "pdf.bottomMargin")
        configure(horizontalPopup, PDFMarginSize.allCases.map(\.name), "pdf.horizontalMargin")
        configure(decorationPopup, PDFDecorationSize.allCases.map(\.name), "pdf.decorationSize")
        row("风格 / 字体", stylePopup)
        row("正文字号", sizeControl(fontSlider, fontValue, "pdf.fontSize"))
        row("主标题（H1）", sizeControl(titleSlider, titleValue, "pdf.titleFontSize"))
        row("正文行距", spacingPopup)
        row("纸张", paperPopup)
        row("打印方向", orientationPopup)
        row("上边距 / 页眉", topPopup)
        row("下边距 / 页脚", bottomPopup)
        row("左右边距", horizontalPopup)
        row("页眉页脚字号", decorationPopup)
        for (check, identifier) in [(headerCheck, "pdf.showsHeader"), (pagesCheck, "pdf.showsPageNumbers")] {
            check.target = self
            check.action = #selector(changed)
            check.identifier = NSUserInterfaceItemIdentifier(identifier)
            stack.addArrangedSubview(check)
        }
        let reset = NSButton(title: "恢复默认设置", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)
        let tip = NSTextField(wrappingLabelWithString: "边距包含页眉页脚留白，字号仅调整文字。打印建议使用白纸风格；墨黑风格会打印背景。")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        stack.addArrangedSubview(tip)
        tip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        apply(options)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func selected<T>(_ popup: NSPopUpButton, _ values: [T]) -> T { values[values.indices.contains(popup.indexOfSelectedItem) ? popup.indexOfSelectedItem : 0] }
    private func choose<T: Equatable>(_ popup: NSPopUpButton, _ values: [T], _ value: T) { popup.selectItem(at: values.firstIndex(of: value) ?? 0) }
    private func apply(_ options: PDFExportOptions) {
        choose(stylePopup, PDFExportStyle.allCases, options.style)
        choose(topPopup, PDFMarginSize.allCases, options.topMargin)
        choose(bottomPopup, PDFMarginSize.allCases, options.bottomMargin)
        choose(horizontalPopup, PDFMarginSize.allCases, options.horizontalMargin)
        choose(paperPopup, PDFPaperSize.allCases, options.paperSize)
        choose(orientationPopup, PDFOrientation.allCases, options.orientation)
        choose(spacingPopup, PDFLineSpacing.allCases, options.lineSpacing)
        choose(decorationPopup, PDFDecorationSize.allCases, options.decorationSize)
        fontSlider.doubleValue = Double(options.normalizedFontSize)
        titleSlider.doubleValue = Double(options.normalizedTitleFontSize)
        headerCheck.state = options.showsHeader ? .on : .off
        pagesCheck.state = options.showsPageNumbers ? .on : .off
        updateLabels()
    }
    private func updateLabels() {
        fontSlider.doubleValue = fontSlider.doubleValue.rounded()
        titleSlider.doubleValue = titleSlider.doubleValue.rounded()
        fontValue.stringValue = "\(Int(fontSlider.doubleValue)) pt"
        titleValue.stringValue = "\(Int(titleSlider.doubleValue)) pt"
        decorationPopup.isEnabled = headerCheck.state == .on || pagesCheck.state == .on
    }
    @objc private func changed() { updateLabels(); onChange?(options) }
    @objc private func resetDefaults() { apply(.default); onChange?(options) }
}

final class PDFExportOptionsPanel: NSPanel, NSWindowDelegate {
    private let optionsView: PDFExportOptionsView
    let previewView = PDFView()
    private let status = NSTextField(labelWithString: "正在生成预览…")
    private let pageLabel = NSTextField(labelWithString: "— / — 页")
    private let proceed = NSButton(title: "继续", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let markdown: String, documentTitle: String
    private let baseURL: URL?
    private var previewTask: PDFExporter.ExportTask?
    private var debounceTask: Task<Void, Never>?
    private var generation = UUID()
    private var readyOptions: PDFExportOptions?
    private var selection: PDFExportSelection?
    private(set) var previewData: Data?
    var options: PDFExportOptions { optionsView.options }
    var isPreviewReady: Bool { previewData != nil && readyOptions == options }

    init(markdown: String, title: String, baseURL: URL?, options: PDFExportOptions = .load()) {
        self.markdown = markdown
        documentTitle = title
        self.baseURL = baseURL
        optionsView = PDFExportOptionsView(options: options)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.title = "PDF 导出设置与预览"
        contentMinSize = NSSize(width: 800, height: 500)
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        delegate = self
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        let container = PDFSettingsBackgroundView()
        contentView = container
        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 310, height: 520))
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.drawsBackground = false
        scroller.documentView = optionsView
        let previewContainer = NSView()
        let footer = NSView()
        for view in [scroller, previewContainer, footer] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20), scroller.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            scroller.widthAnchor.constraint(equalToConstant: 310), scroller.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            previewContainer.leadingAnchor.constraint(equalTo: scroller.trailingAnchor, constant: 20), previewContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            previewContainer.topAnchor.constraint(equalTo: scroller.topAnchor), previewContainer.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20), footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16), footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        let previewTitle = NSTextField(labelWithString: "PDF 实际预览")
        previewTitle.font = .boldSystemFont(ofSize: 14)
        let minus = NSButton(title: "−", target: self, action: #selector(zoomOutPreview))
        let plus = NSButton(title: "+", target: self, action: #selector(zoomInPreview))
        let fit = NSButton(title: "适合页面", target: self, action: #selector(fitPreview))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let heading = NSStackView(views: [previewTitle, spinner, NSView(), minus, plus, fit])
        heading.spacing = 6
        let previous = NSButton(title: "上一页", target: self, action: #selector(previousPage))
        let next = NSButton(title: "下一页", target: self, action: #selector(nextPage))
        pageLabel.alignment = .center
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let navigation = NSStackView(views: [previous, pageLabel, next])
        navigation.spacing = 12
        previewView.displayMode = .singlePageContinuous
        previewView.displayDirection = .vertical
        previewView.autoScales = true
        previewView.backgroundColor = .underPageBackgroundColor
        previewView.minScaleFactor = 0.1
        previewView.maxScaleFactor = 4
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        for view in [heading, previewView, navigation, status] { view.translatesAutoresizingMaskIntoConstraints = false; previewContainer.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: previewContainer.topAnchor), heading.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor), heading.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor), heading.heightAnchor.constraint(equalToConstant: 26),
            previewView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor), previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor), previewView.bottomAnchor.constraint(equalTo: navigation.topAnchor, constant: -8),
            navigation.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor), navigation.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor), status.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor), status.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])
        let explanation = NSTextField(labelWithString: "调整后自动更新；导出与预览完全一致。")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        proceed.target = self
        proceed.action = #selector(proceedPressed)
        proceed.keyEquivalent = "\r"
        proceed.bezelStyle = .rounded
        proceed.isEnabled = false
        let buttons = NSStackView(views: [explanation, NSView(), cancel, proceed])
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)
        NSLayoutConstraint.activate([buttons.leadingAnchor.constraint(equalTo: footer.leadingAnchor), buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor), buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor), proceed.widthAnchor.constraint(equalToConstant: 90), cancel.widthAnchor.constraint(equalToConstant: 80)])
        optionsView.onChange = { [weak self] _ in self?.schedulePreview() }
        NotificationCenter.default.addObserver(self, selector: #selector(updatePageLabel), name: .PDFViewPageChanged, object: previewView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func beginSheet(for window: NSWindow, completion: @escaping (PDFExportSelection?) -> Void) {
        window.beginSheet(self) { [self] response in
            orderOut(nil)
            stopPreview()
            completion(response == .OK ? selection : nil)
        }
        schedulePreview()
    }

    private func stopPreview() {
        generation = UUID()
        debounceTask?.cancel()
        debounceTask = nil
        previewTask?.cancel()
        previewTask = nil
        spinner.stopAnimation(nil)
    }

    private func schedulePreview() {
        stopPreview()
        previewData = nil
        readyOptions = nil
        proceed.isEnabled = false
        previewView.alphaValue = 0.45
        status.stringValue = "正在更新预览…"
        status.textColor = .secondaryLabelColor
        spinner.startAnimation(nil)
        pageLabel.stringValue = "预览更新中"
        let token = generation
        let settings = options
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, token == self.generation else { return }
            self.previewTask = PDFExporter.render(markdown: self.markdown, title: self.documentTitle, baseURL: self.baseURL, options: settings) { [weak self] result in
                guard let self, token == self.generation else { return }
                self.previewTask = nil
                self.spinner.stopAnimation(nil)
                switch result {
                case .success(let data):
                    guard let document = PDFDocument(data: data), document.pageCount > 0 else { self.showPreviewError("无法读取预览 PDF，请调整设置重试。"); return }
                    let oldIndex = self.previewView.currentPage.flatMap { self.previewView.document?.index(for: $0) } ?? 0
                    self.previewData = data
                    self.readyOptions = settings
                    self.previewView.document = document
                    self.previewView.autoScales = true
                    if let page = document.page(at: min(oldIndex, document.pageCount - 1)) { self.previewView.go(to: page) }
                    self.previewView.alphaValue = 1
                    self.proceed.isEnabled = true
                    self.status.stringValue = "\(settings.paperSize == .a4 ? "A4" : "Letter") · \(settings.orientation == .portrait ? "纵向" : "横向") · 共 \(document.pageCount) 页 · 可滚动查看"
                    self.updatePageLabel()
                case .failure(let error): self.showPreviewError("预览失败：\(error.localizedDescription) 调整设置或恢复默认可重试。")
                }
            }
        }
    }

    private func showPreviewError(_ message: String) { status.stringValue = message; status.toolTip = message; status.textColor = .systemRed; previewView.alphaValue = 0.45 }
    @objc private func updatePageLabel() {
        guard isPreviewReady, let document = previewView.document else { pageLabel.stringValue = "— / — 页"; return }
        let page = previewView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        pageLabel.stringValue = "\(page) / \(document.pageCount) 页"
    }
    @objc private func zoomInPreview() { previewView.zoomIn(nil) }
    @objc private func zoomOutPreview() { previewView.zoomOut(nil) }
    @objc private func fitPreview() { previewView.autoScales = true }
    @objc private func previousPage() { if previewView.canGoToPreviousPage { previewView.goToPreviousPage(nil) } }
    @objc private func nextPage() { if previewView.canGoToNextPage { previewView.goToNextPage(nil) } }
    @objc private func proceedPressed() {
        guard isPreviewReady, let previewData, let readyOptions else { return }
        selection = PDFExportSelection(options: readyOptions, data: previewData)
        sheetParent?.endSheet(self, returnCode: .OK)
    }
    @objc private func cancelPressed() { stopPreview(); sheetParent?.endSheet(self, returnCode: .cancel) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancelPressed(); return false }
}
