import Foundation

/// 与 `background.js` 中 `normalizeUrlForDedup` 一致：去掉 hash，便于去重比较。
enum URLHistoryNormalize {
    static func normalizeUrlForDedup(_ url: String) -> String {
        guard !url.isEmpty else { return url }
        guard let u = URL(string: url) else { return url }
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? url
    }
}
