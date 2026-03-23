import Foundation

/// 从 WKWebView 抽出来的一份「只读状态快照」，避免 ViewModel 直接依赖 WebKit 类型。
/// 好处：单元测试可伪造快照；架构上 Web 层与业务层解耦。
struct BrowserNavigationSnapshot: Equatable {
    /// 地址栏应显示的 URL 字符串（可能是当前提交 URL，不一定是 webView.url）。
    var locationDisplay: String
    /// 页面标题（document.title）。
    var pageTitle: String
    /// 是否可以后退。
    var canGoBack: Bool
    /// 是否可以前进。
    var canGoForward: Bool

    /// 空白页占位快照：初始状态或重置导航时用。
    static let blank = BrowserNavigationSnapshot(
        locationDisplay: "about:blank",
        pageTitle: "",
        canGoBack: false,
        canGoForward: false
    )
}
