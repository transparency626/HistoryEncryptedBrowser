import Foundation

/// 地址解析抽象：把用户输入变成可 `load` 的 URL，便于单测替换实现。
protocol AddressResolving: Sendable {
    /// 将用户输入解析为 URL；无法解析时返回 nil（调用方不导航）。
    func resolvedURL(forUserInput input: String) -> URL?
}

/// 默认实现：支持完整 URL、隐式 https 主机名、以及 Bing 搜索。
struct DefaultAddressResolver: AddressResolving {
    /// 搜索引擎主机（全球站 Bing）。
    private static let searchHost = "www.bing.com"
    /// 搜索路径。
    private static let searchPath = "/search"

    /// 协议方法入口，转调静态实现。
    func resolvedURL(forUserInput input: String) -> URL? {
        Self.url(for: input)
    }

    /// 核心解析逻辑。
    static func url(for input: String) -> URL? {
        // 去掉首尾空白。
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空输入不导航。
        if t.isEmpty { return nil }

        // 已带 scheme:// 的字符串，直接交给 URL 解析（ftp、file 等也会过，但加载时 WebKit 可能限制）。
        if t.contains("://"), let u = URL(string: t), u.scheme != nil {
            return u
        }

        // URL(string:) 对 "http://..." 也能解析出 scheme。
        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return u
        }

        // 含空格/换行/制表 → 视为搜索词，不走「像域名」分支。
        if t.contains(" ") || t.contains("\n") || t.contains("\t") {
            return searchURL(query: t)
        }

        // 尝试当作主机名：https://用户输入；若 host 看起来合理则直接访问。
        if let u = URL(string: "https://\(t)"), let host = u.host, isPlausibleHost(host) {
            return u
        }

        // 否则一律当搜索关键词。
        return searchURL(query: t)
    }

    /// 判断 host 是否像「可直连」的目标（域名、IPv4、localhost、IPv6 方括号形式）。
    private static func isPlausibleHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        // 含点：常见域名。
        if h.contains(".") { return true }
        // IPv6 常写成 [2001:...]。
        if h.hasPrefix("[") { return true }
        // 四段数字 0-255 → IPv4。
        let octets = h.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { o in
            guard let n = Int(o), (0 ... 255).contains(n) else { return false }
            return true
        }
    }

    /// 构造 Bing 搜索 URL；用 URLComponents 正确编码查询参数。
    private static func searchURL(query: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = searchHost
        c.path = searchPath
        // q= 查询串；特殊字符由 URLComponents 处理。
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }
}
