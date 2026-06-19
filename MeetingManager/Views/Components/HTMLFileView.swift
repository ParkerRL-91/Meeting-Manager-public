import SwiftUI
import WebKit

/// Sandboxed renderer for a local `.html` file in the Knowledge Base viewer.
///
/// The KB can hold arbitrary HTML the user dropped in, so this view is locked
/// down (PRJ-014 ADR — sandboxed HTML rendering):
///   - JavaScript is disabled (`allowsContentJavaScript = false`).
///   - The data store is `.nonPersistent()` so nothing (cookies, cache) is
///     written to disk.
///   - A `WKNavigationDelegate` cancels ANY navigation or subresource load
///     whose scheme is not `file:`. JS-off alone does not stop `<img src=http…>`,
///     `<iframe>`, or meta-refresh redirects from reaching the network — the
///     delegate is the actual guarantee.
///   - Content loads via `loadFileURL(_:allowingReadAccessTo:)` scoped to the
///     file's own directory (so relative local assets resolve, nothing wider).
struct HTMLFileView: NSViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")   // transparent; inherit app bg
        loadIfNeeded(webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadIfNeeded(webView, context: context)
    }

    private func loadIfNeeded(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != fileURL else { return }
        context.coordinator.loadedURL = fileURL
        context.coordinator.allowedFileURL = fileURL
        let dir = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: dir)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        /// Last HTML string rendered (string-preview variant) — avoids reloading
        /// the web view on every keystroke when the source hasn't actually changed.
        var loadedHTML: String?
        /// The single file: URL we permit the top-level load for. Everything else
        /// (remote, about:, data:, even other local files) is cancelled.
        var allowedFileURL: URL?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            // Allow file: navigations and the local-only `about:blank` document
            // (`loadHTMLString` commits through about:blank — it touches no
            // network). This covers redirects (re-evaluated here) and any frame
            // load; remote subresources are blocked by the resource-load policy.
            let allowed = url.isFileURL || url.absoluteString == "about:blank"
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let isFile = navigationResponse.response.url?.isFileURL ?? false
            decisionHandler(isFile ? .allow : .cancel)
        }
    }
}

/// Live preview of in-progress HTML *source* for the KB editor. Renders the
/// edited string (not a file on disk) under the same sandbox as `HTMLFileView`:
/// JS off, non-persistent store, and the file-only navigation delegate so a
/// pasted `<img src=http…>`/`<iframe>` can't reach the network during editing.
/// `baseURL` is scoped to the file's own directory so relative local assets
/// resolve; cross-origin/remote loads are still cancelled by the delegate.
struct HTMLStringView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeCoordinator() -> HTMLFileView.Coordinator { HTMLFileView.Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadIfNeeded(webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadIfNeeded(webView, context: context)
    }

    private func loadIfNeeded(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
