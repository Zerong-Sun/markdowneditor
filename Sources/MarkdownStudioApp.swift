import AppKit
import SwiftUI
import WebKit

#if !DOCUMENT_LIFECYCLE_TESTING
@main
#endif
struct MarkdownStudioApp: App {
    @StateObject private var workspace = MarkdownWorkspace()
    @NSApplicationDelegateAdaptor(MarkdownStudioAppDelegate.self) private var appDelegate
    @AppStorage("editor.displayMode") private var displayMode = EditorDisplayMode.split

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
                Button("从磁盘重新载入") { workspace.selectedDocument.reloadFromDisk() }
                    .disabled(workspace.selectedDocument.fileURL == nil)
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
            CommandMenu("显示模式") {
                Button("仅编辑") { displayMode = .source }
                    .keyboardShortcut("1", modifiers: .command)
                Button("双栏") { displayMode = .split }
                    .keyboardShortcut("2", modifiers: .command)
                Button("仅渲染（阅读，隐藏源码）") { displayMode = .reading }
                    .keyboardShortcut("3", modifiers: .command)
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
        workspace?.windowCloseApproved = false
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
        welcome.workspace = self
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
        windowCloseApproved = false
        var errors: [String] = []
        for url in urls {
            let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            if let existing = documents.first(where: { document in document.fileURL.map { MarkdownFileIO.refersToSameFile($0, normalizedURL) } == true }) {
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
        windowCloseApproved = false
        document.workspace = self
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
        documents.forEach { $0.workspace = self }
        if selectedID == document.id { selectedID = documents[min(index, documents.count - 1)].id }
    }

    func canCloseAllDocuments() -> Bool {
        documents.allSatisfy { $0.shouldDiscardChanges() }
    }
}

@MainActor
final class MarkdownDocument: ObservableObject {
    enum UnsavedChangesChoice { case save, cancel, discard }
    let id = UUID()
    @Published var text: String = MarkdownExamples.defaultDocument
    @Published var fileURL: URL?
    @Published var isDirty = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isExportingPDF = false
    @Published private(set) var exportProgress: Double?
    @Published private(set) var exportedPDFURL: URL?
    private var exportTask: PDFExporter.ExportTask?
    private var exportOptionsPanel: PDFExportOptionsPanel?
    private var exportSavePanel: NSSavePanel?
    private var encoding: String.Encoding = .utf8
    private var diskRevision: MarkdownFileIO.Revision?
    private var savedText = MarkdownExamples.defaultDocument
    weak var workspace: MarkdownWorkspace?
    let sourceEditorState = MarkdownSourceEditorState()
    var confirmUnsavedChanges: @MainActor (String) -> UnsavedChangesChoice = MarkdownDocument.presentUnsavedChangesAlert
    private let pdfDefaults: UserDefaults

    init(pdfDefaults: UserDefaults = .standard) { self.pdfDefaults = pdfDefaults }

    var displayName: String { fileURL?.lastPathComponent ?? "未命名文档" }

    func edit(_ newText: String) {
        guard newText != text else { return }
        workspace?.windowCloseApproved = false
        text = newText
        isDirty = text != savedText
        notice = nil
    }

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
            diskRevision = MarkdownFileIO.Revision(data: Data(initialText.utf8))
            savedText = initialText
            sourceEditorState.reset()
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
            diskRevision = loaded.revision
            savedText = loaded.text
            sourceEditorState.reset()
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
        switch confirmUnsavedChanges(displayName) {
        case .save: return save()
        case .discard: return true
        case .cancel: return false
        }
    }

    private static func presentUnsavedChangesAlert(_ name: String) -> UnsavedChangesChoice {
        let alert = NSAlert()
        alert.messageText = "保存“\(name)”的更改？"
        alert.informativeText = "保存后再继续，或选择不保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        return save(to: url)
    }

    /// Shared by Save and Save As, and directly exercised without a modal panel.
    @discardableResult
    func save(to url: URL) -> Bool {
        do {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if workspace?.documents.contains(where: { $0 !== self && $0.fileURL.map { MarkdownFileIO.refersToSameFile($0, canonical) } == true }) == true {
                errorMessage = "此位置已在另一个标签中打开。请选择其他文件名，避免覆盖另一个文档。"
                return false
            }
            let isCurrentFile = fileURL.map { MarkdownFileIO.refersToSameFile($0, canonical) } == true
            let revision = try MarkdownFileIO.write(text, to: url, encoding: encoding, expectedRevision: isCurrentFile ? diskRevision : nil)
            fileURL = url
            diskRevision = revision
            savedText = text
            errorMessage = nil
            isDirty = false
            notice = "已保存"
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            errorMessage = "无法保存文件：\(error.localizedDescription)"
            return false
        }
    }

    func reloadFromDisk() {
        guard let fileURL, shouldDiscardChanges() else { return }
        _ = load(fileURL)
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
            if save(to: destination) {
                notice = "已保存：\(destination.lastPathComponent)"
                return true
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
        guard exportWindow.attachedSheet == nil else { return }
        isExportingPDF = true
        let optionsPanel = PDFExportOptionsPanel(markdown: text, title: displayName, baseURL: fileURL?.deletingLastPathComponent(), options: .load(from: pdfDefaults))
        exportOptionsPanel = optionsPanel
        optionsPanel.beginSheet(for: exportWindow) { [weak self, weak exportWindow] selection in
            guard let self else { return }
            self.exportOptionsPanel = nil
            guard let selection, let exportWindow else {
                self.isExportingPDF = false
                return
            }
            selection.options.save(to: self.pdfDefaults)
            DispatchQueue.main.async { self.selectPDFDestination(selection: selection, window: exportWindow) }
        }
    }

    private func selectPDFDestination(selection: PDFExportSelection, window: NSWindow) {
        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Markdown 文档") + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        exportSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.exportSavePanel = nil
            guard response == .OK, let destination = panel.url else {
                self.isExportingPDF = false
                return
            }
            self.beginPDFExport(to: destination, options: selection.options, preparedData: selection.data)
        }
    }

    func beginPDFExport(to destination: URL, options: PDFExportOptions, preparedData: Data? = nil) {
        guard exportTask == nil else { return }
        isExportingPDF = true
        exportProgress = 0
        exportedPDFURL = nil
        notice = "正在导出 PDF…"
        errorMessage = nil
        exportTask = PDFExporter.export(markdown: text, title: displayName, baseURL: fileURL?.deletingLastPathComponent(), options: options, to: destination, preparedData: preparedData, progress: { [weak self] in
            self?.exportProgress = $0
        }) { [weak self] result in
            guard let self else { return }
            self.exportTask = nil
            self.isExportingPDF = false
            self.exportProgress = nil
            switch result {
            case .success:
                self.exportedPDFURL = destination
                self.notice = "已导出 PDF：\(destination.lastPathComponent)"
            case .failure(PDFExporter.PDFExportError.cancelled): self.notice = "已取消 PDF 导出"
            case .failure(let error):
                self.notice = "PDF 导出未完成"
                self.errorMessage = "PDF 导出失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelPDFExport() { exportTask?.cancel() }
}

enum EditorDisplayMode: String, CaseIterable {
    case source, split, reading
    var name: String {
        switch self {
        case .source: "仅编辑"
        case .split: "双栏"
        case .reading: "仅渲染"
        }
    }
    var showsSource: Bool { self != .reading }
    var showsPreview: Bool { self != .source }
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
    @AppStorage("editor.displayMode") private var displayMode = EditorDisplayMode.split
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
                Picker("显示模式", selection: $displayMode) {
                    ForEach(EditorDisplayMode.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .help("仅编辑 ⌘1 · 双栏 ⌘2 · 仅渲染（阅读，隐藏源码）⌘3")
                .accessibilityLabel("显示模式")
                .accessibilityIdentifier("editor.displayMode")
                Toggle(isOn: $renderEditing) { Label("渲染编辑", systemImage: "pencil.and.outline") }
                    .toggleStyle(.button)
                    .disabled(displayMode != .split)
                    .help("在双栏模式下直接编辑渲染内容；仅读取模式不会修改文档。")
                Button(action: document.exportPDF) { Label("导出 PDF", systemImage: "doc.richtext") }
                    .disabled(document.isExportingPDF)
            }
            .padding(12)
            .background(.bar)

            HSplitView {
                if displayMode.showsSource {
                    VStack(alignment: .leading, spacing: 0) {
                        panelHeader("Markdown", icon: "curlybraces")
                        SyncedMarkdownEditor(text: Binding(
                            get: { document.text },
                            set: { document.edit($0) }
                        ), state: document.sourceEditorState, onScrollChange: { editorScrollProgress = $0 }, onOpenFiles: { [weak workspace] in workspace?.openDocuments($0) })
                    }
                    .frame(minWidth: 380)
                }

                if displayMode.showsPreview {
                    VStack(alignment: .leading, spacing: 0) {
                        panelHeader(displayMode == .reading ? "阅读 — 仅读取，不修改文件" : (renderEditing ? "渲染编辑 — 直接在右侧修改" : "实时预览"), icon: displayMode == .reading ? "book" : (renderEditing ? "pencil.and.outline" : "doc.text.image"))
                        if renderEditing && displayMode == .split {
                            RenderedMarkdownEditor(
                                markdown: Binding(
                                    get: { document.text },
                                    set: { document.edit($0) }
                                ),
                                baseURL: document.fileURL?.deletingLastPathComponent(),
                                onOpenFiles: { [weak workspace] in workspace?.openDocuments($0) }
                            )
                        } else {
                            MarkdownPreview(
                                markdown: document.text,
                                baseURL: document.fileURL?.deletingLastPathComponent(),
                                scrollProgress: displayMode == .split ? editorScrollProgress : nil,
                                onOpenFiles: { [weak workspace] in workspace?.openDocuments($0) }
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
                if let progress = document.exportProgress {
                    ProgressView(value: progress).frame(width: 100)
                    Text("导出 PDF \(Int(progress * 100))%")
                    Button("取消导出", action: document.cancelPDFExport)
                } else {
                    if document.isDirty { Text("未保存的更改").foregroundStyle(.orange) }
                    if let notice = document.notice {
                        Text(notice).lineLimit(1)
                    } else if !document.isDirty {
                        Text("已保存")
                    }
                    if let url = document.exportedPDFURL {
                        Button("打开 PDF") {
                            if !NSWorkspace.shared.open(url) { document.errorMessage = "无法打开导出的 PDF，请确认文件仍在原位置。" }
                        }
                        .accessibilityLabel("打开刚导出的 PDF")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .onChange(of: displayMode) { _, mode in
            if mode != .split { renderEditing = false }
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

/// Keep native undo/caret/scroll state with the document, not the visible mode.
@MainActor
final class MarkdownSourceEditorState {
    var scrollView: NSScrollView?
    let undoManager = UndoManager()

    func reset() {
        undoManager.removeAllActions()
        (scrollView?.documentView as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView?.contentView.scroll(to: .zero)
    }
}

struct SyncedMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let state: MarkdownSourceEditorState
    let onScrollChange: (Double) -> Void
    let onOpenFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        if let retained = state.scrollView, let textView = retained.documentView as? MarkdownSourceTextView {
            textView.delegate = context.coordinator
            textView.onOpenFiles = onOpenFiles
            context.coordinator.startObserving(retained)
            return retained
        }
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
        state.scrollView = scrollView
        context.coordinator.startObserving(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scrollView.documentView as? MarkdownSourceTextView)?.onOpenFiles = onOpenFiles
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        // A rendered edit/reload has replaced the text. Old native undo ranges
        // would target a different string; invalidate them and clamp selection.
        let selected = textView.selectedRange()
        state.undoManager.removeAllActions()
        textView.string = text
        let length = (text as NSString).length
        let location = min(selected.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
        if let textView = scrollView.documentView as? NSTextView, textView.delegate === coordinator { textView.delegate = nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyncedMarkdownEditor
        private weak var scrollView: NSScrollView?
        private weak var observedUndoManager: UndoManager?

        init(parent: SyncedMarkdownEditor) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        func startObserving(_ scrollView: NSScrollView) {
            stopObserving()
            self.scrollView = scrollView
            observedUndoManager = parent.state.undoManager
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reportScrollPosition),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(publishUndoState), name: name, object: observedUndoManager)
            }
        }

        func stopObserving() {
            // NSTextView also registers its delegate with NotificationCenter.
            // Removing every observer here silently disconnects textDidChange.
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scrollView?.contentView)
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.removeObserver(self, name: name, object: observedUndoManager)
            }
            observedUndoManager = nil
            scrollView = nil
        }

        @objc private func publishUndoState() {
            // Undo actions retained across detachment can update text storage
            // without NSTextView's live-edit notification. Publish the final text.
            if let textView = scrollView?.documentView as? NSTextView { parent.text = textView.string }
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

        func undoManager(for view: NSTextView) -> UndoManager? { parent.state.undoManager }
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
    let scrollProgress: Double?
    let onOpenFiles: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = MarkdownFileDropWebView(frame: .zero, configuration: configuration)
        view.onOpenFiles = onOpenFiles
        view.registerForDraggedTypes(view.registeredDraggedTypes + [.fileURL])
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        context.coordinator.onOpenFiles = onOpenFiles
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        (view as? MarkdownFileDropWebView)?.onOpenFiles = onOpenFiles
        context.coordinator.onOpenFiles = onOpenFiles
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

    final class Coordinator: MarkdownNavigationDelegate {
        var lastHTML = ""
        var lastBasePath: String?
        var scrollProgress: Double?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyScroll(to: webView) }

        func applyScroll(to webView: WKWebView) {
            guard let scrollProgress else { return }
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
        context.coordinator.onOpenFiles = onOpenFiles
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        (view as? MarkdownFileDropWebView)?.onOpenFiles = onOpenFiles
        context.coordinator.parent = self
        context.coordinator.onOpenFiles = onOpenFiles
        let basePath = baseURL?.path
        if context.coordinator.acceptingRenderedEdit && context.coordinator.lastMarkdown == markdown && context.coordinator.lastBasePath == basePath {
            context.coordinator.acceptingRenderedEdit = false
            return
        }
        context.coordinator.acceptingRenderedEdit = false
        guard !context.coordinator.hasLoadedDocument || context.coordinator.lastMarkdown != markdown || context.coordinator.lastBasePath != basePath else { return }
        context.coordinator.hasLoadedDocument = true
        context.coordinator.lastMarkdown = markdown
        context.coordinator.lastBasePath = basePath
        view.loadHTMLString(MarkdownRenderer.documentHTML(markdown: markdown, title: "渲染编辑", editable: true), baseURL: baseURL)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "markdownChanged")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: MarkdownNavigationDelegate, WKScriptMessageHandler {
        var parent: RenderedMarkdownEditor
        var lastMarkdown = ""
        var lastBasePath: String?
        var acceptingRenderedEdit = false
        var hasLoadedDocument = false

        init(parent: RenderedMarkdownEditor) { self.parent = parent; super.init() }

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
    private static let editorScript = resourceText("editor-runtime", "js")
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
        \(editorScript)
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

这是应用启动时的示例文档。左侧可以直接修改，右侧使用 **GFM / CommonMark** 实时预览。

工具栏支持 **仅编辑 / 双栏 / 仅渲染**。按 `⌘3` 隐藏左侧源码、只读排版正文；按 `⌘2` 返回双栏，按 `⌘1` 仅显示源码。显示模式会记住，阅读时不会修改文件。

按 `⌘P` 打开 PDF 设置与真实预览：选择白纸/墨黑与衬线/无衬线四种组合，调整正文和 H1 字号、行距，以及小/中/大打印边距。上、下、左右边距分别可调，也可添加文档名页眉和页码页脚，选择 A4/Letter、横向/纵向。右侧可以翻页、缩放；预览更新完成后点“继续”选择保存位置，导出与预览一致。

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
