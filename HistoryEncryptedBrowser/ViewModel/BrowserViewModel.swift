import Combine
import Foundation
import Security

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var addressBar: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var locationDisplay: String = BrowserNavigationSnapshot.blank.locationDisplay

    /// 普通浏览：持久化 Cookie 等 + 明文历史。无痕：非持久化 + 仅此时写入加密保险库。
    @Published private(set) var browsingMode: BrowsingMode = .normal

    /// 普通模式下的明文历史（用于列表展示）。
    @Published private(set) var normalHistoryEntries: [NormalHistoryEntry] = []

    /// 是否已有保险库元数据（有公钥才可写加密历史）。
    @Published private(set) var vaultMetaPresent = false
    @Published private(set) var vaultUnlocked = false
    @Published private(set) var vaultListItems: [VaultListItem] = []

    private let addressResolver: AddressResolving
    private let vaultStore: IncognitoVaultStore
    private let plainHistoryStore: PlainHistoryStore
    private let privateRecorder: PrivateHistoryRecorder
    private let normalRecorder: NormalHistoryRecorder
    private weak var navigationDriver: BrowserNavigationDriver?

    private var unlockedPrivateKey: SecKey?
    private var lastTitleObservationKey: String?
    private var lastTitleObservationValue: String?

    var vaultNeedsPasswordSetup: Bool { !vaultMetaPresent }

    init(addressResolver: AddressResolving = DefaultAddressResolver()) {
        self.addressResolver = addressResolver
        let store = IncognitoVaultStore()
        let plain = PlainHistoryStore()
        self.vaultStore = store
        self.plainHistoryStore = plain
        self.privateRecorder = PrivateHistoryRecorder(store: store)
        self.normalRecorder = NormalHistoryRecorder(store: plain)
        self.vaultMetaPresent = store.loadMeta() != nil
    }

    func setBrowsingMode(_ mode: BrowsingMode) {
        guard mode != browsingMode else { return }
        browsingMode = mode
        if mode == .normal {
            privateRecorder.clearMemoryState()
        } else {
            normalRecorder.clearMemoryState()
        }
        lastTitleObservationKey = nil
        lastTitleObservationValue = nil
        applySnapshot(.blank)
        estimatedProgress = 0
        isLoading = false
    }

    func refreshNormalHistoryList() {
        normalHistoryEntries = plainHistoryStore.loadAllSortedNewestFirst()
    }

    func deleteNormalHistoryItems(at offsets: IndexSet) {
        let snap = normalHistoryEntries
        for i in offsets where snap.indices.contains(i) {
            try? plainHistoryStore.deleteRecord(id: snap[i].id)
        }
        refreshNormalHistoryList()
    }

    func clearNormalHistory() {
        try? plainHistoryStore.clearAll()
        normalRecorder.clearMemoryState()
        refreshNormalHistoryList()
    }

    func openNormalHistoryEntry(_ item: NormalHistoryEntry) {
        guard let u = URL(string: item.url) else { return }
        addressBar = item.url
        navigationDriver?.load(url: u)
    }

    func attachNavigationDriver(_ driver: BrowserNavigationDriver) {
        navigationDriver = driver
    }

    /// 仅当当前绑定的仍是 `driver` 时才解除。避免切换普通/无痕时新 `WKWebView` 已 `attach` 后，旧视图 `dismantle` 晚到把新 driver 误清掉（会导致「前往」无反应）。
    func detachNavigationDriver(_ driver: BrowserNavigationDriver) {
        guard (navigationDriver as AnyObject?) === (driver as AnyObject) else { return }
        navigationDriver = nil
    }

    func submitAddress() {
        let raw = addressBar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = addressResolver.resolvedURL(forUserInput: raw) else { return }
        navigationDriver?.load(url: url)
    }

    func goBack() { navigationDriver?.goBack() }
    func goForward() { navigationDriver?.goForward() }

    func reloadOrStop() {
        if isLoading {
            navigationDriver?.stopLoading()
        } else {
            navigationDriver?.reload()
        }
    }

    func syncAddressBarFromWebIfNeeded(addressFieldFocused: Bool) {
        guard !addressFieldFocused else { return }
        let u = locationDisplay
        guard u != "about:blank", !u.isEmpty else { return }
        addressBar = u
    }

    // MARK: - 无痕加密历史（逻辑对齐 `background.js` + `vault-crypto.js`）

    /// 与扩展 `trySetPassword` 规则一致。重密码学在后台执行，避免主线程卡死被系统 `SIGTERM`。
    func validateAndSetVaultPassword(_ pwd1: String, _ pwd2: String) async throws {
        guard pwd1.count >= 8, pwd1.count <= 16 else {
            throw VaultSetupValidationError(message: "密码须为 8～16 位")
        }
        let hasDigit = pwd1.range(of: "[0-9]", options: .regularExpression) != nil
        let hasUpper = pwd1.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasLower = pwd1.range(of: "[a-z]", options: .regularExpression) != nil
        let hasSymbol = pwd1.range(of: "[^0-9A-Za-z]", options: .regularExpression) != nil
        guard hasDigit, hasUpper, hasLower, hasSymbol else {
            throw VaultSetupValidationError(message: "密码须同时包含数字、大写字母、小写字母和符号")
        }
        guard pwd1 == pwd2 else {
            throw VaultSetupValidationError(message: "两次输入不一致，请再次输入验证")
        }
        let pwd = pwd1
        let meta = try await Task.detached(priority: .userInitiated) {
            try VaultCryptoService.createVaultMeta(password: pwd)
        }.value
        try vaultStore.saveMeta(meta)
        privateRecorder.reloadPublicKeyFromDisk()
        vaultMetaPresent = true
    }

    func unlockVault(password: String) async throws {
        guard let meta = vaultStore.loadMeta() else { return }
        let pwd = password
        let der = try await Task.detached(priority: .userInitiated) {
            let priv = try VaultCryptoService.unlockPrivateKey(meta: meta, password: pwd)
            return try VaultCryptoService.exportPrivateKeyDER(priv)
        }.value
        unlockedPrivateKey = try VaultCryptoService.importPrivateKeyDER(der)
        vaultUnlocked = true
        await refreshVaultList()
    }

    func lockVault() {
        unlockedPrivateKey = nil
        vaultUnlocked = false
        vaultListItems = []
    }

    func refreshVaultList() async {
        guard let pk = unlockedPrivateKey else {
            vaultListItems = []
            return
        }
        guard let der = try? VaultCryptoService.exportPrivateKeyDER(pk) else { return }
        let rows = vaultStore.loadAllRecords().sorted { $0.time > $1.time }
        var pairs: [(Int64, VaultRecordEncoded)] = []
        pairs.reserveCapacity(rows.count)
        for r in rows {
            guard let enc = try? vaultStore.rowToEncoded(r) else { continue }
            pairs.append((r.id, enc))
        }
        let items = await Task.detached(priority: .userInitiated) {
            guard let sk = try? VaultCryptoService.importPrivateKeyDER(der) else { return [VaultListItem]() }
            var out: [VaultListItem] = []
            out.reserveCapacity(pairs.count)
            for (id, enc) in pairs {
                guard let plain = try? VaultCryptoService.decryptRecord(encoded: enc, privateKey: sk) else { continue }
                out.append(VaultListItem(id: id, payload: plain))
            }
            return out
        }.value
        vaultListItems = items
    }

    func deleteVaultListItems(at offsets: IndexSet) {
        let snap = vaultListItems
        for i in offsets where snap.indices.contains(i) {
            try? vaultStore.deleteVaultRecord(id: snap[i].id)
        }
        Task { await refreshVaultList() }
    }

    func clearVaultRecords() {
        try? vaultStore.clearVaultRecords()
        privateRecorder.clearMemoryState()
        Task { await refreshVaultList() }
    }

    func openVaultEntry(_ item: VaultListItem) {
        guard let u = URL(string: item.payload.url) else { return }
        addressBar = item.payload.url
        navigationDriver?.load(url: u)
    }

    /// 主文档 `didFinish`：普通模式写明文历史；无痕模式写加密保险库（无公钥则跳过）。
    func browserHistoryOnNavigationCompleted(url: String, title: String) {
        guard shouldRecordHistoryURL(url) else { return }
        switch browsingMode {
        case .normal:
            normalRecorder.onWebNavigationCompleted(url: url, title: title, favIconUrl: "")
        case .incognito:
            privateRecorder.onWebNavigationCompleted(url: url, title: title, favIconUrl: "")
        }
    }

    /// 标题 KVO：两种模式分别更新对应存储。
    func browserHistoryOnTitleChange(url: String, title: String) {
        guard shouldRecordHistoryURL(url) else { return }
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url)
        if lastTitleObservationKey == norm, lastTitleObservationValue == title { return }
        lastTitleObservationKey = norm
        lastTitleObservationValue = title
        switch browsingMode {
        case .normal:
            normalRecorder.onTitleUpdated(url: url, title: title, favIconUrl: "")
        case .incognito:
            privateRecorder.onTitleUpdated(url: url, title: title, favIconUrl: "")
        }
    }

    private func shouldRecordHistoryURL(_ url: String) -> Bool {
        guard url != "about:blank", !url.isEmpty else { return false }
        guard let u = URL(string: url), let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return true
    }

    private func applySnapshot(_ snapshot: BrowserNavigationSnapshot) {
        locationDisplay = snapshot.locationDisplay
        pageTitle = snapshot.pageTitle
        canGoBack = snapshot.canGoBack
        canGoForward = snapshot.canGoForward
    }
}

extension BrowserViewModel: BrowserWebEventSink {
    func handleLoadStarted() {
        isLoading = true
    }

    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot) {
        applySnapshot(snapshot)
    }

    func handleLoadFinished(snapshot: BrowserNavigationSnapshot) {
        isLoading = false
        applySnapshot(snapshot)
        browserHistoryOnNavigationCompleted(url: snapshot.locationDisplay, title: snapshot.pageTitle)
    }

    func handleLoadFailed(snapshot: BrowserNavigationSnapshot) {
        isLoading = false
        applySnapshot(snapshot)
    }

    func handleEstimatedProgress(_ value: Double) {
        estimatedProgress = value
    }
}
