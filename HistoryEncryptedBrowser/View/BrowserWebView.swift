import SwiftUI
import WebKit

/// View 层：仅负责把 `WKWebView` 嵌入 SwiftUI，并实现 `BrowserNavigationDriver` 把命令转给 WebKit。
struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var viewModel: BrowserViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag

        context.coordinator.observeProgress(webView: webView)
        context.coordinator.bind(webView: webView)

        viewModel.attachNavigationDriver(context.coordinator)
        webView.load(URLRequest(url: URL(string: "about:blank")!))

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, BrowserNavigationDriver {
        private weak var viewModel: BrowserViewModel?
        /// `navigationDelegate` 在 WebKit 内为弱引用，此处用强引用避免在 SwiftUI 生命周期里 `weak` 过早变 nil 导致 `load` 无效。
        private var webView: WKWebView?
        /// 在 `didCommit` 之前 `webView.url` 常仍为上一页；失败时也可能回到 `about:blank`，用于地址栏与快照一致。
        private var lastRequestedURL: URL?
        private var progressObservation: NSKeyValueObservation?

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        func bind(webView: WKWebView) {
            self.webView = webView
        }

        func unbind() {
            progressObservation?.invalidate()
            progressObservation = nil
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            viewModel?.detachNavigationDriver()
            lastRequestedURL = nil
            webView = nil
            viewModel = nil
        }

        func observeProgress(webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    self?.viewModel?.handleEstimatedProgress(wv.estimatedProgress)
                }
            }
        }

        private func snapshot(from wv: WKWebView) -> BrowserNavigationSnapshot {
            let committed = wv.url?.absoluteString
            let loc: String
            if let committed, committed != "about:blank" {
                loc = committed
            } else if let pending = lastRequestedURL?.absoluteString {
                loc = pending
            } else {
                loc = BrowserNavigationSnapshot.blank.locationDisplay
            }
            let title = wv.title ?? ""
            return BrowserNavigationSnapshot(
                locationDisplay: loc,
                pageTitle: title,
                canGoBack: wv.canGoBack,
                canGoForward: wv.canGoForward
            )
        }

        // MARK: - BrowserNavigationDriver

        func load(url: URL) {
            lastRequestedURL = url
            webView?.load(URLRequest(url: url))
        }

        func goBack() { webView?.goBack() }
        func goForward() { webView?.goForward() }
        func reload() { webView?.reload() }
        func stopLoading() { webView?.stopLoading() }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel?.handleLoadStarted()
                viewModel?.handleLoadCommitted(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                viewModel?.handleLoadCommitted(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.lastRequestedURL = nil
                viewModel?.handleLoadFinished(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                viewModel?.handleLoadFailed(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                viewModel?.handleLoadFailed(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
