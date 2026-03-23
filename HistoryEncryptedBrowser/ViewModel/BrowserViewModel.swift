// Combine：ObservableObject / @Published 依赖（本文件主要用后者）。
import Combine
import Foundation
// Security：解锁后内存里持有 SecKey（私钥）。
import Security

/// 浏览器主 ViewModel：地址栏、导航状态、双模式历史、保险库状态；@MainActor 与 SwiftUI 同线程。
@MainActor
final class BrowserViewModel: ObservableObject {
    // MARK: - 地址与导航（驱动 UI）

    /// 地址栏里用户正在编辑的文本。
    @Published var addressBar: String = ""
    /// 当前页标题（来自快照）。
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    /// WKWebView.estimatedProgress。
    @Published var estimatedProgress: Double = 0
    /// 展示用 URL 字符串（可能与 addressBar 不同步，以网页为准时由快照更新）。
    @Published var locationDisplay: String = BrowserNavigationSnapshot.blank.locationDisplay

    // MARK: - 浏览模式与历史

    /// 当前是「普通」还是「无痕」；影响 WKWebsiteDataStore 与写哪条历史管道。
    @Published private(set) var browsingMode: BrowsingMode = .normal

    /// 明文历史列表数据（打开「浏览历史」 sheet 时刷新）。
    @Published private(set) var normalHistoryEntries: [NormalHistoryEntry] = []

    // MARK: - 保险库（无痕加密）

    /// 磁盘上是否已有 meta（有则无痕可写加密记录）。
    @Published private(set) var vaultMetaPresent = false
    /// 当前会话是否已解锁私钥（内存中有 SecKey）。
    @Published private(set) var vaultUnlocked = false
    /// 解锁后解密得到的列表，供 sheet 展示。
    @Published private(set) var vaultListItems: [VaultListItem] = []

    /// 地址解析策略（测试可注入 Mock）。
    private let addressResolver: AddressResolving
    /// 无痕加密存储。
    private let vaultStore: IncognitoVaultStore
    /// 普通明文历史存储。
    private let plainHistoryStore: PlainHistoryStore
    /// 无痕侧记录器。
    private let privateRecorder: PrivateHistoryRecorder
    /// 普通侧记录器。
    private let normalRecorder: NormalHistoryRecorder
    /// 当前驱动 WKWebView 的 Coordinator；weak 避免 VM↔Coordinator 循环引用（Coordinator 弱引用 VM）。
    private weak var navigationDriver: BrowserNavigationDriver?

    /// 解锁后仅在内存中保留私钥；lockVault 时置 nil。
    private var unlockedPrivateKey: SecKey?
    /// 用于减少标题 KVO 重复触发：上次处理的 (规范化URL, 标题)。
    private var lastTitleObservationKey: String?
    private var lastTitleObservationValue: String?

    /// 尚未创建 meta 时需要走「设置密码」流程。
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

    /// 切换普通/无痕：清理对方内存去重、重置导航快照（WebView 由 View 层 .id 重建）。
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

    /// 从磁盘重载明文历史到 @Published。
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

    /// WebView 创建时由 Coordinator 注册。
    func attachNavigationDriver(_ driver: BrowserNavigationDriver) {
        navigationDriver = driver
    }

    /// 仅当要拆下的实例仍是当前 driver 时才置 nil，防止新旧 WebView 交接时误删新 driver。
    func detachNavigationDriver(_ driver: BrowserNavigationDriver) {
        guard (navigationDriver as AnyObject?) === (driver as AnyObject) else { return }
        navigationDriver = nil
    }

    /// 解析地址栏并交给 WebView 加载。
    func submitAddress() {
        let raw = addressBar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = addressResolver.resolvedURL(forUserInput: raw) else { return }
        navigationDriver?.load(url: url)
    }

    func goBack() { navigationDriver?.goBack() }
    func goForward() { navigationDriver?.goForward() }

    /// 加载中则停止，否则刷新。
    func reloadOrStop() {
        if isLoading {
            navigationDriver?.stopLoading()
        } else {
            navigationDriver?.reload()
        }
    }

    /// 加载结束后，若用户没在编辑地址栏，用当前页 URL 回填地址栏。
    func syncAddressBarFromWebIfNeeded(addressFieldFocused: Bool) {
        guard !addressFieldFocused else { return }
        let u = locationDisplay
        guard u != "about:blank", !u.isEmpty else { return }
        addressBar = u
    }

    // MARK: - 保险库 API

    /// 首次创建：校验密码规则 → 后台 PBKDF2+RSA → 写 meta → 刷新公钥缓存。
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

    /// 解锁：后台 PBKDF2+解密私钥 → 主线程导入 SecKey → 异步解密列表。
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

    /// 清除内存私钥与列表；进后台时也会调用。
    func lockVault() {
        unlockedPrivateKey = nil
        vaultUnlocked = false
        vaultListItems = []
    }

    /// 批量 RSA 解密在后台执行，避免卡 UI。
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

    /// didFinish 时：按模式分流到明文或加密记录器。
    func browserHistoryOnNavigationCompleted(url: String, title: String) {
        guard shouldRecordHistoryURL(url) else { return }
        switch browsingMode {
        case .normal:
            normalRecorder.onWebNavigationCompleted(url: url, title: title, favIconUrl: "")
        case .incognito:
            privateRecorder.onWebNavigationCompleted(url: url, title: title, favIconUrl: "")
        }
    }

    /// 标题变化：同样按模式分流。
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

    /// 只记录 http/https，忽略 about:blank。
    private func shouldRecordHistoryURL(_ url: String) -> Bool {
        guard url != "about:blank", !url.isEmpty else { return false }
        guard let u = URL(string: url), let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return true
    }

    /// 把 Web 快照写入各 @Published 导航字段。
    private func applySnapshot(_ snapshot: BrowserNavigationSnapshot) {
        locationDisplay = snapshot.locationDisplay
        pageTitle = snapshot.pageTitle
        canGoBack = snapshot.canGoBack
        canGoForward = snapshot.canGoForward
    }
}

// MARK: - WKWebView 事件入口（由 Coordinator 调用）

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
