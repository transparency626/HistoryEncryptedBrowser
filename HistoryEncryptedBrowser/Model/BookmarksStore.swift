import Foundation

/// 收藏夹单条：明文 JSON 存储，字段与历史类似，独立文件。
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

    /// 按添加时间倒序（最近添加在前）。
    func loadAllSortedNewestFirst() -> [BookmarkEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let rows = (try? decoder.decode([BookmarkEntry].self, from: data)) ?? []
        return rows.sorted { $0.time > $1.time }
    }

    /// 若该 URL（规范化）已在收藏夹：只更新 `title` 与当前 URL 字符串，**不改** `time`（与历史里「标题晚到再改一条」类似）。
    func updateTitleIfBookmarked(pageURL: String, title: String) throws {
        let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL)
        var rows = loadAllSortedNewestFirst()
        guard let idx = rows.firstIndex(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return }
        rows[idx].url = pageURL
        rows[idx].title = title
        try saveAll(rows)
    }

    /// 同一规范化 URL 已存在则更新标题与时间；否则新增。用于「再点一次收藏」刷新名称。
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

    /// 按「当前页的 URL 字符串」做规范化匹配并删除（用于取消收藏）。
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
