import Foundation

/// 普通浏览：持久化站点数据 + **明文**本地历史。无痕：非持久化数据 + **加密**保险库历史（需设保险库密码）。
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
