import AppKit
import SwiftUI
import WebKit

/// Regression tests against production WebKit and NSTextView implementations.
@main
enum EditorQualityIntegrationTests {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("Editor quality FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures.append(name); print("FAIL:", name) }
        }
        func wait(line: Int = #line, _ completed: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !completed(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            guard completed() else { throw NSError(domain: "EditorQualityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Asynchronous WebKit/view deadline at line \(line)"]) }
        }
        func js(_ script: String, in view: WKWebView) throws -> Any? {
            var done = false
            var result: Any?
            var failure: Error?
            view.evaluateJavaScript(script) { value, error in result = value; failure = error; done = true }
            try wait { done }
            if let failure { throw failure }
            return result
        }
        func literal(_ value: String) -> String { String(data: try! JSONEncoder().encode(value), encoding: .utf8)! }
        func load(_ markdown: String, editable: Bool = true) throws -> WKWebView {
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.loadHTMLString(MarkdownRenderer.documentHTML(markdown: markdown, title: "Quality test", editable: editable), baseURL: URL(fileURLWithPath: "Tests/Fixtures", isDirectory: true).standardizedFileURL)
            try wait { view.estimatedProgress == 1 && !view.isLoading }
            return view
        }

        let corpus = #"""
        # Preserve source

        Literal \*stars\* and \[brackets\]. A [reference][link].

        7. start seven
           1. nested one
           2. nested two

        ````markdown
        ```swift
        print("nested fence")
        ```
        ````

        <details><summary>Keep HTML</summary><p>hidden body</p></details>

        | left | right |
        | :--- | ---: |
        | a | b |

        [link]: https://example.com "Keep title"
        """# + "\n"
        let editor = try load(corpus)
        check(try js("renderedToMarkdown(content) === \(literal(corpus))", in: editor) as? Bool == true, "Untouched rendered document round-trips byte-for-byte")
        _ = try js("content.querySelector('p').append(document.createTextNode(' *literal*'));", in: editor)
        let edited = try js("renderedToMarkdown(content)", in: editor) as! String
        check(edited.contains("7. start seven\n   1. nested one\n   2. nested two"), "Editing a paragraph preserves unrelated list numbering/indentation")
        check(edited.contains("<details><summary>Keep HTML</summary><p>hidden body</p></details>"), "Editing a paragraph preserves unrelated raw HTML")
        check(edited.contains("[link]: https://example.com \"Keep title\""), "Editing a paragraph preserves reference definitions and titles")
        check(edited.contains("````markdown\n```swift"), "Editing a paragraph preserves nested code fences")
        let reparsed = try load(edited, editable: false)
        check(try js("content.querySelector('p').textContent.includes('*literal*') && !content.querySelector('p em')", in: reparsed) as? Bool == true, "Typed Markdown punctuation stays literal, not accidental formatting")

        let malicious = try load("<a href=\"java&#x09;script:alert(1)\">unsafe</a>\n\n<video src=\"https://example.com/a.mp4\" autoplay></video>", editable: false)
        check(try js("!content.querySelector('a').hasAttribute('href')", in: malicious) as? Bool == true, "Sanitizer rejects control-character-obfuscated JavaScript URLs")
        check(try js("!content.querySelector('video')", in: malicious) as? Bool == true, "Untrusted media cannot autoplay or execute handlers")
        for sample in ["", "first\r\n\r\nsecond\r\n", "\tindented code\n\nparagraph\n", "[ref]: https://example.com\n\n[link][ref]\n", "- [x] task\n- [ ] todo\n", "$x_i+x_j$ and $\\frac{a_b}{c_d}$\n"] {
            let view = try load(sample)
            check(try js("renderedToMarkdown(content) === \(literal(sample))", in: view) as? Bool == true, "Round-trip exact source: \(sample.prefix(24).debugDescription)")
        }
        let formulas = try load("$x_i+x_j$ and $\\frac{a_b}{c_d}$\n\n`$not_math$`\n\n\\$5 and \\$10", editable: false)
        check(try js("content.querySelectorAll('.katex').length === 2 && !content.querySelector('.katex-error')", in: formulas) as? Bool == true, "Math containing underscores renders before Markdown emphasis")
        check(try js("content.querySelector('code').textContent === '$not_math$'", in: formulas) as? Bool == true, "Code never renders as math")

        let code = try load("````markdown\n```swift\nprint(1)\n```\n````\n")
        _ = try js("content.querySelector('code').textContent += 'added\\n';", in: code)
        let codeResult = try js("renderedToMarkdown(content)", in: code) as! String
        let codePreview = try load(codeResult, editable: false)
        check(try js("content.querySelectorAll('pre').length === 1 && content.querySelector('code').textContent.includes('```swift') && content.querySelector('code').textContent.includes('added')", in: codePreview) as? Bool == true, "Editing nested code chooses a sufficiently long fence")

        let navigation = MarkdownPreview.Coordinator()
        var externalLinks: [URL] = [], localLinks: [URL] = []
        navigation.openExternal = { externalLinks.append($0) }
        navigation.onOpenFiles = { localLinks.append(contentsOf: $0) }
        let links = try load("[external](https://example.com/help)\n\n[local](second.MD)", editable: false)
        links.navigationDelegate = navigation
        _ = try js("content.querySelectorAll('a')[0].click();", in: links)
        try wait { externalLinks.count == 1 }
        check(externalLinks[0].host == "example.com", "Real WebKit navigation delegate routes external links")
        _ = try js("content.querySelectorAll('a')[1].click();", in: links)
        try wait { localLinks.count == 1 }
        check(localLinks[0].lastPathComponent == "second.MD", "Real WebKit navigation delegate routes local Markdown links")
        check(try js("content.querySelectorAll('a').length === 2", in: links) as? Bool == true, "Clicking links does not replace the document preview")

        let defaultsName = "MarkdownStudio-quality-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(EditorDisplayMode.source.rawValue, forKey: "editor.displayMode")
        let workspace = MarkdownWorkspace()
        let document = workspace.selectedDocument
        let original = document.text
        let host = NSHostingView(rootView: ContentView().environmentObject(workspace).environmentObject(document).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func sourceView() -> MarkdownSourceTextView? { descendants(host).compactMap { $0 as? MarkdownSourceTextView }.first }
        try wait { sourceView() != nil }
        let source = sourceView()!
        window.makeFirstResponder(source)
        source.setSelectedRange(NSRange(location: 3, length: 0))
        source.insertText("TEST-EDIT", replacementRange: source.selectedRange())
        source.breakUndoCoalescing()
        try wait { document.text != original }
        let selection = source.selectedRange()
        check(source.undoManager?.canUndo == true, "Native typing registers undo")
        defaults.set(EditorDisplayMode.reading.rawValue, forKey: "editor.displayMode")
        try wait { sourceView() == nil }
        defaults.set(EditorDisplayMode.source.rawValue, forKey: "editor.displayMode")
        try wait { sourceView() != nil }
        let restored = sourceView()!
        check(restored === source, "Switching modes retains the document's native editor")
        check(restored.selectedRange() == selection, "Switching modes retains caret/selection")
        check(restored.undoManager?.canUndo == true, "Switching modes retains undo history")
        check(restored.undoManager === document.sourceEditorState.undoManager, "Each document uses its own undo manager")
        restored.undoManager?.undo()
        try wait { document.text == original }
        check(document.text == original && !document.isDirty, "Undo back to saved content clears dirty state")
        restored.undoManager?.redo()
        try wait { document.text != original }
        check(document.isDirty && document.text == restored.string, "Redo after mode switch updates model and unsaved state")
        restored.undoManager?.undo()
        try wait { document.text == original }

        // Test the real tab host, whose document identity controls representable
        // lifetimes. Undo in one file must not edit the other file.
        let tabWorkspace = MarkdownWorkspace()
        let firstFile = URL(fileURLWithPath: "Tests/Fixtures/中文 打开测试.md").standardizedFileURL
        let secondFile = URL(fileURLWithPath: "Tests/Fixtures/second.MD").standardizedFileURL
        tabWorkspace.openDocuments([firstFile, secondFile])
        let firstDocument = tabWorkspace.documents[0]
        tabWorkspace.selectedID = firstDocument.id
        let tabHost = NSHostingView(rootView: MarkdownWorkspaceView().environmentObject(tabWorkspace).defaultAppStorage(defaults))
        window.contentView = tabHost
        func tabSource() -> MarkdownSourceTextView? { descendants(tabHost).compactMap { $0 as? MarkdownSourceTextView }.first }
        try wait { tabSource() != nil }
        let firstSource = tabSource()!
        window.makeFirstResponder(firstSource)
        firstSource.insertText("TAB-ONE", replacementRange: NSRange(location: 0, length: 0))
        firstSource.breakUndoCoalescing()
        try wait { firstDocument.isDirty }
        let tabSelection = firstSource.selectedRange()
        tabWorkspace.selectedID = tabWorkspace.documents[1].id
        try wait { tabSource() !== firstSource && tabSource() != nil }
        let secondSource = tabSource()!
        check(secondSource.undoManager?.canUndo == false, "Second tab has no first tab's undo actions")
        check(secondSource.undoManager !== firstSource.undoManager, "Tabs do not share native undo history")
        tabWorkspace.selectedID = firstDocument.id
        try wait { tabSource() === firstSource }
        check(firstSource.selectedRange() == tabSelection, "Tab switch preserves caret position")
        firstSource.undoManager?.undo()
        try wait { !firstDocument.isDirty }
        check(!tabWorkspace.documents[1].isDirty && secondSource.string == tabWorkspace.documents[1].text, "Undo in first tab leaves second tab untouched")

        let richDocument = MarkdownDocument()
        richDocument.text = ""
        let richHost = NSHostingView(rootView: RichEditorHarness(document: richDocument))
        window.contentView = richHost
        var richView: WKWebView?
        try wait {
            richView = descendants(richHost).compactMap { $0 as? WKWebView }.first
            return richView?.estimatedProgress == 1 && richView?.isLoading == false
        }
        let rich = richView!
        check(try js("content.isContentEditable", in: rich) as? Bool == true, "Empty file still initializes an editable rendered document")
        _ = try js("content.dispatchEvent(new CompositionEvent('compositionstart')); content.textContent = '中文 *literal*'; content.dispatchEvent(new InputEvent('input'));", in: rich)
        check(richDocument.text.isEmpty, "IME composition does not publish intermediate uncommitted text")
        _ = try js("content.dispatchEvent(new CompositionEvent('compositionend'));", in: rich)
        try wait { richDocument.text.contains("中文") }
        check(richDocument.isDirty && richDocument.text.contains("\\*literal\\*"), "IME commit flows through real WebKit message bridge to Markdown model")
        richDocument.edit("# External source update\n\n$x_i+x_j$\n")
        try wait { !rich.isLoading }
        var synced = false
        try wait {
            rich.evaluateJavaScript("content.querySelector('h1')?.textContent === 'External source update'") { value, _ in synced = value as? Bool == true }
            return synced
        }
        check(synced, "External source changes are not swallowed by rendered-edit echo suppression")

        if let output = ProcessInfo.processInfo.environment["MARKDOWNSTUDIO_PDF_TEST_OUTPUT"] {
            let target = URL(fileURLWithPath: output, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.appendingPathComponent(".markdownstudio-test-output").path) {
                var snapshotDone = false
                rich.takeSnapshot(with: nil) { image, _ in
                    if let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: target.appendingPathComponent("rich-editor.png"))
                    }
                    snapshotDone = true
                }
                try wait { snapshotDone }
            }
        }

        if !failures.isEmpty { throw NSError(domain: "EditorQualityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
        print("Editor quality integration tests passed: \(checks) checks.")
    }
}

private struct RichEditorHarness: View {
    @ObservedObject var document: MarkdownDocument
    var body: some View {
        RenderedMarkdownEditor(markdown: Binding(get: { document.text }, set: { document.edit($0) }), baseURL: nil, onOpenFiles: { _ in })
    }
}
