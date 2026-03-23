import Foundation

/// 移植 `background.js` 中 **无痕 + webNavigation** 分支与 **tabs.onUpdated 标题** 分支（单标签页 `tabId = 0`）。
/// 仅应在主框架 **`didFinish`（等价 onCompleted）** 时调用 `onWebNavigationCompleted`，不要用 URL 类 tabs 事件重复写入。
@MainActor
final class PrivateHistoryRecorder {
    private static let debounceMs: Int64 = 4000

    private let store: IncognitoVaultStore

    private var debounceLastAt: [String: Int64] = [:]
    private var lastVaultUrlByTab: [Int: String] = [:]
    private var lastVaultRecordIdByTab: [String: Int64] = [:]

    /// RSA 公钥 SPKI DER（无密码也可追加加密记录，与扩展一致）；在 `Task.detached` 内再导入为 `SecKey`。
    private var cachedPublicSPKI: Data?

    init(store: IncognitoVaultStore) {
        self.store = store
        reloadPublicKeyFromDisk()
    }

    func reloadPublicKeyFromDisk() {
        cachedPublicSPKI = nil
        guard let meta = store.loadMeta() else { return }
        cachedPublicSPKI = Data(base64Encoded: meta.publicKeySPKI)
    }

    func clearMemoryState() {
        debounceLastAt.removeAll()
        lastVaultUrlByTab.removeAll()
        lastVaultRecordIdByTab.removeAll()
    }

    /// 对应 `onVisit(..., 'webNavigation')` 在无痕下的逻辑。
    func onWebNavigationCompleted(
        tabId: Int = 0,
        url: String,
        title: String,
        favIconUrl: String = "",
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        guard !url.isEmpty else { return }
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
                self.lastVaultUrlByTab[tabIdCopy] = normalizedUrl
                self.lastVaultRecordIdByTab[mapKeyCopy] = newId
            }
        }
    }

    /// 对应 `chrome.tabs.onUpdated` 里 `changeInfo.title` 的无痕分支。
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
