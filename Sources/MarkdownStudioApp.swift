import AppKit
import SwiftUI
import WebKit

@main
struct MarkdownStudioApp: App {
    @StateObject private var document = MarkdownDocument()

    var body: some Scene {
        WindowGroup("Markdown Studio") {
            ContentView()
                .environmentObject(document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Markdown 文件") { document.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("打开…") { document.openDocument() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("另存为…") { document.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("导出为 PDF…") { document.exportPDF() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class MarkdownDocument: ObservableObject {
    @Published var text: String = MarkdownExamples.defaultDocument
    @Published var fileURL: URL?
    @Published var isDirty = false
    @Published var errorMessage: String?
    @Published var notice: String?

    var displayName: String { fileURL?.lastPathComponent ?? "未命名文档" }

    func newDocument() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "note_\(formatter.string(from: Date()))"
        var candidate = downloads.appendingPathComponent(base).appendingPathExtension("md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("md")
            suffix += 1
        }
        text = "# 新文档\n\n"
        fileURL = candidate
        save()
        notice = "已在下载目录创建：\(candidate.lastPathComponent)"
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文件"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                text = try String(contentsOf: url, encoding: .utf8)
                fileURL = url
                isDirty = false
                notice = "已打开：\(url.lastPathComponent)"
            } catch {
                errorMessage = "无法读取文件：\(error.localizedDescription)"
            }
        }
    }

    func save() {
        guard let url = fileURL else { saveAs(); return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            notice = "已保存"
        } catch {
            errorMessage = "无法保存文件：\(error.localizedDescription)"
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "保存 Markdown 文件"
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url.pathExtension.isEmpty ? url.appendingPathExtension("md") : url
            save()
        }
    }

    func exportPDF() {
        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Markdown 文档") + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let optionsView = PDFExportOptionsView()
        panel.accessoryView = optionsView
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let html = MarkdownRenderer.documentHTML(markdown: text, title: displayName, appearance: optionsView.options.appearance)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
        PDFExporter.export(webView: webView, html: html, baseURL: fileURL?.deletingLastPathComponent(), to: destination) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success: self?.notice = "已导出 PDF：\(destination.lastPathComponent)"
                case .failure(let error): self?.errorMessage = "PDF 导出失败：\(error.localizedDescription)"
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

    var appearance: MarkdownAppearance { MarkdownAppearance(fontSize: fontSize, additionalCSS: style.css) }
}

final class PDFExportOptionsView: NSView {
    private let stylePopup = NSPopUpButton(frame: NSRect(x: 105, y: 52, width: 175, height: 26), pullsDown: false)
    private let fontSlider = NSSlider(value: 16, minValue: 11, maxValue: 26, target: nil, action: nil)
    private let fontValue = NSTextField(labelWithString: "16 pt")

    var options: PDFExportOptions {
        PDFExportOptions(style: PDFExportStyle.allCases[stylePopup.indexOfSelectedItem], fontSize: CGFloat(fontSlider.doubleValue))
    }

    override init(frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 292, height: 92)) {
        super.init(frame: frameRect)
        let styleLabel = NSTextField(labelWithString: "导出风格")
        styleLabel.frame = NSRect(x: 0, y: 56, width: 90, height: 20)
        addSubview(styleLabel)
        stylePopup.addItems(withTitles: PDFExportStyle.allCases.map(\.name))
        stylePopup.selectItem(at: 0)
        addSubview(stylePopup)

        let sizeLabel = NSTextField(labelWithString: "正文字号")
        sizeLabel.frame = NSRect(x: 0, y: 18, width: 90, height: 20)
        addSubview(sizeLabel)
        fontSlider.frame = NSRect(x: 105, y: 18, width: 125, height: 20)
        fontSlider.target = self
        fontSlider.action = #selector(fontSizeChanged)
        fontSlider.numberOfTickMarks = 16
        fontSlider.allowsTickMarkValuesOnly = true
        addSubview(fontSlider)
        fontValue.frame = NSRect(x: 240, y: 18, width: 48, height: 20)
        fontValue.alignment = .right
        addSubview(fontValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fontSizeChanged() {
        fontValue.stringValue = "\(Int(fontSlider.doubleValue)) pt"
    }
}

struct ContentView: View {
    @EnvironmentObject private var document: MarkdownDocument
    @State private var showingPreview = true
    @State private var editorScrollProgress = 0.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: document.newDocument) { Label("新建", systemImage: "square.and.pencil") }
                Button(action: document.openDocument) { Label("打开", systemImage: "folder") }
                Button(action: document.save) { Label("保存", systemImage: "square.and.arrow.down") }
                    .disabled(!document.isDirty && document.fileURL != nil)
                Button(action: document.saveAs) { Label("另存为", systemImage: "arrow.down.doc") }
                Spacer()
                Toggle(isOn: $showingPreview) { Label("预览", systemImage: "eye") }
                    .toggleStyle(.button)
                Button(action: document.exportPDF) { Label("导出 PDF", systemImage: "doc.richtext") }
            }
            .padding(12)
            .background(.bar)

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    panelHeader("Markdown", icon: "curlybraces")
                    SyncedMarkdownEditor(text: Binding(
                        get: { document.text },
                        set: { document.text = $0; document.isDirty = true }
                    ), onScrollChange: { editorScrollProgress = $0 })
                }
                .frame(minWidth: 380)

                if showingPreview {
                    VStack(alignment: .leading, spacing: 0) {
                        panelHeader("实时预览", icon: "doc.text.image")
                        MarkdownPreview(
                            markdown: document.text,
                            baseURL: document.fileURL?.deletingLastPathComponent(),
                            scrollProgress: editorScrollProgress
                        )
                    }
                    .frame(minWidth: 380)
                }
            }

            HStack {
                Text(document.fileURL?.path ?? "尚未保存 — 新建文档将保存到下载目录")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(document.isDirty ? "未保存的更改" : "已保存")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .navigationTitle(document.displayName + (document.isDirty ? " •" : ""))
        .alert("Markdown Studio", isPresented: Binding(
            get: { document.errorMessage != nil || document.notice != nil },
            set: { if !$0 { document.errorMessage = nil; document.notice = nil } }
        )) {
            Button("好") { document.errorMessage = nil; document.notice = nil }
        } message: {
            Text(document.errorMessage ?? document.notice ?? "")
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

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = NSTextView()
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

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let scrollProgress: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
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

enum PDFExporter {
    @MainActor
    static func export(webView: WKWebView, html: String, baseURL: URL?, to url: URL, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let observer = NavigationObserver { result in
            switch result {
            case .success:
                let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
                printInfo.paperSize = NSSize(width: 595.28, height: 841.89) // A4, in points
                printInfo.leftMargin = 42
                printInfo.rightMargin = 42
                printInfo.topMargin = 48
                printInfo.bottomMargin = 48
                printInfo.horizontalPagination = .fit
                printInfo.verticalPagination = .automatic
                printInfo.isHorizontallyCentered = true
                printInfo.isVerticallyCentered = false
                printInfo.jobDisposition = .save
                printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

                let operation = webView.printOperation(with: printInfo)
                operation.showsPrintPanel = false
                operation.showsProgressPanel = false
                if operation.run(), FileManager.default.fileExists(atPath: url.path) {
                    completion(.success(()))
                } else {
                    completion(.failure(PDFExportError.couldNotCreateFile))
                }
            case .failure(let error): completion(.failure(error))
            }
        }
        webView.navigationDelegate = observer
        objc_setAssociatedObject(webView, Unmanaged.passUnretained(webView).toOpaque(), observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    enum PDFExportError: LocalizedError {
        case couldNotCreateFile
        var errorDescription: String? { "系统未能完成 PDF 文件写入。" }
    }

    private final class NavigationObserver: NSObject, WKNavigationDelegate {
        let completion: @MainActor (Result<Void, Error>) -> Void
        init(completion: @escaping @MainActor (Result<Void, Error>) -> Void) { self.completion = completion }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { completion(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { completion(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { completion(.failure(error)) }
    }
}

enum MarkdownRenderer {
    private static let markedScript: String = {
        let appResourceBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("MarkdownStudio_MarkdownStudio.bundle")) }
        let resourceBundle = appResourceBundle ?? Bundle.module
        guard let url = resourceBundle.url(forResource: "marked.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return script
    }()

    static func documentHTML(markdown: String, title: String, appearance: MarkdownAppearance = .preview) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escapeHTML(title))</title>
        <style>
        :root { color-scheme: light dark; } body { margin: 0 auto; max-width: 880px; padding: 38px 48px; font: \(Int(appearance.fontSize))px -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif; line-height: 1.72; color: #202124; background: #fff; } h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin-top: 1.55em; } h1 { font-size: 2em; border-bottom: 1px solid #ddd; padding-bottom: .35em; } h2 { font-size: 1.5em; border-bottom: 1px solid #e5e5e5; padding-bottom: .25em; } code { background: #f2f4f7; padding: .15em .35em; border-radius: 4px; font: .9em ui-monospace, SFMono-Regular, Menlo, monospace; } pre { background: #f5f7f9; padding: 16px; border-radius: 8px; overflow:auto; } pre code { padding:0; background:none; } blockquote { border-left: 4px solid #9ba6b2; color: #5b6570; margin: 1em 0; padding: .1em 1em; } table { border-collapse: collapse; width:100%; } th,td { border:1px solid #d9dde3; padding: 7px 10px; text-align:left; } th { background:#f5f7f9; } img { max-width:100%; } a { color:#1967d2; } hr { border:0; border-top:1px solid #ddd; margin: 2em 0; } input[type=checkbox] { margin-right: .45em; } kbd { border: 1px solid #b8bec7; border-bottom-width: 2px; border-radius: 4px; background: #f5f5f5; padding: .05em .35em; font: .85em ui-monospace, monospace; } details { border: 1px solid #d9dde3; border-radius: 7px; padding: .45em .8em; } summary { cursor: pointer; font-weight: 600; } \(appearance.additionalCSS) @media print { body { padding: 20px; max-width: none; } }
        </style></head><body><main id="content"></main><script>\(markedScript)</script>
        <script>
        const source = \(scriptString(markdown));
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

这是应用启动时的示例文档。左侧可以直接修改，右侧使用 **GFM / CommonMark** 实时预览；按 `⇧⌘E` 可以导出为 PDF。

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

## 9. 常见扩展：可写入，但尚未在本应用启用

这些并非 CommonMark/GFM 的全部标准能力，通常需要额外解析器或运行时；当前会作为普通 Markdown 文本处理。

### 脚注（扩展）

这里是一段脚注引用[^1]。

[^1]: 需要脚注扩展。

### 数学公式（KaTeX / MathJax 扩展）

行内：$E = mc^2$。

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

这些都可以继续加入应用；每一项都需要明确的渲染规则或额外离线组件。
"""#
}
