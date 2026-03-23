import Foundation

/// ViewModel 通过该端口驱动网页容器；由 View 层的 `WKWebView` 协调器实现，避免 ViewModel 依赖 WebKit。
protocol BrowserNavigationDriver: AnyObject {
    func load(url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
}

/// 网页容器向 ViewModel 回传状态（单向数据流：Web → VM → View）。
@MainActor
protocol BrowserWebEventSink: AnyObject {
    func handleLoadStarted()
    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot)
    func handleLoadFinished(snapshot: BrowserNavigationSnapshot)
    func handleLoadFailed(snapshot: BrowserNavigationSnapshot)
    func handleEstimatedProgress(_ value: Double)
}
