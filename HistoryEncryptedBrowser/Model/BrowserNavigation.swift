import Foundation // 系统基础库：URL、String、URLComponents 等

// MARK: - 导航快照

/// 从 WKWebView 抽出的只读导航状态，业务层不直接依赖 WebKit 类型。
struct BrowserNavigationSnapshot: Equatable { // 值类型，可比较是否相等
    var locationDisplay: String // 地址栏应显示的 URL 字符串
    var pageTitle: String // 当前文档标题
    var canGoBack: Bool // 后退栈是否非空
    var canGoForward: Bool // 前进栈是否非空

    static let blank = BrowserNavigationSnapshot( // 空白页用的固定快照
        locationDisplay: "about:blank", // WebKit 默认空白页 scheme
        pageTitle: "", // 尚无标题
        canGoBack: false, // 不能后退
        canGoForward: false // 不能前进
    )
}

// MARK: - 地址解析

/// 把用户输入解析成可加载 URL 的协议，Sendable 便于并发语义检查。
protocol AddressResolving: Sendable { // 协议继承 Sendable
    func resolvedURL(forUserInput input: String) -> URL? // 入参：用户输入；出参：URL 或 nil
}

/// 默认实现：完整 URL、隐式 https、否则 Bing 搜索。
struct DefaultAddressResolver: AddressResolving { // 遵循 AddressResolving
    private static let searchHost = "www.bing.com" // 搜索用的主机名
    private static let searchPath = "/search" // 搜索路径，配合查询参数 q

    func resolvedURL(forUserInput input: String) -> URL? { // 协议入口，转调静态方法
        Self.url(for: input) // 调用下面 url(for:) 做实际解析
    }

    static func url(for input: String) -> URL? { // 静态方法，便于单测直接调用
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines) // 去掉首尾空白与换行
        if t.isEmpty { return nil } // 空串无法解析成有效导航目标

        if t.contains("://"), let u = URL(string: t), u.scheme != nil { // 含 scheme 则当完整 URL
            return u // 返回解析结果
        }

        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" { // 无 :// 但仍是 http(s)
            return u // 返回该 URL
        }

        if t.contains(" ") || t.contains("\n") || t.contains("\t") { // 含空白视为搜索词
            return searchURL(query: t) // 走搜索引擎
        }

        if let u = URL(string: "https://\(t)"), let host = u.host, isPlausibleHost(host) { // 尝试当主机名直连
            return u // 返回 https 站点 URL
        }

        return searchURL(query: t) // 其余全部当关键词搜索
    }

    private static func isPlausibleHost(_ host: String) -> Bool { // 判断 host 是否像可直连目标
        let h = host.lowercased() // 统一小写再判断
        if h == "localhost" { return true } // localhost 允许
        if h.contains(".") { return true } // 含点视为域名
        if h.hasPrefix("[") { return true } // IPv6 方括号形式
        let octets = h.split(separator: ".") // 按点分段
        guard octets.count == 4 else { return false } // 不是四段则不是 IPv4 形式
        return octets.allSatisfy { o in // 每一段都要满足
            guard let n = Int(o), (0 ... 255).contains(n) else { return false } // 转整数且在 0…255
            return true // 该段合法
        }
    }

    private static func searchURL(query: String) -> URL? { // 构造 Bing 搜索 URL
        var c = URLComponents() // 可变组件，用于安全拼查询串
        c.scheme = "https" // 固定 HTTPS
        c.host = searchHost // 主机
        c.path = searchPath // 路径 /search
        c.queryItems = [URLQueryItem(name: "q", value: query)] // 查询参数 q=关键词
        return c.url // 组装失败时可能为 nil
    }
}

// MARK: - URL 去重键

/// 去掉 #fragment，用于历史去重与收藏比对。
enum URLHistoryNormalize { // 无实例，只放静态方法
    static func normalizeUrlForDedup(_ url: String) -> String { // 入参：原始 URL 字符串
        guard !url.isEmpty else { return url } // 空串直接返回
        guard let u = URL(string: url) else { return url } // 解析失败则原样返回
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false) // 转成可改 fragment 的组件
        c?.fragment = nil // 去掉 # 及后面部分
        return c?.string ?? url // 拼不回则用原串
    }
}

// MARK: - 浏览模式

/// 普通 / 无痕，影响 DataStore 与是否写应用内历史。
enum BrowsingMode: String, CaseIterable, Identifiable { // Raw 为 String，可枚举全部 case
    case normal // 普通浏览
    case incognito // 无痕浏览

    var id: String { rawValue } // Identifiable：id 用枚举原始字符串

    var shortTitle: String { // 分段控件上显示的文字
        switch self { // 按模式分支
        case .normal: return "普通" // 普通模式文案
        case .incognito: return "无痕" // 无痕模式文案
        }
    }
}
