import Foundation

// MARK: - 导航快照

/// 从 WKWebView 抽出来的一份「只读状态快照」，避免 ViewModel 直接依赖 WebKit 类型。
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

// MARK: - 地址解析

protocol AddressResolving: Sendable {
    func resolvedURL(forUserInput input: String) -> URL?
}

struct DefaultAddressResolver: AddressResolving {
    private static let searchHost = "www.bing.com"
    private static let searchPath = "/search"

    func resolvedURL(forUserInput input: String) -> URL? {
        Self.url(for: input)
    }

    static func url(for input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }

        if t.contains("://"), let u = URL(string: t), u.scheme != nil {
            return u
        }

        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return u
        }

        if t.contains(" ") || t.contains("\n") || t.contains("\t") {
            return searchURL(query: t)
        }

        if let u = URL(string: "https://\(t)"), let host = u.host, isPlausibleHost(host) {
            return u
        }

        return searchURL(query: t)
    }

    private static func isPlausibleHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        if h.contains(".") { return true }
        if h.hasPrefix("[") { return true }
        let octets = h.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { o in
            guard let n = Int(o), (0 ... 255).contains(n) else { return false }
            return true
        }
    }

    private static func searchURL(query: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = searchHost
        c.path = searchPath
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }
}

// MARK: - URL 去重键

enum URLHistoryNormalize {
    static func normalizeUrlForDedup(_ url: String) -> String {
        guard !url.isEmpty else { return url }
        guard let u = URL(string: url) else { return url }
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? url
    }
}

// MARK: - 浏览模式

enum BrowsingMode: String, CaseIterable, Identifiable {
    case normal
    case incognito

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .normal: return "普通"
        case .incognito: return "无痕"
        }
    }
}
