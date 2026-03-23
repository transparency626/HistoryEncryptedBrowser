import Foundation

/// 本地保险库文件（对应扩展 IndexedDB 的 `VAULT_META` + `VAULT`）。
@MainActor
final class IncognitoVaultStore {
    private let metaURL: URL
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

    func loadMeta() -> VaultMetaFile? {
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return nil }
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? decoder.decode(VaultMetaFile.self, from: data)
    }

    func saveMeta(_ meta: VaultMetaFile) throws {
        let data = try encoder.encode(meta)
        try atomicWrite(data, to: metaURL)
    }

    func deleteMeta() throws {
        if FileManager.default.fileExists(atPath: metaURL.path) {
            try FileManager.default.removeItem(at: metaURL)
        }
    }

    func loadAllRecords() -> [VaultRecordRow] {
        guard FileManager.default.fileExists(atPath: vaultURL.path) else { return [] }
        guard let data = try? Data(contentsOf: vaultURL) else { return [] }
        return (try? decoder.decode([VaultRecordRow].self, from: data)) ?? []
    }

    private func saveAllRecords(_ rows: [VaultRecordRow]) throws {
        let data = try encoder.encode(rows)
        try atomicWrite(data, to: vaultURL)
    }

    /// 新增一条，返回自增 id（对应 `addVaultRecord`）。
    func addVaultRecord(time: Int64, iv: String, ciphertext: String, encryptedAesKey: String) throws -> Int64 {
        var rows = loadAllRecords()
        let next = (rows.map(\.id).max() ?? 0) + 1
        rows.append(VaultRecordRow(id: next, time: time, iv: iv, ciphertext: ciphertext, encryptedAesKey: encryptedAesKey))
        try saveAllRecords(rows)
        return next
    }

    func deleteVaultRecord(id: Int64) throws {
        var rows = loadAllRecords()
        rows.removeAll { $0.id == id }
        try saveAllRecords(rows)
    }

    func clearVaultRecords() throws {
        try saveAllRecords([])
    }

    func clearAllIncognitoData() throws {
        try clearVaultRecords()
        try deleteMeta()
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

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
