import AppKit
import WebKit

/// Loads a web page off screen and turns it into a paginated PDF (see `PDFPaginator`).
@MainActor final class WebPagePDF: NSObject, WKNavigationDelegate {
    // Exactly one letter-proportioned page tall (900 × 11 / 8.5): a page never renders shorter than
    // the view, so a taller view pushed even a short page onto a nearly blank second one.
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1165))
    private var loaded: CheckedContinuation<Void, Error>?

    func render(_ url: URL) async throws -> (data: Data, title: String) {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
        }
        // Give late layout (fonts, lazy images) a moment to settle.
        try await Task.sleep(for: .seconds(1))
        let tall = try await webView.pdf(configuration: WKPDFConfiguration())
        let title = (webView.title?.isEmpty == false ? webView.title! : url.host()) ?? "Web Page"
        return (try PDFPaginator.paginate(tall), title)
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(throwing: error); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(throwing: error); loaded = nil }
    }
}
