import AppKit
import SwiftUI
import WebKit

#if !DOCUMENT_LIFECYCLE_TESTING
@main
#endif
struct MarkdownStudioApp: App {
    @StateObject private var workspace = MarkdownWorkspace()
    @NSApplicationDelegateAdaptor(MarkdownStudioAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Markdown Studio", id: "editor") {
            MarkdownWorkspaceView()
                .environmentObject(workspace)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { appDelegate.attach(workspace) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Markdown 文件") { workspace.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("打开…") { workspace.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存") { workspace.selectedDocument.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("另存为…") { workspace.selectedDocument.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Button("关闭当前文档") {
                    if workspace.documents.count > 1 {
                        workspace.close(workspace.selectedDocument)
                    } else {
                        NSApp.mainWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .printItem) {
                Button("导出为 PDF…") { workspace.selectedDocument.exportPDF() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(workspace.selectedDocument.isExportingPDF)
            }
        }
    }
}

@MainActor
final class MarkdownStudioAppDelegate: NSObject, NSApplicationDelegate {
    private weak var workspace: MarkdownWorkspace?
    private var pendingURLs: [URL] = []

    func attach(_ workspace: MarkdownWorkspace) {
        self.workspace = workspace
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        workspace.openDocuments(urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) { open(urls) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && (FileManager.default.fileExists(atPath: $0)
                || MarkdownFileIO.markdownExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
                || URL(fileURLWithPath: $0).pathExtension.lowercased() == "txt")
        }
        if !paths.isEmpty { open(paths.map { URL(fileURLWithPath: $0) }) }
    }

    func open(_ urls: [URL]) {
        if let workspace {
            workspace.openDocuments(urls)
            workspace.showEditor?()
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspace?.showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspace?.windowCloseApproved == true { return .terminateNow }
        guard workspace?.canCloseAllDocuments() ?? true else { return .terminateCancel }
        return .terminateNow
    }
}

@MainActor
final class MarkdownWorkspace: ObservableObject {
    @Published private(set) var documents: [MarkdownDocument]
    @Published var selectedID: UUID
    var showEditor: (() -> Void)?
    var windowCloseApproved = false

    init() {
        let welcome = MarkdownDocument()
        documents = [welcome]
        selectedID = welcome.id
    }

    var selectedDocument: MarkdownDocument {
        documents.first { $0.id == selectedID } ?? documents[0]
    }

    func newDocument() {
        let document = MarkdownDocument()
        guard document.createNewDocument() else {
            selectedDocument.errorMessage = document.errorMessage
            return
        }
        add(document)
        showEditor?()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文件"
        panel.allowedContentTypes = MarkdownFileIO.openableTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = selectedDocument.fileURL?.deletingLastPathComponent()
        if panel.runModal() == .OK { openDocuments(panel.urls) }
    }

    func openDocuments(_ urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = documents.first(where: { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == normalizedURL }) {
                selectedID = existing.id
                continue
            }
            let document = MarkdownDocument()
            if document.load(normalizedURL) {
                add(document)
            } else {
                errors.append("\(url.lastPathComponent)：\(document.errorMessage ?? "无法打开文件")")
            }
        }
        if !errors.isEmpty { selectedDocument.errorMessage = errors.joined(separator: "\n") }
    }

    private func add(_ document: MarkdownDocument) {
        // Replace only the untouched welcome tab. Never overwrite an edited document.
        if documents.count == 1, documents[0].fileURL == nil, !documents[0].isDirty {
            documents = [document]
        } else {
            documents.append(document)
        }
        selectedID = document.id
    }

    func close(_ document: MarkdownDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        guard document.shouldDiscardChanges() else { return }
        let remaining = documents.filter { $0.id != document.id }
        documents = remaining.isEmpty ? [MarkdownDocument()] : remaining
        if selectedID == document.id { selectedID = documents[min(index, documents.count - 1)].id }
    }

    func canCloseAllDocuments() -> Bool {
        documents.allSatisfy { $0.shouldDiscardChanges() }
    }
}

@MainActor
final class MarkdownDocument: ObservableObject {
    let id = UUID()
    @Published var text: String = MarkdownExamples.defaultDocument
    @Published var fileURL: URL?
    @Published var isDirty = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isExportingPDF = false
    private var encoding: String.Encoding = .utf8

    var displayName: String { fileURL?.lastPathComponent ?? "未命名文档" }

    @discardableResult
    func createNewDocument() -> Bool {
        do {
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let initialText = "# 新文档\n\n"
            let destination = try MarkdownFileIO.createNote(in: downloads, text: initialText)
            text = initialText
            fileURL = destination
            encoding = .utf8
            errorMessage = nil
            isDirty = false
            notice = "已在下载目录创建：\(destination.lastPathComponent)"
            return true
        } catch {
            errorMessage = "无法新建文件：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        do {
            let loaded = try MarkdownFileIO.read(url)
            text = loaded.text
            encoding = loaded.encoding
            fileURL = url
            errorMessage = nil
            isDirty = false
            notice = "已打开：\(url.lastPathComponent)"
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            errorMessage = "无法读取文件：\(error.localizedDescription)"
            return false
        }
    }

    func shouldDiscardChanges() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存“\(displayName)”的更改？"
        alert.informativeText = "保存后再继续，或选择不保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        do {
            try MarkdownFileIO.write(text, to: url, encoding: encoding)
            errorMessage = nil
            isDirty = false
            notice = "已保存"
            return true
        } catch {
            errorMessage = "无法保存文件：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "保存 Markdown 文件"
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "note.md"
        panel.allowedContentTypes = [MarkdownFileIO.markdownType]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            let destination = url.pathExtension.isEmpty ? url.appendingPathExtension("md") : url
            do {
                try MarkdownFileIO.write(text, to: destination, encoding: encoding)
                fileURL = destination
                errorMessage = nil
                isDirty = false
                notice = "已保存：\(destination.lastPathComponent)"
                NSDocumentController.shared.noteNewRecentDocumentURL(destination)
                return true
            } catch {
                errorMessage = "无法另存为：\(error.localizedDescription)"
            }
        }
        return false
    }

    func exportPDF() {
        guard !isExportingPDF else { return }
        guard let exportWindow = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) else {
            errorMessage = "请先打开文档窗口，再导出 PDF。"
            return
        }
        let optionsPanel = PDFExportOptionsPanel()
        guard optionsPanel.run() else { return }

        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Markdown 文档") + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let html = MarkdownRenderer.documentHTML(markdown: text, title: displayName, appearance: optionsPanel.options.appearance)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
        isExportingPDF = true
        notice = "正在导出 PDF…"
        PDFExporter.export(webView: webView, window: exportWindow, html: html, baseURL: fileURL?.deletingLastPathComponent(), to: destination) { [weak self] result in
            DispatchQueue.main.async {
                self?.isExportingPDF = false
                switch result {
                case .success: self?.notice = "已导出 PDF：\(destination.lastPathComponent)"
                case .failure(let error):
                    self?.notice = "PDF 导出未完成"
                    self?.errorMessage = "PDF 导出失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

enum PDFExportStyle: CaseIterable {
    case clean, paper, book, night

    var name: String {
        switch self {
        case .clean: "简洁白纸"
        case .paper: "暖色纸张"
        case .book: "书籍衬线"
        case .night: "夜间墨黑"
        }
    }

    var css: String {
        switch self {
        case .clean: "body { color:#202124; background:#ffffff; } h1,h2 { border-color:#d9dde3; }"
        case .paper: "body { color:#42382d; background:#fcf6e9; } h1,h2 { border-color:#d8c7a9; } th { background:#f2e7d2; } code,pre { background:#f3eadb; }"
        case .book: "body { color:#27231e; background:#fffdf8; font-family: Georgia, 'Songti SC', 'STSong', serif; } h1,h2,h3 { font-family: -apple-system, 'PingFang SC', sans-serif; }"
        case .night: "body { color:#e9edf2; background:#1d232d; } h1,h2 { border-color:#485363; } th { background:#293442; } td { border-color:#485363; } code,pre { background:#293442; } a { color:#8ab4f8; } blockquote { color:#b8c2cf; border-color:#7d8998; }"
        }
    }
}

struct MarkdownAppearance {
    let fontSize: CGFloat
    let additionalCSS: String

    static let preview = MarkdownAppearance(fontSize: 16, additionalCSS: "")
}

struct PDFExportOptions {
    let style: PDFExportStyle
    let fontSize: CGFloat

    var appearance: MarkdownAppearance {
        let css = """
        \(style.css)
        body { font-size: \(Int(fontSize))pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        @media print {
          html { background: #fff; }
          body { isolation: isolate; }
          body::before { content: ''; position: fixed; inset: 0; z-index: -1; background: inherit; }
          h1,h2,h3,h4,h5,h6 { break-after: avoid; }
          tr, img { break-inside: avoid; }
          pre { white-space: pre-wrap; overflow: visible; overflow-wrap: anywhere; }
          td,th { overflow-wrap: anywhere; }
        }
        """
        return MarkdownAppearance(fontSize: fontSize, additionalCSS: css)
    }
}

final class PDFExportOptionsView: NSView {
    private let stylePopup = NSPopUpButton(frame: NSRect(x: 92, y: 52, width: 268, height: 26), pullsDown: false)
    private let fontSlider = NSSlider(value: 16, minValue: 11, maxValue: 26, target: nil, action: nil)
    private let fontValue = NSTextField(labelWithString: "16 pt")

    var options: PDFExportOptions {
        PDFExportOptions(style: PDFExportStyle.allCases[stylePopup.indexOfSelectedItem], fontSize: CGFloat(fontSlider.doubleValue))
    }

    override init(frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 360, height: 84)) {
        super.init(frame: frameRect)
        let styleLabel = NSTextField(labelWithString: "导出风格")
        styleLabel.frame = NSRect(x: 0, y: 56, width: 82, height: 20)
        addSubview(styleLabel)
        stylePopup.addItems(withTitles: PDFExportStyle.allCases.map(\.name))
        stylePopup.selectItem(at: 0)
        addSubview(stylePopup)

        let sizeLabel = NSTextField(labelWithString: "正文字号")
        sizeLabel.frame = NSRect(x: 0, y: 18, width: 82, height: 20)
        addSubview(sizeLabel)
        fontSlider.frame = NSRect(x: 92, y: 18, width: 210, height: 20)
        fontSlider.target = self
        fontSlider.action = #selector(fontSizeChanged)
        fontSlider.numberOfTickMarks = 16
        fontSlider.allowsTickMarkValuesOnly = true
        addSubview(fontSlider)
        fontValue.frame = NSRect(x: 312, y: 18, width: 48, height: 20)
        fontValue.alignment = .right
        addSubview(fontValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fontSizeChanged() {
        fontValue.stringValue = "\(Int(fontSlider.doubleValue)) pt"
    }
}

final class PDFExportOptionsPanel: NSPanel, NSWindowDelegate {
    private let optionsView = PDFExportOptionsView()

    var options: PDFExportOptions { optionsView.options }

    init() {
        let contentSize = NSSize(width: 408, height: 178)
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "PDF 导出设置"
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        delegate = self
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true

        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        contentView = container

        let message = NSTextField(labelWithString: "选择导出风格和正文字号，然后选择保存位置。")
        message.frame = NSRect(x: 24, y: 136, width: 360, height: 20)
        container.addSubview(message)

        optionsView.frame.origin = NSPoint(x: 24, y: 48)
        container.addSubview(optionsView)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        cancel.frame = NSRect(x: 208, y: 14, width: 84, height: 30)
        cancel.keyEquivalent = "\u{1b}"
        container.addSubview(cancel)

        let proceed = NSButton(title: "继续", target: self, action: #selector(proceedPressed))
        proceed.frame = NSRect(x: 300, y: 14, width: 84, height: 30)
        proceed.keyEquivalent = "\r"
        proceed.bezelStyle = .rounded
        container.addSubview(proceed)
        initialFirstResponder = optionsView
    }

    func run() -> Bool {
        center()
        makeKeyAndOrderFront(nil)
        return NSApp.runModal(for: self) == .OK
    }

    @objc private func proceedPressed() { closeModal(with: .OK) }
    @objc private func cancelPressed() { closeModal(with: .cancel) }

    func windowWillClose(_ notification: Notification) { NSApp.stopModal(withCode: .cancel) }

    private func closeModal(with response: NSApplication.ModalResponse) {
        NSApp.stopModal(withCode: response)
        orderOut(nil)
    }
}

struct MarkdownWorkspaceView: View {
    @EnvironmentObject private var workspace: MarkdownWorkspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if workspace.documents.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.documents, id: \.id) { document in
                            MarkdownDocumentTab(document: document)
                        }
                    }
                    .padding(8)
                }
                .background(.bar)
            }
            ContentView()
                .environmentObject(workspace.selectedDocument)
                .id(workspace.selectedID)
        }
        .background(EditorWindowGuard(workspace: workspace))
        .onAppear {
            // A single editor window owns the tabs, including after the last window closes.
            workspace.showEditor = { openWindow(id: "editor") }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            workspace.openDocuments(urls)
            return true
        }
    }
}

/// Ask before closing the only window, rather than after SwiftUI has already closed it.
struct EditorWindowGuard: NSViewRepresentable {
    let workspace: MarkdownWorkspace

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attach(to: $0) }
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    final class WindowProbe: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private let workspace: MarkdownWorkspace
        private weak var originalDelegate: NSWindowDelegate?
        private var prompting = false

        init(workspace: MarkdownWorkspace) { self.workspace = workspace }

        @MainActor func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !prompting else { return false }
            prompting = true
            defer { prompting = false }
            guard workspace.canCloseAllDocuments(), originalDelegate?.windowShouldClose?(sender) ?? true else { return false }
            // The Window scene terminates after closing; don't ask a second time.
            workspace.windowCloseApproved = true
            return true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

struct MarkdownDocumentTab: View {
    @EnvironmentObject private var workspace: MarkdownWorkspace
    @ObservedObject var document: MarkdownDocument

    var body: some View {
        HStack(spacing: 4) {
            Button(document.displayName + (document.isDirty ? " •" : "")) {
                workspace.selectedID = document.id
            }
            .buttonStyle(.plain)
            Button { workspace.close(document) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("关闭“\(document.displayName)”")
                .accessibilityLabel("关闭“\(document.displayName)”")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(workspace.selectedID == document.id ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ContentView: View {
    @EnvironmentObject private var workspace: MarkdownWorkspace
    @EnvironmentObject private var document: MarkdownDocument
    @State private var showingPreview = true
    @State private var renderEditing = false
    @State private var editorScrollProgress = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: workspace.newDocument) { Label("新建", systemImage: "square.and.pencil") }
                Button(action: workspace.presentOpenPanel) { Label("打开", systemImage: "folder") }
                Button { document.save() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .disabled(!document.isDirty && document.fileURL != nil)
                Button { document.saveAs() } label: { Label("另存为", systemImage: "arrow.down.doc") }
                Spacer()
                Toggle(isOn: $showingPreview) { Label("预览", systemImage: "eye") }
                    .toggleStyle(.button)
                Toggle(isOn: $renderEditing) { Label("渲染编辑", systemImage: "pencil.and.outline") }
                    .toggleStyle(.button)
                    .disabled(!showingPreview)
                Button(action: document.exportPDF) { Label("导出 PDF", systemImage: "doc.richtext") }
                    .disabled(document.isExportingPDF)
            }
            .padding(12)
            .background(.bar)

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    panelHeader("Markdown", icon: "curlybraces")
                    SyncedMarkdownEditor(text: Binding(
                        get: { document.text },
                        set: { document.text = $0; document.isDirty = true }
                    ), onScrollChange: { editorScrollProgress = $0 }, onOpenFiles: workspace.openDocuments)
                }
                .frame(minWidth: 380)

                if showingPreview {
                    VStack(alignment: .leading, spacing: 0) {
                        panelHeader(renderEditing ? "渲染编辑 — 直接在右侧修改" : "实时预览", icon: renderEditing ? "pencil.and.outline" : "doc.text.image")
                        if renderEditing {
                            RenderedMarkdownEditor(
                                markdown: Binding(
                                    get: { document.text },
                                    set: { document.text = $0; document.isDirty = true }
                                ),
                                baseURL: document.fileURL?.deletingLastPathComponent(),
                                onOpenFiles: workspace.openDocuments
                            )
                        } else {
                            MarkdownPreview(
                                markdown: document.text,
                                baseURL: document.fileURL?.deletingLastPathComponent(),
                                scrollProgress: editorScrollProgress,
                                onOpenFiles: workspace.openDocuments
                            )
                        }
                    }
                    .frame(minWidth: 380)
                }
            }

            HStack {
                Text(document.fileURL?.path ?? "尚未保存 — 新建文档将保存到下载目录")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(document.isDirty ? "未保存的更改" : (document.notice ?? "已保存"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .navigationTitle(document.displayName + (document.isDirty ? " •" : ""))
        .alert("Markdown Studio", isPresented: Binding(
            get: { document.errorMessage != nil },
            set: { if !$0 { document.errorMessage = nil } }
        )) {
            Button("好") { document.errorMessage = nil }
        } message: {
            Text(document.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func panelHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SyncedMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let onScrollChange: (Double) -> Void
    let onOpenFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = MarkdownSourceTextView()
        textView.onOpenFiles = onOpenFiles
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.startObserving(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scrollView.documentView as? MarkdownSourceTextView)?.onOpenFiles = onOpenFiles
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncedMarkdownEditor
        private weak var scrollView: NSScrollView?

        init(parent: SyncedMarkdownEditor) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func startObserving(_ scrollView: NSScrollView) {
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reportScrollPosition),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func reportScrollPosition() {
            guard let scrollView else { return }
            let visibleHeight = scrollView.contentView.bounds.height
            let contentHeight = scrollView.documentView?.bounds.height ?? visibleHeight
            let maximum = max(1, contentHeight - visibleHeight)
            let progress = min(1, max(0, scrollView.contentView.bounds.origin.y / maximum))
            parent.onScrollChange(progress)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class MarkdownSourceTextView: NSTextView {
    var onOpenFiles: (([URL]) -> Void)?

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURLs(from: sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onOpenFiles?(urls)
        return true
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let scrollProgress: Double
    let onOpenFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = MarkdownFileDropWebView(frame: .zero, configuration: configuration)
        view.onOpenFiles = onOpenFiles
        view.registerForDraggedTypes(view.registeredDraggedTypes + [.fileURL])
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        (view as? MarkdownFileDropWebView)?.onOpenFiles = onOpenFiles
        let html = MarkdownRenderer.documentHTML(markdown: markdown, title: "预览")
        context.coordinator.scrollProgress = scrollProgress
        let basePath = baseURL?.path
        if context.coordinator.lastHTML != html || context.coordinator.lastBasePath != basePath {
            context.coordinator.lastHTML = html
            context.coordinator.lastBasePath = basePath
            view.loadHTMLString(html, baseURL: baseURL)
        } else {
            context.coordinator.applyScroll(to: view)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var lastBasePath: String?
        var scrollProgress = 0.0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyScroll(to: webView) }

        func applyScroll(to webView: WKWebView) {
            let fraction = min(1, max(0, scrollProgress))
            let script = "window.scrollTo(0, Math.max(0, document.documentElement.scrollHeight - window.innerHeight) * \(fraction));"
            webView.evaluateJavaScript(script)
        }
    }
}

struct RenderedMarkdownEditor: NSViewRepresentable {
    @Binding var markdown: String
    let baseURL: URL?
    let onOpenFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "markdownChanged")
        let view = MarkdownFileDropWebView(frame: .zero, configuration: configuration)
        view.onOpenFiles = onOpenFiles
        view.registerForDraggedTypes(view.registeredDraggedTypes + [.fileURL])
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        (view as? MarkdownFileDropWebView)?.onOpenFiles = onOpenFiles
        context.coordinator.parent = self
        let basePath = baseURL?.path
        if context.coordinator.acceptingRenderedEdit {
            context.coordinator.acceptingRenderedEdit = false
            context.coordinator.lastMarkdown = markdown
            context.coordinator.lastBasePath = basePath
            return
        }
        guard context.coordinator.lastMarkdown != markdown || context.coordinator.lastBasePath != basePath else { return }
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastBasePath = basePath
        view.loadHTMLString(MarkdownRenderer.documentHTML(markdown: markdown, title: "渲染编辑", editable: true), baseURL: baseURL)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RenderedMarkdownEditor
        var lastMarkdown = ""
        var lastBasePath: String?
        var acceptingRenderedEdit = false

        init(parent: RenderedMarkdownEditor) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "markdownChanged", let value = message.body as? String else { return }
            acceptingRenderedEdit = true
            lastMarkdown = value
            parent.markdown = value
        }
    }
}

/// WebKit normally navigates to dropped files. Route them to the editor instead.
final class MarkdownFileDropWebView: WKWebView {
    var onOpenFiles: (([URL]) -> Void)?

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileURLs(from: sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onOpenFiles?(urls)
        return true
    }
}

@MainActor
enum PDFExporter {
    private static var jobs: [UUID: ExportJob] = [:]

    static func export(webView: WKWebView, window: NSWindow, html: String, baseURL: URL?, to url: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let job = ExportJob(webView: webView, window: window, destination: url, completion: completion)
        jobs[job.id] = job
        webView.navigationDelegate = job
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    enum PDFExportError: LocalizedError {
        case couldNotCreateFile
        var errorDescription: String? { "系统未能完成 PDF 文件写入。" }
    }

    @MainActor private final class ExportJob: NSObject, WKNavigationDelegate {
        let id = UUID()
        let webView: WKWebView
        private weak var window: NSWindow?
        let destination: URL
        let temporaryPDF = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownStudio-export-\(UUID().uuidString).pdf")
        let completion: @MainActor (Result<Void, Error>) -> Void
        private var operation: NSPrintOperation?
        private var started = false

        init(webView: WKWebView, window: NSWindow, destination: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            self.webView = webView
            self.window = window
            self.destination = destination
            self.completion = completion
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !started else { return }
            started = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await webView.callAsyncJavaScript("await document.fonts.ready;", arguments: [:], in: nil, contentWorld: .page)
                    self.beginPrinting()
                } catch { self.finish(.failure(error)) }
            }
        }

        private func beginPrinting() {
            guard let window else {
                finish(.failure(PDFExportError.couldNotCreateFile))
                return
            }
            let printInfo = NSPrintInfo(dictionary: [:])
            printInfo.paperSize = NSSize(width: 595.28, height: 841.89)
            printInfo.leftMargin = 42
            printInfo.rightMargin = 42
            printInfo.topMargin = 48
            printInfo.bottomMargin = 48
            printInfo.horizontalPagination = .fit
            printInfo.verticalPagination = .automatic
            printInfo.isHorizontallyCentered = true
            printInfo.isVerticallyCentered = false
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporaryPDF
            printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
            let operation = webView.printOperation(with: printInfo)
            self.operation = operation
            operation.showsPrintPanel = false
            operation.showsProgressPanel = true
            // WebKit needs the main run loop to calculate pagination. Synchronous
            // run() on the main thread can interpret its pending page count as Int.max.
            operation.canSpawnSeparateThread = true
            operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }

        @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            DispatchQueue.main.async { self.finishPrinting(success: success) }
        }

        private func finishPrinting(success: Bool) {
            do {
                guard success else { throw PDFExportError.couldNotCreateFile }
                let data = try Data(contentsOf: temporaryPDF)
                guard !data.isEmpty else { throw PDFExportError.couldNotCreateFile }
                // Leave an existing PDF untouched if rendering or writing fails.
                try data.write(to: destination, options: .atomic)
                finish(.success(()))
            } catch { finish(.failure(error)) }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard jobs.removeValue(forKey: id) != nil else { return }
            webView.navigationDelegate = nil
            operation = nil
            try? FileManager.default.removeItem(at: temporaryPDF)
            completion(result)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    }
}

enum MarkdownRenderer {
    private static let resourceBundle: Bundle = {
        let appResourceBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("MarkdownStudio_MarkdownStudio.bundle")) }
        return appResourceBundle ?? Bundle.module
    }()

    private static func resourceText(_ name: String, _ fileExtension: String) -> String {
        guard let url = resourceBundle.url(forResource: name, withExtension: fileExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    private static let markedScript = resourceText("marked.min", "js")
    private static let katexScript = resourceText("katex.min", "js")
    private static let katexCSS: String = {
        let fontsURL = resourceBundle.resourceURL?.appendingPathComponent("fonts/", isDirectory: true).absoluteString ?? ""
        return resourceText("katex.min", "css").replacingOccurrences(of: "url(fonts/", with: "url(\(fontsURL)")
    }()

    static func documentHTML(markdown: String, title: String, appearance: MarkdownAppearance = .preview, editable: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
        <style>
        :root { color-scheme: light dark; } body { margin: 0 auto; max-width: 880px; padding: 38px 48px; font: \(Int(appearance.fontSize))px -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif; line-height: 1.72; color: #202124; background: #fff; } h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin-top: 1.55em; } h1 { font-size: 2em; border-bottom: 1px solid #ddd; padding-bottom: .35em; } h2 { font-size: 1.5em; border-bottom: 1px solid #e5e5e5; padding-bottom: .25em; } code { background: #f2f4f7; padding: .15em .35em; border-radius: 4px; font: .9em ui-monospace, SFMono-Regular, Menlo, monospace; } pre { background: #f5f7f9; padding: 16px; border-radius: 8px; overflow:auto; } pre code { padding:0; background:none; } blockquote { border-left: 4px solid #9ba6b2; color: #5b6570; margin: 1em 0; padding: .1em 1em; } table { border-collapse: collapse; width:100%; } th,td { border:1px solid #d9dde3; padding: 7px 10px; text-align:left; } th { background:#f5f7f9; } img { max-width:100%; } a { color:#1967d2; } hr { border:0; border-top:1px solid #ddd; margin: 2em 0; } input[type=checkbox] { margin-right: .45em; } kbd { border: 1px solid #b8bec7; border-bottom-width: 2px; border-radius: 4px; background: #f5f5f5; padding: .05em .35em; font: .85em ui-monospace, monospace; } details { border: 1px solid #d9dde3; border-radius: 7px; padding: .45em .8em; } summary { cursor: pointer; font-weight: 600; } \(katexCSS) \(appearance.additionalCSS) @media print { body { padding: 20px; max-width: none; } }
        </style></head><body><main id="content"></main><script>\(markedScript)</script><script>\(katexScript)</script>
        <script>
        const source = \(scriptString(markdown));
        const renderEditing = \(editable ? "true" : "false");
        const rawHTML = marked.parse(source, { gfm: true, breaks: false });
        const safe = new DOMParser().parseFromString(rawHTML, 'text/html');
        safe.querySelectorAll('script, style, iframe, frame, frameset, object, embed, form, button, textarea, select, option, link, meta, base, svg, math').forEach(node => node.remove());
        safe.querySelectorAll('input').forEach(node => {
          if (node.getAttribute('type') !== 'checkbox') node.remove();
          else [...node.attributes].forEach(attr => { if (!['type', 'checked', 'disabled'].includes(attr.name.toLowerCase())) node.removeAttribute(attr.name); });
        });
        safe.querySelectorAll('*').forEach(node => {
          [...node.attributes].forEach(attr => {
            const name = attr.name.toLowerCase(); const value = attr.value.trim().toLowerCase();
            if (name.startsWith('on') || name === 'style' || name === 'srcdoc' || ((name === 'href' || name === 'src') && (value.startsWith('javascript:') || value.startsWith('data:text/html')))) node.removeAttribute(attr.name);
          });
        });
        document.getElementById('content').innerHTML = safe.body.innerHTML;
        const content = document.getElementById('content');
        const textNodes = [];
        const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, {
          acceptNode(node) { return node.parentElement && !node.parentElement.closest('code, pre, kbd, script, style') ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
        });
        while (walker.nextNode()) textNodes.push(walker.currentNode);
        const mathPattern = /(^|[^\\\\])(?:\\$\\$([\\s\\S]+?)\\$\\$|\\$([^$\\n]+?)\\$)/g;
        textNodes.forEach(node => {
          const text = node.nodeValue;
          let match, lastIndex = 0, changed = false;
          const fragment = document.createDocumentFragment();
          while ((match = mathPattern.exec(text)) !== null) {
            changed = true;
            const prefixEnd = match.index + match[1].length;
            fragment.append(document.createTextNode(text.slice(lastIndex, prefixEnd)));
            const expression = (match[2] ?? match[3]).trim();
            const wrapper = document.createElement(match[2] ? 'div' : 'span');
            wrapper.dataset.markdownMath = expression;
            wrapper.dataset.displayMath = Boolean(match[2]).toString();
            wrapper.innerHTML = katex.renderToString(expression, { throwOnError: false, displayMode: Boolean(match[2]) });
            fragment.append(wrapper);
            lastIndex = match.index + match[0].length;
          }
          if (changed) { fragment.append(document.createTextNode(text.slice(lastIndex))); node.replaceWith(fragment); }
        });
        function inlineMarkdown(node) {
          if (node.nodeType === Node.TEXT_NODE) return node.nodeValue;
          if (node.nodeType !== Node.ELEMENT_NODE) return '';
          if (node.dataset && node.dataset.markdownMath) return node.dataset.displayMath === 'true' ? `$$\\n${node.dataset.markdownMath}\\n$$` : `$${node.dataset.markdownMath}$`;
          const value = Array.from(node.childNodes).map(inlineMarkdown).join('');
          switch (node.tagName) {
            case 'STRONG': case 'B': return `**${value}**`;
            case 'EM': case 'I': return `*${value}*`;
            case 'DEL': case 'S': return `~~${value}~~`;
            case 'CODE': return `\\`${node.textContent.replace(/`/g, '\\\\`')}\\``;
            case 'A': return `[${value}](${node.getAttribute('href') || ''})`;
            case 'IMG': return `![${node.getAttribute('alt') || ''}](${node.getAttribute('src') || ''})`;
            case 'BR': return '  \\n';
            case 'INPUT': return node.checked ? '[x] ' : '[ ] ';
            default: return value;
          }
        }
        function listMarkdown(list, depth = 0) {
          return Array.from(list.children).filter(node => node.tagName === 'LI').map((item, index) => {
            const prefix = list.tagName === 'OL' ? `${index + 1}. ` : '- ';
            const own = Array.from(item.childNodes).filter(node => !['UL', 'OL'].includes(node.tagName)).map(inlineMarkdown).join('').trim();
            const nested = Array.from(item.children).filter(node => ['UL', 'OL'].includes(node.tagName)).map(node => listMarkdown(node, depth + 1)).join('');
            return `${'  '.repeat(depth)}${prefix}${own}\\n${nested}`;
          }).join('');
        }
        function tableMarkdown(table) {
          const rows = Array.from(table.querySelectorAll('tr'));
          if (!rows.length) return '';
          const row = element => Array.from(element.children).map(cell => inlineMarkdown(cell).replace(/\\|/g, '\\\\|').trim());
          const header = row(rows[0]);
          const divider = header.map((_, index) => {
            const headerCell = rows[0].children[index];
            const align = headerCell?.getAttribute('align') || headerCell?.style.textAlign;
            return align === 'center' ? ':---:' : align === 'right' ? '---:' : ':---';
          });
          return [header, divider, ...rows.slice(1).map(row)].map(cells => `| ${cells.join(' | ')} |`).join('\\n');
        }
        function blockMarkdown(node) {
          if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.trim();
          if (node.nodeType !== Node.ELEMENT_NODE) return '';
          const children = () => Array.from(node.childNodes).map(blockMarkdown).filter(Boolean).join('\\n\\n');
          const text = inlineMarkdown(node).trim();
          if (/^H[1-6]$/.test(node.tagName)) return `${'#'.repeat(Number(node.tagName[1]))} ${text}`;
          if (node.tagName === 'P') return text;
          if (node.tagName === 'PRE') { const code = node.textContent.replace(/\\n$/, ''); const language = node.querySelector('code')?.className.match(/language-([^\\s]+)/)?.[1] || ''; return `\\`\\`\\`${language}\\n${code}\\n\\`\\`\\``; }
          if (node.tagName === 'BLOCKQUOTE') return children().split('\\n').map(line => `> ${line}`).join('\\n');
          if (node.tagName === 'UL' || node.tagName === 'OL') return listMarkdown(node).trim();
          if (node.tagName === 'TABLE') return tableMarkdown(node);
          if (node.tagName === 'HR') return '---';
          if (node.tagName === 'IMG') return text;
          return children() || text;
        }
        function renderedToMarkdown(root) { return Array.from(root.childNodes).map(blockMarkdown).filter(Boolean).join('\\n\\n').replace(/\\n{3,}/g, '\\n\\n').trim() + '\\n'; }
        if (renderEditing) {
          content.contentEditable = 'true';
          content.spellcheck = true;
          content.setAttribute('aria-label', '渲染编辑区');
          content.querySelectorAll('[data-markdown-math]').forEach(node => { node.contentEditable = 'false'; });
          content.addEventListener('input', () => window.webkit.messageHandlers.markdownChanged.postMessage(renderedToMarkdown(content)));
        }
        </script></body></html>
        """
    }

    private static func scriptString(_ value: String) -> String {
        let encoded = String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        return encoded.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum MarkdownExamples {
    static let defaultDocument = #"""
# Markdown Studio · Markdown 语法示例

这是应用启动时的示例文档。左侧可以直接修改，右侧使用 **GFM / CommonMark** 实时预览；按 `⌘P` 可以导出为 PDF。

> 本地预览会安全地过滤脚本、嵌入网页和表单等危险 HTML；普通排版 HTML（如 `details` 和 `kbd`）可使用。

---

## 1. 标题与段落

# 一级标题
## 二级标题
### 三级标题
#### 四级标题
##### 五级标题
###### 六级标题

这是普通段落。两个空行会开始一个新段落。

Setext 一级标题
=============

Setext 二级标题
-------------

这一行结尾有两个空格，可以强制换行。  
这是换行后的内容。

---

## 2. 行内文字样式

**粗体**、__另一种粗体__、*斜体*、_另一种斜体_、***粗斜体***、~~删除线~~。

行内代码：`let title = "Markdown"`。反斜杠可以转义：\*不是斜体\*；在行首的 `#` 前加反斜杠可阻止它成为标题。

可直接输入 Unicode：中文、é、✅、🚀。`:smile:` 这类短代码不是通用 Markdown，本应用不会自动转换为表情。

---

## 3. 链接、自动链接与图片

[内联链接](https://commonmark.org "可选标题") 与 [引用式链接][gfm-spec]。

自动链接：<https://github.com>、<hello@example.com>、https://www.example.com 和 www.example.com。

![图片替代文字](./example-image.png "本地或网络图片地址")

[gfm-spec]: https://github.github.com/gfm/ "GitHub Flavored Markdown 规范"

---

## 4. 列表、嵌套列表与任务清单

- 无序项目
  - 二级项目
    - 三级项目
- 另一个项目

1. 有序项目
2. 第二项
   1. 嵌套编号
   2. 嵌套编号二

- [x] 已完成任务
- [ ] 未完成任务
  - [x] 嵌套任务
  - [ ] 另一个嵌套任务

---

## 5. 引用与分隔线

> 一级引用可以包含 **行内格式**。
>
> > 这是一段二级引用。
> >
> > - 引用中的列表
> > - 第二项

***

---

## 6. 表格（GFM）

| 左对齐 | 居中 | 右对齐 |
| :--- | :---: | ---: |
| 普通文字 | **粗体** | `123` |
| 第二行 | ~~删除线~~ | 456 |

单元格中的竖线需要转义：`\|`。

---

## 7. 代码：行内、围栏、缩进与嵌套围栏

行内代码已经在前面展示。下面是带语言标识的代码围栏（目前按等宽代码块显示；语法高亮可后续加入）：

```swift
struct Note {
    let title: String
    let tags: [String]
}
```

```python
def greet(name: str) -> str:
    return f"Hello, {name}!"
```

四个空格或一个 Tab 开头的行也是代码块：

    npm run build
    ./MarkdownStudio.app

以下是“代码块中再展示 Markdown 代码块”的嵌套围栏写法：

````markdown
```bash
echo "这是嵌套的代码围栏"
```
````

---

## 8. 安全的原始 HTML

<details>
<summary>点击展开</summary>

这里可以放入 **Markdown 文字**和普通文本。
</details>

按 <kbd>⌘</kbd> + <kbd>S</kbd> 保存文档。

---

## 9. 常见扩展

其中数学公式已内置离线渲染；其余项目通常需要额外解析器或运行时，目前会作为普通 Markdown 文本处理。

### 脚注（扩展）

这里是一段脚注引用[^1]。

[^1]: 需要脚注扩展。

### 数学公式（已支持 KaTeX）

行内：$E = mc^2$、$\frac{a}{b}$、$\sqrt{x^2 + y^2}$。

块级：

$$
\int_a^b f(x)\,dx
$$

### Mermaid 图（扩展）

```mermaid
flowchart LR
    Write[编写 Markdown] --> Preview[实时预览]
    Preview --> PDF[导出 PDF]
```

### YAML Front Matter、目录、Wiki 链接与提示框

```yaml
---
title: 文档标题
tags: [markdown, notes]
---
```

- `[[]]` Wiki 链接
- 自动目录（TOC）
- GitHub Alerts，例如 `> [!NOTE]`
- 公式编号、图表、流程图、引用文献

脚注、Mermaid、YAML Front Matter、目录、Wiki 链接和 GitHub Alerts 都可以继续加入；每一项都需要明确的渲染规则或额外离线组件。
"""#
}
