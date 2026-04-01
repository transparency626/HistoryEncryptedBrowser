// Combine：ObservableObject / @Published 依赖（本文件主要用后者）。
import Combine
import Foundation

// MARK: - Web 层协议（Coordinator 实现 Driver，ViewModel 实现 Sink）

protocol BrowserNavigationDriver: AnyObject {
    func load(url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    func fetchDocumentTitle(completion: @escaping (String?) -> Void)
}

@MainActor
protocol BrowserWebEventSink: AnyObject {
    func handleLoadStarted()
    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot)
    func handleLoadFinished(snapshot: BrowserNavigationSnapshot)
    func handleLoadFailed(snapshot: BrowserNavigationSnapshot)
    func handleEstimatedProgress(_ value: Double)
}

/// 浏览器主 ViewModel：地址栏、导航、普通模式下的历史与收藏；无痕模式不写磁盘。
@MainActor
final class BrowserViewModel: ObservableObject {
    // MARK: - 地址与导航

    @Published var addressBar: String = ""
    @Published var pageTitle: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var estimatedProgress: Double = 0
    @Published var locationDisplay: String = BrowserNavigationSnapshot.blank.locationDisplay

    // MARK: - 浏览模式与持久化数据（仅普通模式写入）

    @Published private(set) var browsingMode: BrowsingMode = .normal

    @Published private(set) var normalHistoryEntries: [NormalHistoryEntry] = []
    @Published private(set) var bookmarkEntries: [BookmarkEntry] = []

    private let addressResolver: AddressResolving
    private let plainHistoryStore: PlainHistoryStore
    private let bookmarksStore: BookmarksStore
    private let normalRecorder: NormalHistoryRecorder
    private weak var navigationDriver: BrowserNavigationDriver?

    private var lastTitleObservationKey: String?
    private var lastTitleObservationValue: String?

    init(addressResolver: AddressResolving = DefaultAddressResolver()) {
        self.addressResolver = addressResolver
        let plain = PlainHistoryStore()
        self.plainHistoryStore = plain
        self.bookmarksStore = BookmarksStore()
        self.normalRecorder = NormalHistoryRecorder(store: plain)
        refreshBookmarksList()
    }

    /// 切换普通/无痕：无痕不写历史；切到无痕时清掉明文记录器的内存去重状态。
    func setBrowsingMode(_ mode: BrowsingMode) {
        guard mode != browsingMode else { return }
        browsingMode = mode
        if mode == .incognito {
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

    // MARK: - 收藏夹（仅普通模式可改；数据仍存于应用沙盒，与无痕会话无关）

    func refreshBookmarksList() {
        bookmarkEntries = bookmarksStore.loadAllSortedNewestFirst()
    }

    func tryRefreshBookmarkTitleForCurrentPageIfNeeded() {
        guard browsingMode == .normal else { return }
        let u = locationDisplay
        guard shouldRecordHistoryURL(u) else { return }
        let norm = URLHistoryNormalize.normalizeUrlForDedup(u)
        guard let entry = bookmarkEntries.first(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return }
        if sanitizedBookmarkTitle(entry.title, pageURL: u).isEmpty {
            tryFillBookmarkTitleViaJS(pageURL: u, retryCount: 0)
        }
    }

    var isCurrentPageBookmarked: Bool {
        guard browsingMode == .normal else { return false }
        let u = locationDisplay
        guard shouldRecordHistoryURL(u) else { return false }
        let norm = URLHistoryNormalize.normalizeUrlForDedup(u)
        return bookmarkEntries.contains { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }
    }

    func toggleBookmarkForCurrentPage() {
        guard browsingMode == .normal else { return }
        let u = locationDisplay
        guard shouldRecordHistoryURL(u) else { return }
        let norm = URLHistoryNormalize.normalizeUrlForDedup(u)
        let already = bookmarkEntries.contains { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }
        var needJSTitle = false
        if already {
            try? bookmarksStore.removeMatchingNormalizedURL(u)
        } else {
            let raw = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = sanitizedBookmarkTitle(raw, pageURL: u)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try? bookmarksStore.upsert(url: u, title: title, favIconUrl: "", time: now)
            needJSTitle = title.isEmpty
        }
        refreshBookmarksList()
        if needJSTitle {
            tryFillBookmarkTitleViaJS(pageURL: u, retryCount: 0)
        }
    }

    func deleteBookmarkItems(at offsets: IndexSet) {
        let snap = bookmarkEntries
        for i in offsets where snap.indices.contains(i) {
            try? bookmarksStore.deleteRecord(id: snap[i].id)
        }
        refreshBookmarksList()
    }

    func clearBookmarks() {
        try? bookmarksStore.clearAll()
        refreshBookmarksList()
    }

    func openBookmarkEntry(_ item: BookmarkEntry) {
        guard let url = URL(string: item.url) else { return }
        addressBar = item.url
        navigationDriver?.load(url: url)
    }

    func attachNavigationDriver(_ driver: BrowserNavigationDriver) {
        navigationDriver = driver
    }

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

    func browserHistoryOnNavigationCompleted(url: String, title: String) {
        guard browsingMode == .normal else { return }
        guard shouldRecordHistoryURL(url) else { return }
        normalRecorder.onWebNavigationCompleted(url: url, title: title, favIconUrl: "")
        syncBookmarkTitleWithPage(url: url, title: title)
    }

    func browserHistoryOnTitleChange(url: String, title: String) {
        guard browsingMode == .normal else { return }
        guard shouldRecordHistoryURL(url) else { return }
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url)
        if lastTitleObservationKey == norm, lastTitleObservationValue == title { return }
        lastTitleObservationKey = norm
        lastTitleObservationValue = title
        normalRecorder.onTitleUpdated(url: url, title: title, favIconUrl: "")
        syncBookmarkTitleWithPage(url: url, title: title)
    }

    private func syncBookmarkTitleWithPage(url: String, title: String) {
        guard browsingMode == .normal else { return }
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url)
        guard bookmarkEntries.contains(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return }
        let clean = sanitizedBookmarkTitle(title, pageURL: url)
        if !clean.isEmpty {
            try? bookmarksStore.updateTitleIfBookmarked(pageURL: url, title: clean)
            refreshBookmarksList()
        } else {
            tryFillBookmarkTitleViaJS(pageURL: url, retryCount: 0)
        }
    }

    private func sanitizedBookmarkTitle(_ raw: String, pageURL: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if t == pageURL { return "" }
        let nu = URLHistoryNormalize.normalizeUrlForDedup(pageURL)
        let nt = URLHistoryNormalize.normalizeUrlForDedup(t)
        if nu == nt { return "" }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return "" }
        return t
    }

    private func tryFillBookmarkTitleViaJS(pageURL: String, retryCount: Int) {
        guard browsingMode == .normal else { return }
        navigationDriver?.fetchDocumentTitle { [weak self] raw in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL)
                guard self.bookmarkEntries.contains(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return }
                let clean = raw.map { self.sanitizedBookmarkTitle($0, pageURL: pageURL) } ?? ""
                if !clean.isEmpty {
                    try? self.bookmarksStore.updateTitleIfBookmarked(pageURL: pageURL, title: clean)
                    self.refreshBookmarksList()
                    return
                }
                if retryCount < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self else { return }
                        self.tryFillBookmarkTitleViaJS(pageURL: pageURL, retryCount: retryCount + 1)
                    }
                }
            }
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
