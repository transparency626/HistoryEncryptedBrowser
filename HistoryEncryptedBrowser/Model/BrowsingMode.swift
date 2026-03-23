// Foundation：此处未直接用，保留 import 与工程风格一致（若将来扩展 Codable 等可用）。
import Foundation

/// 浏览模式枚举：决定 WebKit 是否持久化站点数据，以及历史写入哪条管道。
/// - 普通：持久化 Cookie/缓存等 + 明文 JSON 历史。
/// - 无痕：非持久化会话 + 仅在有保险库公钥时写入加密记录。
enum BrowsingMode: String, CaseIterable, Identifiable {
    /// 普通浏览模式。
    case normal
    /// 无痕浏览模式（对应「私密」会话）。
    case incognito

    /// Identifiable：供 SwiftUI `ForEach` 等用稳定 id。
    var id: String { rawValue }

    /// 分段控件上显示的短标题。
    var shortTitle: String {
        switch self {
        case .normal: return "普通"
        case .incognito: return "无痕"
        }
    }
}
