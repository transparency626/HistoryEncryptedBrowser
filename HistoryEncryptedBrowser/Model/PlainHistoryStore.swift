import Foundation

/// 普通浏览模式下的明文历史条目（存 JSON，与无痕保险库文件分离）。
struct NormalHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: Int64
    var url: String
    var title: String
    var time: Int64
    var favIconUrl: String
}

/// 明文历史文件的读写；@MainActor 与 ViewModel 同线程，避免并发写文件。
@MainActor
final class PlainHistoryStore {
    /// 历史 JSON 文件路径。
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: 可选自定义目录；默认 Application Support/HistoryEncryptedBrowser。
    init(directory: URL? = nil) {
        // 优先 Application Support，没有则临时目录。
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

    /// 读取全部并按时间倒序（最新在前）。
    func loadAllSortedNewestFirst() -> [NormalHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let rows = (try? decoder.decode([NormalHistoryEntry].self, from: data)) ?? []
        return rows.sorted { $0.time > $1.time }
    }

    /// 追加一条，返回新行的自增 id。
    func addRecord(url: String, title: String, favIconUrl: String, time: Int64) throws -> Int64 {
        var rows = loadAllSortedNewestFirst()
        let next = (rows.map(\.id).max() ?? 0) + 1
        rows.append(NormalHistoryEntry(id: next, url: url, title: title, time: time, favIconUrl: favIconUrl))
        try saveAll(rows)
        return next
    }

    /// 按 id 删除一条。
    func deleteRecord(id: Int64) throws {
        var rows = loadAllSortedNewestFirst()
        rows.removeAll { $0.id == id }
        try saveAll(rows)
    }

    /// 清空全部历史。
    func clearAll() throws {
        try saveAll([])
    }

    /// 先写临时文件再替换，降低写入中断导致文件损坏的概率。
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
