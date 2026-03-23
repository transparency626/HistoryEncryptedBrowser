import Foundation

/// 普通模式历史记录器：防抖、同 URL 去重、标题更新时删旧加新；逻辑对齐无痕加密侧，但不加密。
@MainActor
final class NormalHistoryRecorder {
    /// 与扩展一致：短时间内同一 URL 重复完成导航则忽略（毫秒）。
    private static let debounceMs: Int64 = 4000

    private let store: PlainHistoryStore

    /// 去防抖：mapKey → 上次写入时间戳。
    private var debounceLastAt: [String: Int64] = [:]
    /// 每个 tab 最近一次已记录的标准化 URL（避免同页重复条）。
    private var lastUrlByTab: [Int: String] = [:]
    /// mapKey → 当前页面对应的历史行 id（标题更新时要删掉这条再插入新的）。
    private var lastRecordIdByTab: [String: Int64] = [:]

    init(store: PlainHistoryStore) {
        self.store = store
    }

    /// 切换浏览模式或清空历史时重置内存去重状态（磁盘数据不变）。
    func clearMemoryState() {
        debounceLastAt.removeAll()
        lastUrlByTab.removeAll()
        lastRecordIdByTab.removeAll()
    }

    /// 主框架加载完成时调用（与 WKNavigationDelegate.didFinish 对齐）。
    func onWebNavigationCompleted(
        tabId: Int = 0,
        url: String,
        title: String,
        favIconUrl: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        guard !url.isEmpty else { return }

        let normalizedUrl = URLHistoryNormalize.normalizeUrlForDedup(url)
        let mapKey = "\(tabId)::\(normalizedUrl)"

        // 4 秒内同一 mapKey 只允许记一条。
        if let last = debounceLastAt[mapKey], nowMs - last < Self.debounceMs { return }
        debounceLastAt[mapKey] = nowMs

        // 同一 tab 连续同一 URL 视为重复导航，不重复插入。
        if lastUrlByTab[tabId] == normalizedUrl { return }

        guard let newId = try? store.addRecord(url: url, title: title, favIconUrl: favIconUrl, time: nowMs) else { return }
        lastUrlByTab[tabId] = normalizedUrl
        lastRecordIdByTab[mapKey] = newId
    }

    /// 标题 KVO 更新时：删掉该 URL 下旧记录，再插入带新标题的记录。
    func onTitleUpdated(
        tabId: Int = 0,
        url: String,
        title: String,
        favIconUrl: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let normalizedUrl = URLHistoryNormalize.normalizeUrlForDedup(url)
        let mapKey = "\(tabId)::\(normalizedUrl)"
        guard let recordId = lastRecordIdByTab[mapKey] else { return }

        lastRecordIdByTab.removeValue(forKey: mapKey)
        try? store.deleteRecord(id: recordId)

        guard let newId = try? store.addRecord(url: url, title: title, favIconUrl: favIconUrl, time: nowMs) else { return }
        lastRecordIdByTab[mapKey] = newId
    }
}
