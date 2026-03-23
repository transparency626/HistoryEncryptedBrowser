import Foundation

/// ViewModel → Web 容器：只描述「要网页做什么」，由 Coordinator（持有 WKWebView）实现。
/// 约束为 AnyObject：便于用 `===` 比较实例，解决 detach 时误清新 driver 的竞态。
protocol BrowserNavigationDriver: AnyObject {
    /// 加载指定 URL（主文档导航）。
    func load(url: URL)
    /// 后退一页。
    func goBack()
    /// 前进一页。
    func goForward()
    /// 刷新当前页。
    func reload()
    /// 停止当前加载。
    func stopLoading()
}

/// Web 容器 → ViewModel：网页生命周期与进度回调。
/// @MainActor：与 SwiftUI / 主线程 UI 更新一致。
@MainActor
protocol BrowserWebEventSink: AnyObject {
    /// 开始一次新的导航（白屏/转圈开始）。
    func handleLoadStarted()
    /// 已提交导航（开始有内容渲染的迹象）。
    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot)
    /// 主文档加载完成（对应扩展里 webNavigation.onCompleted 的时机）。
    func handleLoadFinished(snapshot: BrowserNavigationSnapshot)
    /// 导航失败（网络错误、取消等）。
    func handleLoadFailed(snapshot: BrowserNavigationSnapshot)
    /// 加载进度 0...1，用于顶栏进度条。
    func handleEstimatedProgress(_ value: Double)
}
