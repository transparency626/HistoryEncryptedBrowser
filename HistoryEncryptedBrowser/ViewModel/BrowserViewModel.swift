import Combine // ObservableObject、@Published
import Foundation // 基础类型，无 UI

// MARK: - Web 层协议（Coordinator 实现 Driver，ViewModel 实现 Sink）

/// Web 对 VM 暴露的导航接口，AnyObject 便于 === 比较实例。
protocol BrowserNavigationDriver: AnyObject { // 仅类可实现
    func load(url: URL) // 加载指定 URL
    func goBack() // 后退
    func goForward() // 前进
    func reload() // 刷新
    func stopLoading() // 停止加载
    func fetchDocumentTitle(completion: @escaping (String?) -> Void) // 异步取标题，escaping 闭包
}

/// Web 向 VM 上报事件，主线程隔离。
@MainActor // 整个协议要求主线程
protocol BrowserWebEventSink: AnyObject { // 引用语义
    func handleLoadStarted() // 开始加载
    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot) // 已提交，带快照
    func handleLoadFinished(snapshot: BrowserNavigationSnapshot) // 加载完成
    func handleLoadFailed(snapshot: BrowserNavigationSnapshot) // 加载失败
    func handleEstimatedProgress(_ value: Double) // 估计进度 0…1
}

/// 浏览器 VM：地址栏、导航、普通模式历史与收藏。
@MainActor // 与 SwiftUI 同线程
final class BrowserViewModel: ObservableObject { // SwiftUI 可观察对象
    // MARK: - 地址与导航

    @Published var addressBar: String = "" // 用户编辑中的地址栏文本
    @Published var pageTitle: String = "" // 当前页标题
    @Published var canGoBack = false // 能否后退
    @Published var canGoForward = false // 能否前进
    @Published var isLoading = false // 是否正在加载
    @Published var estimatedProgress: Double = 0 // WebKit 进度 0…1
    @Published var locationDisplay: String = BrowserNavigationSnapshot.blank.locationDisplay // 界面展示的当前 URL

    // MARK: - 浏览模式与持久化数据（仅普通模式写入）

    @Published private(set) var browsingMode: BrowsingMode = .normal // 普通或无痕，外部只读改通过方法
    @Published private(set) var normalHistoryEntries: [NormalHistoryEntry] = [] // 历史列表缓存
    @Published private(set) var bookmarkEntries: [BookmarkEntry] = [] // 收藏列表缓存

    private let addressResolver: AddressResolving // 地址解析策略
    private let plainHistoryStore: PlainHistoryStore // 历史存储
    private let bookmarksStore: BookmarksStore // 收藏存储
    private let normalRecorder: NormalHistoryRecorder // 历史记录器（去重防抖）
    private weak var navigationDriver: BrowserNavigationDriver? // 弱引用 Coordinator，避免循环引用

    private var lastTitleObservationKey: String? // 上次处理的规范化 URL，用于去重标题回调
    private var lastTitleObservationValue: String? // 上次处理的标题字符串

    init(addressResolver: AddressResolving = DefaultAddressResolver()) { // 可注入解析器
        self.addressResolver = addressResolver // 保存解析器
        let plain = PlainHistoryStore() // 新建历史存储
        self.plainHistoryStore = plain // 赋值
        self.bookmarksStore = BookmarksStore() // 新建收藏存储
        self.normalRecorder = NormalHistoryRecorder(store: plain) // 记录器与历史共用 store
        refreshBookmarksList() // 初始把收藏读进内存
    }

    func setBrowsingMode(_ mode: BrowsingMode) { // 切换普通/无痕
        guard mode != browsingMode else { return } // 相同模式直接返回
        browsingMode = mode // 写入新模式
        if mode == .incognito { // 若进入无痕
            normalRecorder.clearMemoryState() // 清空明文记录器内存状态
        }
        lastTitleObservationKey = nil // 重置标题去重键
        lastTitleObservationValue = nil // 重置标题去重值
        applySnapshot(.blank) // UI 回到空白快照
        estimatedProgress = 0 // 进度归零
        isLoading = false // 不显示加载中
    }

    func refreshNormalHistoryList() { // 从磁盘刷新历史数组
        normalHistoryEntries = plainHistoryStore.loadAllSortedNewestFirst() // 读盘并排序
    }

    func deleteNormalHistoryItems(at offsets: IndexSet) { // 按索引删历史
        let snap = normalHistoryEntries // 快照避免删除过程中索引变化
        for i in offsets where snap.indices.contains(i) { // 遍历要删的索引
            try? plainHistoryStore.deleteRecord(id: snap[i].id) // 按 id 删磁盘
        }
        refreshNormalHistoryList() // 刷新 Published
    }

    func clearNormalHistory() { // 清空全部历史
        try? plainHistoryStore.clearAll() // 磁盘清空
        normalRecorder.clearMemoryState() // 内存状态清空
        refreshNormalHistoryList() // 刷新列表
    }

    func openNormalHistoryEntry(_ item: NormalHistoryEntry) { // 从历史点开网页
        guard let u = URL(string: item.url) else { return } // 非法 URL 则返回
        addressBar = item.url // 同步地址栏显示
        navigationDriver?.load(url: u) // 让 WebView 加载
    }

    // MARK: - 收藏夹（仅普通模式可改；数据在沙盒，与无痕会话逻辑分离）

    func refreshBookmarksList() { // 从磁盘刷新收藏
        bookmarkEntries = bookmarksStore.loadAllSortedNewestFirst() // 读盘
    }

    func tryRefreshBookmarkTitleForCurrentPageIfNeeded() { // 打开收藏 sheet 时补标题
        guard browsingMode == .normal else { return } // 非普通模式不处理
        let u = locationDisplay // 当前展示 URL
        guard shouldRecordHistoryURL(u) else { return } // 非 http(s) 不处理
        let norm = URLHistoryNormalize.normalizeUrlForDedup(u) // 规范化
        guard let entry = bookmarkEntries.first(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return } // 无收藏则返回
        if sanitizedBookmarkTitle(entry.title, pageURL: u).isEmpty { // 若标题无效
            tryFillBookmarkTitleViaJS(pageURL: u, retryCount: 0) // 用 JS 补
        }
    }

    var isCurrentPageBookmarked: Bool { // 计算属性：当前页是否已收藏
        guard browsingMode == .normal else { return false } // 无痕当未收藏显示
        let u = locationDisplay // 当前 URL
        guard shouldRecordHistoryURL(u) else { return false } // 非网页不显示收藏状态
        let norm = URLHistoryNormalize.normalizeUrlForDedup(u) // 规范化
        return bookmarkEntries.contains { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm } // 是否存在同键收藏
    }

    func toggleBookmarkForCurrentPage() { // 切换收藏状态
        guard browsingMode == .normal else { return } // 无痕不允许改收藏
        let u = locationDisplay // 当前页 URL
        guard shouldRecordHistoryURL(u) else { return } // 非 http(s) 不操作
        let norm = URLHistoryNormalize.normalizeUrlForDedup(u) // 规范化键
        let already = bookmarkEntries.contains { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm } // 是否已收藏
        var needJSTitle = false // 是否需要 JS 补标题
        if already { // 已收藏则删除
            try? bookmarksStore.removeMatchingNormalizedURL(u) // 按规范化 URL 删
        } else { // 未收藏则添加
            let raw = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines) // 当前标题去空白
            let title = sanitizedBookmarkTitle(raw, pageURL: u) // 净化标题
            let now = Int64(Date().timeIntervalSince1970 * 1000) // 当前毫秒时间戳
            try? bookmarksStore.upsert(url: u, title: title, favIconUrl: "", time: now) // 插入或更新
            needJSTitle = title.isEmpty // 标题空则需要 JS
        }
        refreshBookmarksList() // 刷新列表
        if needJSTitle { // 若需要补标题
            tryFillBookmarkTitleViaJS(pageURL: u, retryCount: 0) // 异步取标题
        }
    }

    func deleteBookmarkItems(at offsets: IndexSet) { // 按索引删收藏
        let snap = bookmarkEntries // 快照
        for i in offsets where snap.indices.contains(i) { // 遍历索引
            try? bookmarksStore.deleteRecord(id: snap[i].id) // 按 id 删除
        }
        refreshBookmarksList() // 刷新
    }

    func clearBookmarks() { // 清空收藏
        try? bookmarksStore.clearAll() // 磁盘清空
        refreshBookmarksList() // 刷新
    }

    func openBookmarkEntry(_ item: BookmarkEntry) { // 从收藏打开
        guard let url = URL(string: item.url) else { return } // URL 非法则返回
        addressBar = item.url // 填地址栏
        navigationDriver?.load(url: url) // 加载
    }

    func attachNavigationDriver(_ driver: BrowserNavigationDriver) { // 注册 Coordinator
        navigationDriver = driver // 强引用转由 VM 持有（Coordinator 侧弱引用 VM）
    }

    func detachNavigationDriver(_ driver: BrowserNavigationDriver) { // 解绑 Coordinator
        guard (navigationDriver as AnyObject?) === (driver as AnyObject) else { return } // 不是当前实例则忽略
        navigationDriver = nil // 清空
    }

    func submitAddress() { // 用户提交地址栏
        let raw = addressBar.trimmingCharacters(in: .whitespacesAndNewlines) // 去空白
        guard let url = addressResolver.resolvedURL(forUserInput: raw) else { return } // 解析失败不导航
        navigationDriver?.load(url: url) // 加载
    }

    func goBack() { navigationDriver?.goBack() } // 委托后退
    func goForward() { navigationDriver?.goForward() } // 委托前进

    func reloadOrStop() { // 刷新或停止
        if isLoading { // 若正在加载
            navigationDriver?.stopLoading() // 则停止
        } else { // 否则
            navigationDriver?.reload() // 刷新
        }
    }

    func syncAddressBarFromWebIfNeeded(addressFieldFocused: Bool) { // 加载结束后同步地址栏
        guard !addressFieldFocused else { return } // 用户正在编辑则不覆盖
        let u = locationDisplay // 当前页 URL
        guard u != "about:blank", !u.isEmpty else { return } // 空白页不同步
        addressBar = u // 用网页 URL 覆盖地址栏
    }

    func browserHistoryOnNavigationCompleted(url: String, title: String) { // 主文档完成回调
        guard browsingMode == .normal else { return } // 无痕不写历史
        guard shouldRecordHistoryURL(url) else { return } // 非 http(s) 不记
        normalRecorder.onWebNavigationCompleted(url: url, title: title, favIconUrl: "") // 写入历史
        syncBookmarkTitleWithPage(url: url, title: title) // 同步收藏标题
    }

    func browserHistoryOnTitleChange(url: String, title: String) { // 标题 KVO 回调
        guard browsingMode == .normal else { return } // 无痕不处理
        guard shouldRecordHistoryURL(url) else { return } // 非网页不处理
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url) // 规范化 URL
        if lastTitleObservationKey == norm, lastTitleObservationValue == title { return } // 与上次相同则跳过
        lastTitleObservationKey = norm // 记录键
        lastTitleObservationValue = title // 记录值
        normalRecorder.onTitleUpdated(url: url, title: title, favIconUrl: "") // 更新历史行标题
        syncBookmarkTitleWithPage(url: url, title: title) // 更新收藏标题
    }

    private func syncBookmarkTitleWithPage(url: String, title: String) { // 若已收藏则更新标题显示
        guard browsingMode == .normal else { return } // 无痕不更新收藏
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url) // 规范化
        guard bookmarkEntries.contains(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return } // 未收藏则返回
        let clean = sanitizedBookmarkTitle(title, pageURL: url) // 净化标题
        if !clean.isEmpty { // 有有效标题
            try? bookmarksStore.updateTitleIfBookmarked(pageURL: url, title: clean) // 写回存储
            refreshBookmarksList() // 刷新 Published
        } else { // 仍无有效标题
            tryFillBookmarkTitleViaJS(pageURL: url, retryCount: 0) // JS 再取
        }
    }

    private func sanitizedBookmarkTitle(_ raw: String, pageURL: String) -> String { // 过滤假标题
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines) // 去空白
        if t.isEmpty { return "" } // 空则无效
        if t == pageURL { return "" } // 与完整 URL 相同视为无效
        let nu = URLHistoryNormalize.normalizeUrlForDedup(pageURL) // 页面规范化
        let nt = URLHistoryNormalize.normalizeUrlForDedup(t) // 标题当 URL 规范化
        if nu == nt { return "" } // 与页面同页不同锚点等仍视为无效
        let lower = t.lowercased() // 小写
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return "" } // 整串像 URL 则无效
        return t // 否则可用
    }

    private func tryFillBookmarkTitleViaJS(pageURL: String, retryCount: Int) { // JS 取标题并重试
        guard browsingMode == .normal else { return } // 无痕不执行
        navigationDriver?.fetchDocumentTitle { [weak self] raw in // 异步回调
            Task { @MainActor [weak self] in // 切回主线程
                guard let self else { return } // VM 已释放则结束
                let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL) // 规范化当前页
                guard self.bookmarkEntries.contains(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return } // 收藏已删则结束
                let clean = raw.map { self.sanitizedBookmarkTitle($0, pageURL: pageURL) } ?? "" // 可选绑定净化
                if !clean.isEmpty { // 得到有效标题
                    try? self.bookmarksStore.updateTitleIfBookmarked(pageURL: pageURL, title: clean) // 更新存储
                    self.refreshBookmarksList() // 刷新 UI
                    return // 成功则返回
                }
                if retryCount < 2 { // 最多再试 2 次（共 3 轮）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in // 延迟 0.35 秒
                        guard let self else { return } // 弱引用检查
                        self.tryFillBookmarkTitleViaJS(pageURL: pageURL, retryCount: retryCount + 1) // 递归重试
                    }
                }
            }
        }
    }

    private func shouldRecordHistoryURL(_ url: String) -> Bool { // 是否应记入历史/收藏逻辑
        guard url != "about:blank", !url.isEmpty else { return false } // 空白或空串 false
        guard let u = URL(string: url), let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return false } // 仅 http(s)
        return true // 其它情况 true
    }

    private func applySnapshot(_ snapshot: BrowserNavigationSnapshot) { // 快照写入 Published
        locationDisplay = snapshot.locationDisplay // 展示 URL
        pageTitle = snapshot.pageTitle // 标题
        canGoBack = snapshot.canGoBack // 后退
        canGoForward = snapshot.canGoForward // 前进
    }
}

extension BrowserViewModel: BrowserWebEventSink { // 由 Coordinator 调用
    func handleLoadStarted() { // 导航开始
        isLoading = true // 显示加载中
    }

    func handleLoadCommitted(snapshot: BrowserNavigationSnapshot) { // 已提交导航
        applySnapshot(snapshot) // 更新 UI 状态
    }

    func handleLoadFinished(snapshot: BrowserNavigationSnapshot) { // 主文档加载完
        isLoading = false // 结束加载态
        applySnapshot(snapshot) // 更新 UI
        browserHistoryOnNavigationCompleted(url: snapshot.locationDisplay, title: snapshot.pageTitle) // 写历史等
    }

    func handleLoadFailed(snapshot: BrowserNavigationSnapshot) { // 导航失败
        isLoading = false // 结束加载态
        applySnapshot(snapshot) // 仍更新可见 URL/标题
    }

    func handleEstimatedProgress(_ value: Double) { // 进度变化
        estimatedProgress = value // 绑定进度条
    }
}
