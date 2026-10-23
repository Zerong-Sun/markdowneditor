import AppKit
import WebKit

enum MarkdownLinkDestination: Equatable {
    case anchor, markdown(URL), external(URL), blocked

    static func resolve(_ url: URL, currentURL: URL?) -> Self {
        if url.fragment != nil, let currentURL,
           url.removingFragment == currentURL.removingFragment { return .anchor }
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            return MarkdownFileIO.markdownExtensions.contains(ext) || ext == "txt" ? .markdown(url.removingFragment) : .blocked
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return .external(url)
        default: return .blocked
        }
    }
}

private extension URL {
    var removingFragment: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return self }
        components.fragment = nil
        return components.url ?? self
    }
}

/// Links must never replace the document with a web page or launch arbitrary
/// application URL schemes. Shared by reading, preview and rendered editing.
@MainActor
class MarkdownNavigationDelegate: NSObject, WKNavigationDelegate {
    var onOpenFiles: ([URL]) -> Void = { _ in }
    var openExternal: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else { decisionHandler(.allow); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        switch MarkdownLinkDestination.resolve(url, currentURL: webView.url) {
        case .anchor: decisionHandler(.allow)
        case .markdown(let file):
            decisionHandler(.cancel)
            onOpenFiles([file])
        case .external(let destination):
            decisionHandler(.cancel)
            openExternal(destination)
        case .blocked: decisionHandler(.cancel)
        }
    }
}
