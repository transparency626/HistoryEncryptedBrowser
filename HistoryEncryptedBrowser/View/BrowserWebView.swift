// SwiftUI：UIViewRepresentable、Context 等。
import SwiftUI
// WebKit：WKWebView、WKNavigationDelegate、配置项。
import WebKit

/// 把 UIKit 的 WKWebView「桥」进 SwiftUI；内部用 Coordinator 接 delegate 和 ViewModel。
struct BrowserWebView: UIViewRepresentable {
    // ObservedObject：父视图 BrowserView 的 viewModel 变化时，本结构体也会刷新（但 makeUIView 不一定会再调）。
    @ObservedObject var viewModel: BrowserViewModel

    /// SwiftUI 在适当时机调用，生成与当前 Representable 绑定的协调器对象。
    func makeCoordinator() -> Coordinator {
        // 把 ViewModel 传进去；Coordinator 里用 weak 指回 VM，避免循环引用。
        Coordinator(viewModel: viewModel)
    }

    /// 首次需要 UIView 时调用：创建并配置 WKWebView，挂 delegate、KVO，注册导航驱动。
    func makeUIView(context: Context) -> WKWebView {
        // 配置对象：决定 JavaScript、DataStore 等全局行为。
        let config = WKWebViewConfiguration()
        // 按当前模式选持久化或无痕存储；必须与外层 .id(browsingMode) 配合，否则只改这里无效。
        switch viewModel.browsingMode {
        case .normal:
            // 默认 DataStore：Cookie 等会落盘。
            config.websiteDataStore = .default()
        case .incognito:
            // 非持久：进程内有效，关掉 App 站点数据不留（与桌面无痕类似）。
            config.websiteDataStore = .nonPersistent()
        }
        // 允许页面跑 JS（现代网页几乎都需要）。
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // frame: .zero 表示交给 Auto Layout / SwiftUI 布局决定最终大小。
        let webView = WKWebView(frame: .zero, configuration: config)
        // navigationDelegate：加载进度、完成、失败。
        webView.navigationDelegate = context.coordinator
        // uiDelegate：如 window.open、alert 等（这里只处理一种）。
        webView.uiDelegate = context.coordinator
        // 系统边缘滑动手势前进后退。
        webView.allowsBackForwardNavigationGestures = true
        // 拖动滚动时收起键盘，阅读长页更舒服。
        webView.scrollView.keyboardDismissMode = .onDrag

        // 注册 KVO：进度与标题。
        context.coordinator.observeProgress(webView: webView)
        context.coordinator.observeTitle(webView: webView)
        // 让 Coordinator 强引用住 webView，delegate 才不会悬空。
        context.coordinator.bind(webView: webView)

        // ViewModel 需要知道谁来执行 load/goBack，这里把 Coordinator 登记上去。
        viewModel.attachNavigationDriver(context.coordinator)
        // 先加载空白页，避免 nil URL；用户再点「前往」加载真实地址。
        webView.load(URLRequest(url: URL(string: "about:blank")!))

        return webView
    }

    /// 当 SwiftUI 状态更新且未重建 UIView 时调用；本工程靠 .id 重建 WebView，这里留空即可。
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Representable 从视图树移除时调用：必须解绑，否则会野指针或重复回调。
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    /// NSObject：OC runtime 需要，才能当 WKNavigationDelegate。
    /// 同时实现自定义协议 BrowserNavigationDriver，供 ViewModel 调用。
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, BrowserNavigationDriver {
        // weak：VM 强引用 Coordinator（通过 navigationDriver），这里必须 weak 避免环。
        private weak var viewModel: BrowserViewModel?
        // 强引用 WebView；系统对 navigationDelegate 是 weak，否则 Coordinator 可能被释放。
        private var webView: WKWebView?
        // 用户点「前往」后、WebView.url 还没提交前，用这里补显示 URL。
        private var lastRequestedURL: URL?
        // KVO 句柄，unbind 时要 invalidate。
        private var progressObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?

        init(viewModel: BrowserViewModel) {
            self.viewModel = viewModel
        }

        /// 保存 webView 实例，供 load/goBack 等使用。
        func bind(webView: WKWebView) {
            self.webView = webView
        }

        /// 生命周期结束：停观察、清 delegate、从 VM 注销自己。
        func unbind() {
            progressObservation?.invalidate()
            progressObservation = nil
            titleObservation?.invalidate()
            titleObservation = nil
            // 去掉 delegate，WebView 之后不会再回调到本 Coordinator。
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            // 带 self 身份 detach，避免误删新 WebView 的 driver。
            viewModel?.detachNavigationDriver(self)
            lastRequestedURL = nil
            webView = nil
            viewModel = nil
        }

        /// 观察 estimatedProgress，转发给 ViewModel 更新顶栏进度条。
        func observeProgress(webView: WKWebView) {
            // \.estimatedProgress：key path；options .new 表示只关心新值。
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                // KVO 回调线程不保证是主线程，UI 更新统一切主线程。
                Task { @MainActor in
                    self?.viewModel?.handleEstimatedProgress(wv.estimatedProgress)
                }
            }
        }

        /// 标题变化时通知 VM，由 VM 决定更新明文历史还是加密历史。
        func observeTitle(webView: WKWebView) {
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    // 没有 URL 无法和记录关联，直接忽略。
                    guard let urlStr = wv.url?.absoluteString else { return }
                    self?.viewModel?.browserHistoryOnTitleChange(url: urlStr, title: wv.title ?? "")
                }
            }
        }

        /// 从 WebView 当前状态拼一份 BrowserNavigationSnapshot，给 VM 刷新 UI。
        private func snapshot(from wv: WKWebView) -> BrowserNavigationSnapshot {
            // 已提交后的 URL 字符串（可能仍为 nil）。
            let committed = wv.url?.absoluteString
            let loc: String
            if let committed, committed != "about:blank" {
                // 有真实 committed URL 就用它。
                loc = committed
            } else if let pending = lastRequestedURL?.absoluteString {
                // 还在转或刚点前往：用最近一次请求的 URL 显示在地址栏区域。
                loc = pending
            } else {
                // 都没有就退回空白占位。
                loc = BrowserNavigationSnapshot.blank.locationDisplay
            }
            // title 可能为空（加载早期）。
            let title = wv.title ?? ""
            return BrowserNavigationSnapshot(
                locationDisplay: loc,
                pageTitle: title,
                canGoBack: wv.canGoBack,
                canGoForward: wv.canGoForward
            )
        }

        // MARK: - BrowserNavigationDriver（ViewModel 调这些）

        func load(url: URL) {
            // 记下请求，snapshot 在 didCommit 前仍能显示对用户有意义的 URL。
            lastRequestedURL = url
            webView?.load(URLRequest(url: url))
        }

        func goBack() { webView?.goBack() }
        func goForward() { webView?.goForward() }
        func reload() { webView?.reload() }
        func stopLoading() { webView?.stopLoading() }

        /// 与 KVO 的 `title` 互补：SPA/晚解析时 `document.title` 或 og 元数据可能更可靠。
        func fetchDocumentTitle(completion: @escaping (String?) -> Void) {
            guard let wv = webView else {
                completion(nil)
                return
            }
            wv.evaluateJavaScript(Self.bookmarkTitleJavaScript) { result, _ in
                DispatchQueue.main.async {
                    guard let s = result as? String else {
                        completion(nil)
                        return
                    }
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(t.isEmpty ? nil : t)
                }
            }
        }

        /// 取标题：`document.title` 若像 URL 则忽略，优先 `og:title` / `twitter:title`（不少站 KVO 阶段 title 仍是地址栏串）。
        private static let bookmarkTitleJavaScript = """
        (function(){
          function pick(x){ if(x==null||x==='') return ''; return String(x).trim(); }
          function looksLikeURL(s){ return /^https?:\\/\\//i.test(s); }
          var og = document.querySelector('meta[property="og:title"]');
          var ogt = pick(og && og.getAttribute('content'));
          if (ogt && !looksLikeURL(ogt)) return ogt;
          var tw = document.querySelector('meta[name="twitter:title"]');
          var twt = pick(tw && tw.getAttribute('content'));
          if (twt && !looksLikeURL(twt)) return twt;
          var dt = pick(document.title);
          if (dt && !looksLikeURL(dt)) return dt;
          if (ogt) return ogt;
          if (twt) return twt;
          return dt || '';
        })()
        """

        // MARK: - WKNavigationDelegate（WebKit 调这些）

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                // 标记开始加载（VM 里 isLoading = true）。
                viewModel?.handleLoadStarted()
                // 尽早更新一版快照（可能仍显示 lastRequestedURL）。
                viewModel?.handleLoadCommitted(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            Task { @MainActor in
                // 已收到部分响应，URL 一般已可用。
                viewModel?.handleLoadCommitted(snapshot: snapshot(from: webView))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                // 主文档加载完成，pending URL 不再需要。
                self.lastRequestedURL = nil
                // VM 内会写历史（明文或加密）。
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
                // 与 didFail 类似，发生在更早阶段（如 DNS 失败）。
                viewModel?.handleLoadFailed(snapshot: snapshot(from: webView))
            }
        }

        /// 新窗口打开且没有 targetFrame：在当前 WebView 里继续 load，避免「点了没反应」。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            // 返回 nil 表示我们不创建第二个 WebView。
            return nil
        }
    }
}
