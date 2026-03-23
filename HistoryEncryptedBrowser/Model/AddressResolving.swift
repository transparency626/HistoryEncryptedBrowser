import Foundation

/// 将用户输入解析为可加载的 URL（Model 层：无 UI / 无 WebKit）。
protocol AddressResolving: Sendable {
    func resolvedURL(forUserInput input: String) -> URL?
}

struct DefaultAddressResolver: AddressResolving {
    /// Microsoft Edge 默认搜索引擎为 Bing（全球站）。
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
        // 使用 URLComponents + queryItems，避免 urlQueryAllowed 误放行 &、# 等破坏查询串，以及 String(format:) 边缘问题。
        var c = URLComponents()
        c.scheme = "https"
        c.host = searchHost
        c.path = searchPath
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }
}
