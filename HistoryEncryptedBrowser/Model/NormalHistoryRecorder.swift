import Foundation

/// 普通浏览明文历史：去重与防抖逻辑对齐 `PrivateHistoryRecorder`，但不加密、不依赖保险库。
@MainActor
final class NormalHistoryRecorder {
    private static let debounceMs: Int64 = 4000

    private let store: PlainHistoryStore

    private var debounceLastAt: [String: Int64] = [:]
    private var lastUrlByTab: [Int: String] = [:]
    private var lastRecordIdByTab: [String: Int64] = [:]

    init(store: PlainHistoryStore) {
        self.store = store
    }

    func clearMemoryState() {
        debounceLastAt.removeAll()
        lastUrlByTab.removeAll()
        lastRecordIdByTab.removeAll()
    }

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

        if let last = debounceLastAt[mapKey], nowMs - last < Self.debounceMs { return }
        debounceLastAt[mapKey] = nowMs

        if lastUrlByTab[tabId] == normalizedUrl { return }

        guard let newId = try? store.addRecord(url: url, title: title, favIconUrl: favIconUrl, time: nowMs) else { return }
        lastUrlByTab[tabId] = normalizedUrl
        lastRecordIdByTab[mapKey] = newId
    }

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
