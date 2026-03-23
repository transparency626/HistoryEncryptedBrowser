import Foundation

/// 从 Web 容器同步到业务层的导航快照（不含 WebKit 类型，便于测试与分层）。
struct BrowserNavigationSnapshot: Equatable {
    var locationDisplay: String
    var pageTitle: String
    var canGoBack: Bool
    var canGoForward: Bool

    static let blank = BrowserNavigationSnapshot(
        locationDisplay: "about:blank",
        pageTitle: "",
        canGoBack: false,
        canGoForward: false
    )
}
