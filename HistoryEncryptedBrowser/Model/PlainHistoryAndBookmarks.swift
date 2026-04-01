import Foundation

// MARK: - 明文历史

struct NormalHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: Int64
    var url: String
    var title: String
    var time: Int64
    var favIconUrl: String
}

@MainActor
final class PlainHistoryStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HistoryEncryptedBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("normal_browsing_history.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func loadAllSortedNewestFirst() -> [NormalHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let rows = (try? decoder.decode([NormalHistoryEntry].self, from: data)) ?? []
        return rows.sorted { $0.time > $1.time }
    }

    func addRecord(url: String, title: String, favIconUrl: String, time: Int64) throws -> Int64 {
        var rows = loadAllSortedNewestFirst()
        let next = (rows.map(\.id).max() ?? 0) + 1
        rows.append(NormalHistoryEntry(id: next, url: url, title: title, time: time, favIconUrl: favIconUrl))
        try saveAll(rows)
        return next
    }

    func deleteRecord(id: Int64) throws {
        var rows = loadAllSortedNewestFirst()
        rows.removeAll { $0.id == id }
        try saveAll(rows)
    }

    func clearAll() throws {
        try saveAll([])
    }

    private func saveAll(_ rows: [NormalHistoryEntry]) throws {
        let data = try encoder.encode(rows)
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
    }
}

// MARK: - 收藏夹

struct BookmarkEntry: Codable, Equatable, Identifiable, Sendable {
    var id: Int64
    var url: String
    var title: String
    var time: Int64
    var favIconUrl: String
}

@MainActor
final class BookmarksStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HistoryEncryptedBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("bookmarks.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func loadAllSortedNewestFirst() -> [BookmarkEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let rows = (try? decoder.decode([BookmarkEntry].self, from: data)) ?? []
        return rows.sorted { $0.time > $1.time }
    }

    func updateTitleIfBookmarked(pageURL: String, title: String) throws {
        let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL)
        var rows = loadAllSortedNewestFirst()
        guard let idx = rows.firstIndex(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return }
        rows[idx].url = pageURL
        rows[idx].title = title
        try saveAll(rows)
    }

    func upsert(url: String, title: String, favIconUrl: String, time: Int64) throws {
        var rows = loadAllSortedNewestFirst()
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url)
        if let idx = rows.firstIndex(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) {
            rows[idx].url = url
            rows[idx].title = title
            rows[idx].time = time
            rows[idx].favIconUrl = favIconUrl
        } else {
            let next = (rows.map(\.id).max() ?? 0) + 1
            rows.append(BookmarkEntry(id: next, url: url, title: title, time: time, favIconUrl: favIconUrl))
        }
        try saveAll(rows)
    }

    func removeMatchingNormalizedURL(_ pageURL: String) throws {
        let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL)
        var rows = loadAllSortedNewestFirst()
        rows.removeAll { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }
        try saveAll(rows)
    }

    func deleteRecord(id: Int64) throws {
        var rows = loadAllSortedNewestFirst()
        rows.removeAll { $0.id == id }
        try saveAll(rows)
    }

    func clearAll() throws {
        try saveAll([])
    }

    private func saveAll(_ rows: [BookmarkEntry]) throws {
        let data = try encoder.encode(rows)
        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL)
    }
}

// MARK: - 普通模式历史记录器

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
