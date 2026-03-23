import Foundation

/// 普通浏览下的明文历史条目（仅 http/https，与无痕加密库相互独立）。
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
