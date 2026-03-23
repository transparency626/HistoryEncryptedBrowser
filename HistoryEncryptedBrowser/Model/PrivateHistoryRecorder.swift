import Foundation

/// 无痕模式下的加密历史写入：与扩展 webNavigation 完成 + tabs 标题更新行为对齐。
/// 加密在 `Task.detached` 中执行，避免 RSA/AES 阻塞主线程。
@MainActor
final class PrivateHistoryRecorder {
    private static let debounceMs: Int64 = 4000

    private let store: IncognitoVaultStore

    private var debounceLastAt: [String: Int64] = [:]
    private var lastVaultUrlByTab: [Int: String] = [:]
    private var lastVaultRecordIdByTab: [String: Int64] = [:]

    /// 只缓存公钥 SPKI 的原始 DER（Base64 解码后）；后台任务里再 `importPublicKeySPKI`，避免跨并发域传 SecKey。
    private var cachedPublicSPKI: Data?

    init(store: IncognitoVaultStore) {
        self.store = store
        reloadPublicKeyFromDisk()
    }

    /// meta 变化后（创建保险库）重新读公钥。
    func reloadPublicKeyFromDisk() {
        cachedPublicSPKI = nil
        guard let meta = store.loadMeta() else { return }
        cachedPublicSPKI = Data(base64Encoded: meta.publicKeySPKI)
    }

    /// 切换模式时清空内存去重状态。
    func clearMemoryState() {
        debounceLastAt.removeAll()
        lastVaultUrlByTab.removeAll()
        lastVaultRecordIdByTab.removeAll()
    }

    /// 主文档加载完成：加密 payload 并写入磁盘。
    func onWebNavigationCompleted(
        tabId: Int = 0,
        url: String,
        title: String,
        favIconUrl: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        guard !url.isEmpty else { return }
        // 未创建保险库则无公钥，扩展里也不写。
        guard let spki = cachedPublicSPKI else { return }

        let normalizedUrl = URLHistoryNormalize.normalizeUrlForDedup(url)
        let mapKey = "\(tabId)::\(normalizedUrl)"

        if let last = debounceLastAt[mapKey], nowMs - last < Self.debounceMs { return }
        debounceLastAt[mapKey] = nowMs

        if lastVaultUrlByTab[tabId] == normalizedUrl { return }

        let payload = VaultPayload(
            url: url,
            title: title,
            favIconUrl: favIconUrl,
            time: nowMs,
            tabId: tabId,
            actions: []
        )

        let tabIdCopy = tabId
        let mapKeyCopy = mapKey
        Task { [weak self] in
            // 在后台线程做 RSA + AES。
            let enc = await Task.detached {
                try? VaultCryptoService.encryptRecord(spkiDER: spki, payload: payload)
            }.value
            guard let enc else { return }
            // 写文件必须在主 actor（IncognitoVaultStore 标了 @MainActor）。
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let newId = try? self.store.addVaultRecord(
                    time: nowMs,
                    iv: enc.iv.base64EncodedString(),
                    ciphertext: enc.ciphertext.base64EncodedString(),
                    encryptedAesKey: enc.encryptedAesKey.base64EncodedString()
                ) else { return }
                self.lastVaultUrlByTab[tabIdCopy] = normalizedUrl
                self.lastVaultRecordIdByTab[mapKeyCopy] = newId
            }
        }
    }

    /// 标题变化：删旧密文记录，再加密插入新记录。
    func onTitleUpdated(
        tabId: Int = 0,
        url: String,
        title: String,
        favIconUrl: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        guard let spki = cachedPublicSPKI else { return }
        let normalizedUrl = URLHistoryNormalize.normalizeUrlForDedup(url)
        let mapKey = "\(tabId)::\(normalizedUrl)"
        guard let vaultId = lastVaultRecordIdByTab[mapKey] else { return }

        lastVaultRecordIdByTab.removeValue(forKey: mapKey)
        try? store.deleteVaultRecord(id: vaultId)

        let payload = VaultPayload(
            url: url,
            title: title,
            favIconUrl: favIconUrl,
            time: nowMs,
            tabId: tabId,
            actions: []
        )
        let mapKeyCopy = mapKey
        Task { [weak self] in
            let enc = await Task.detached {
                try? VaultCryptoService.encryptRecord(spkiDER: spki, payload: payload)
            }.value
            guard let enc else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let newId = try? self.store.addVaultRecord(
                    time: nowMs,
                    iv: enc.iv.base64EncodedString(),
                    ciphertext: enc.ciphertext.base64EncodedString(),
                    encryptedAesKey: enc.encryptedAesKey.base64EncodedString()
                ) else { return }
                self.lastVaultRecordIdByTab[mapKeyCopy] = newId
            }
        }
    }
}
