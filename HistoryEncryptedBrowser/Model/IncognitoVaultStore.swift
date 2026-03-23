import Foundation

/// 无痕加密保险库的磁盘层：元数据文件 + 加密记录数组 JSON。
@MainActor
final class IncognitoVaultStore {
    /// 保险库 meta（盐、公钥、加密私钥）。
    private let metaURL: URL
    /// 加密历史记录列表。
    private let vaultURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("HistoryEncryptedBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        metaURL = dir.appendingPathComponent("incognito_vault_meta.json", isDirectory: false)
        vaultURL = dir.appendingPathComponent("incognito_vault_records.json", isDirectory: false)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    /// 读取 meta；不存在或损坏返回 nil。
    func loadMeta() -> VaultMetaFile? {
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return nil }
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? decoder.decode(VaultMetaFile.self, from: data)
    }

    /// 写入 meta（创建保险库时）。
    func saveMeta(_ meta: VaultMetaFile) throws {
        let data = try encoder.encode(meta)
        try atomicWrite(data, to: metaURL)
    }

    /// 删除 meta 文件。
    func deleteMeta() throws {
        if FileManager.default.fileExists(atPath: metaURL.path) {
            try FileManager.default.removeItem(at: metaURL)
        }
    }

    /// 读取所有加密记录行（顺序不保证，调用方可再排序）。
    func loadAllRecords() -> [VaultRecordRow] {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return [] }
        guard let data = try? Data(contentsOf: vaultURL) else { return [] }
        return (try? decoder.decode([VaultRecordRow].self, from: data)) ?? []
    }

    private func saveAllRecords(_ rows: [VaultRecordRow]) throws {
        let data = try encoder.encode(rows)
        try atomicWrite(data, to: vaultURL)
    }

    /// 追加一条加密记录，返回自增 id。
    func addVaultRecord(time: Int64, iv: String, ciphertext: String, encryptedAesKey: String) throws -> Int64 {
        var rows = loadAllRecords()
        let next = (rows.map(\.id).max() ?? 0) + 1
        rows.append(VaultRecordRow(id: next, time: time, iv: iv, ciphertext: ciphertext, encryptedAesKey: encryptedAesKey))
        try saveAllRecords(rows)
        return next
    }

    /// 按 id 删除一条。
    func deleteVaultRecord(id: Int64) throws {
        var rows = loadAllRecords()
        rows.removeAll { $0.id == id }
        try saveAllRecords(rows)
    }

    /// 清空所有加密记录（不删 meta）。
    func clearVaultRecords() throws {
        try saveAllRecords([])
    }

    /// 连记录带 meta 一起删（预留，例如「重置保险库」）。
    func clearAllIncognitoData() throws {
        try clearVaultRecords()
        try deleteMeta()
    }

    /// 原子写：tmp → rename，减少半截 JSON。
    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// 把磁盘行转成内存密文结构，供解密。
    func rowToEncoded(_ row: VaultRecordRow) throws -> VaultRecordEncoded {
        guard let iv = Data(base64Encoded: row.iv),
              let ct = Data(base64Encoded: row.ciphertext),
              let eak = Data(base64Encoded: row.encryptedAesKey)
        else {
            throw VaultCryptoService.VaultCryptoError.invalidInput
        }
        return VaultRecordEncoded(iv: iv, ciphertext: ct, encryptedAesKey: eak)
    }
}
