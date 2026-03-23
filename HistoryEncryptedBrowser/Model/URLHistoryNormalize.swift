import Foundation

/// URL 规范化工具：与 Chrome 扩展里 `normalizeUrlForDedup` 对齐，用于历史去重键。
enum URLHistoryNormalize {
    /// 去掉 fragment（# 及后面部分），同一页面不同锚点视为同一条去重键。
    /// - Parameter url: 原始 URL 字符串。
    /// - Returns: 去掉 hash 后的字符串；解析失败则原样返回。
    static func normalizeUrlForDedup(_ url: String) -> String {
        // 空串无需处理。
        guard !url.isEmpty else { return url }
        // 尝试解析为 URL。
        guard let u = URL(string: url) else { return url }
        // 用 URLComponents 可安全改写 fragment。
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        // 置空 fragment，即去掉 #xxx。
        c?.fragment = nil
        // 能组回字符串则用组回的，否则退回原始。
        return c?.string ?? url
    }
}
