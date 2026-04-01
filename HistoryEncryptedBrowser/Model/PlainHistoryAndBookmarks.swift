import Foundation // 文件、JSON、Codable、时间戳

// MARK: - 明文历史

/// 磁盘上一条普通浏览历史记录的结构。
struct NormalHistoryEntry: Codable, Equatable, Identifiable, Sendable { // Codable 编解码，Identifiable 供 ForEach
    var id: Int64 // 行主键，自增
    var url: String // 页面 URL
    var title: String // 页面标题
    var time: Int64 // 访问时间，毫秒时间戳
    var favIconUrl: String // 站点图标 URL，可空串
}

/// 读写 normal_browsing_history.json，主线程隔离避免并发写。
@MainActor // 所有方法在主线程执行
final class PlainHistoryStore { // 引用类型，无继承
    private let fileURL: URL // JSON 文件绝对路径
    private let encoder: JSONEncoder // 序列化用
    private let decoder: JSONDecoder // 反序列化用

    init(directory: URL? = nil) { // directory 为 nil 时用默认沙盒目录
        let base = directory // 若调用方指定根目录
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first // 否则 Application Support
            ?? FileManager.default.temporaryDirectory // 再否则临时目录
        let dir = base.appendingPathComponent("HistoryEncryptedBrowser", isDirectory: true) // 应用子目录名
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // 创建目录，失败忽略
        fileURL = dir.appendingPathComponent("normal_browsing_history.json", isDirectory: false) // 历史文件名
        encoder = JSONEncoder() // 新建编码器
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // 可读 JSON
        decoder = JSONDecoder() // 新建解码器
    }

    func loadAllSortedNewestFirst() -> [NormalHistoryEntry] { // 读盘并排序
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] } // 无文件则空数组
        guard let data = try? Data(contentsOf: fileURL) else { return [] } // 读数据失败则空数组
        let rows = (try? decoder.decode([NormalHistoryEntry].self, from: data)) ?? [] // 解码失败当空数组
        return rows.sorted { $0.time > $1.time } // 按时间降序，新的在前
    }

    func addRecord(url: String, title: String, favIconUrl: String, time: Int64) throws -> Int64 { // 追加一行并落盘
        var rows = loadAllSortedNewestFirst() // 先读出当前全部
        let next = (rows.map(\.id).max() ?? 0) + 1 // 新 id = 最大 id + 1，无则 1
        rows.append(NormalHistoryEntry(id: next, url: url, title: title, time: time, favIconUrl: favIconUrl)) // 追加结构体
        try saveAll(rows) // 整体写回
        return next // 返回新行 id
    }

    func deleteRecord(id: Int64) throws { // 按 id 删一条
        var rows = loadAllSortedNewestFirst() // 读出全部
        rows.removeAll { $0.id == id } // 过滤掉目标 id
        try saveAll(rows) // 写回
    }

    func clearAll() throws { // 清空列表
        try saveAll([]) // 写空数组
    }

    private func saveAll(_ rows: [NormalHistoryEntry]) throws { // 私有：统一写文件逻辑
        let data = try encoder.encode(rows) // 编码为 Data
        let tmp = fileURL.appendingPathExtension("tmp") // 临时文件路径 *.json.tmp
        try data.write(to: tmp, options: .atomic) // 原子写到临时文件
        if FileManager.default.fileExists(atPath: fileURL.path) { // 若正式文件已存在
            try FileManager.default.removeItem(at: fileURL) // 先删旧文件
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL) // 临时文件改名为正式文件
    }
}

// MARK: - 收藏夹

/// 磁盘上一条收藏记录的结构。
struct BookmarkEntry: Codable, Equatable, Identifiable, Sendable { // 与历史条目字段平行
    var id: Int64 // 主键
    var url: String // 收藏时的 URL
    var title: String // 标题
    var time: Int64 // 时间毫秒
    var favIconUrl: String // 图标 URL
}

/// 读写 bookmarks.json。
@MainActor // 主线程
final class BookmarksStore { // 收藏存储类
    private let fileURL: URL // 书签文件路径
    private let encoder: JSONEncoder // 编码器
    private let decoder: JSONDecoder // 解码器

    init(directory: URL? = nil) { // 与历史共用目录策略
        let base = directory // 可选根
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first // Application Support
            ?? FileManager.default.temporaryDirectory // 临时目录兜底
        let dir = base.appendingPathComponent("HistoryEncryptedBrowser", isDirectory: true) // 子目录
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) // 确保目录存在
        fileURL = dir.appendingPathComponent("bookmarks.json", isDirectory: false) // 书签文件名
        encoder = JSONEncoder() // 编码器实例
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys] // 可读输出
        decoder = JSONDecoder() // 解码器实例
    }

    func loadAllSortedNewestFirst() -> [BookmarkEntry] { // 读全部收藏并排序
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] } // 无文件返回空
        guard let data = try? Data(contentsOf: fileURL) else { return [] } // 读失败返回空
        let rows = (try? decoder.decode([BookmarkEntry].self, from: data)) ?? [] // 解码
        return rows.sorted { $0.time > $1.time } // 按时间新到旧
    }

    func updateTitleIfBookmarked(pageURL: String, title: String) throws { // 已收藏则只更新标题与 url 字符串
        let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL) // 当前页规范化键
        var rows = loadAllSortedNewestFirst() // 全部行
        guard let idx = rows.firstIndex(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) else { return } // 找不到则返回
        rows[idx].url = pageURL // 更新为当前 URL 字符串
        rows[idx].title = title // 更新标题
        try saveAll(rows) // 落盘
    }

    func upsert(url: String, title: String, favIconUrl: String, time: Int64) throws { // 有则更新无则插入
        var rows = loadAllSortedNewestFirst() // 当前全部
        let norm = URLHistoryNormalize.normalizeUrlForDedup(url) // 规范化键
        if let idx = rows.firstIndex(where: { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm }) { // 找到同站
            rows[idx].url = url // 写回 url
            rows[idx].title = title // 写标题
            rows[idx].time = time // 更新时间
            rows[idx].favIconUrl = favIconUrl // 更新图标字段
        } else { // 没有则新增
            let next = (rows.map(\.id).max() ?? 0) + 1 // 新 id
            rows.append(BookmarkEntry(id: next, url: url, title: title, time: time, favIconUrl: favIconUrl)) // 追加
        }
        try saveAll(rows) // 保存
    }

    func removeMatchingNormalizedURL(_ pageURL: String) throws { // 取消收藏：按规范化 URL 删
        let norm = URLHistoryNormalize.normalizeUrlForDedup(pageURL) // 规范化
        var rows = loadAllSortedNewestFirst() // 全部
        rows.removeAll { URLHistoryNormalize.normalizeUrlForDedup($0.url) == norm } // 删掉匹配的
        try saveAll(rows) // 保存
    }

    func deleteRecord(id: Int64) throws { // 按主键删除
        var rows = loadAllSortedNewestFirst() // 全部
        rows.removeAll { $0.id == id } // 去掉该 id
        try saveAll(rows) // 保存
    }

    func clearAll() throws { // 清空收藏
        try saveAll([]) // 写空数组
    }

    private func saveAll(_ rows: [BookmarkEntry]) throws { // 原子写书签文件
        let data = try encoder.encode(rows) // 编码
        let tmp = fileURL.appendingPathExtension("tmp") // 临时路径
        try data.write(to: tmp, options: .atomic) // 写临时文件
        if FileManager.default.fileExists(atPath: fileURL.path) { // 旧文件存在
            try FileManager.default.removeItem(at: fileURL) // 删除
        }
        try FileManager.default.moveItem(at: tmp, to: fileURL) // 改名生效
    }
}

// MARK: - 普通模式历史记录器

/// 内存去重 + 防抖后写入 PlainHistoryStore。
@MainActor // 主线程
final class NormalHistoryRecorder { // 记录器类
    private static let debounceMs: Int64 = 4000 // 4 秒内同一键只记一次

    private let store: PlainHistoryStore // 注入的存储
    private var debounceLastAt: [String: Int64] = [:] // 键到上次写入时间
    private var lastUrlByTab: [Int: String] = [:] // tabId 到上次记录的规范化 URL
    private var lastRecordIdByTab: [String: Int64] = [:] // 键到当前页对应历史行 id

    init(store: PlainHistoryStore) { // 初始化
        self.store = store // 保存引用
    }

    func clearMemoryState() { // 清空内存字典，不碰磁盘
        debounceLastAt.removeAll() // 清空防抖表
        lastUrlByTab.removeAll() // 清空 tab 最近 URL
        lastRecordIdByTab.removeAll() // 清空 tab+URL 到行 id 映射
    }

    func onWebNavigationCompleted( // 主文档加载完成时调用
        tabId: Int = 0, // 标签 id，单 WebView 用 0
        url: String, // 当前 URL
        title: String, // 当前标题
        favIconUrl: String = "", // 图标
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) // 当前时间毫秒
    ) {
        guard !url.isEmpty else { return } // 空 URL 不记

        let normalizedUrl = URLHistoryNormalize.normalizeUrlForDedup(url) // 规范化用于去重
        let mapKey = "\(tabId)::\(normalizedUrl)" // 组合键：标签 + 规范化 URL

        if let last = debounceLastAt[mapKey], nowMs - last < Self.debounceMs { return } // 防抖窗口内跳过
        debounceLastAt[mapKey] = nowMs // 记录本次时间

        if lastUrlByTab[tabId] == normalizedUrl { return } // 同一 tab 同一 URL 重复完成不插新行

        guard let newId = try? store.addRecord(url: url, title: title, favIconUrl: favIconUrl, time: nowMs) else { return } // 落盘失败则返回
        lastUrlByTab[tabId] = normalizedUrl // 记录该 tab 当前 URL
        lastRecordIdByTab[mapKey] = newId // 记录该键对应行 id，供标题更新删旧行
    }

    func onTitleUpdated( // 标题变化时：删旧加新
        tabId: Int = 0, // 标签 id
        url: String, // 页面 URL
        title: String, // 新标题
        favIconUrl: String = "", // 图标
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000) // 当前毫秒
    ) {
        let normalizedUrl = URLHistoryNormalize.normalizeUrlForDedup(url) // 规范化
        let mapKey = "\(tabId)::\(normalizedUrl)" // 与上面一致的键
        guard let recordId = lastRecordIdByTab[mapKey] else { return } // 没有对应行 id 则无法更新

        lastRecordIdByTab.removeValue(forKey: mapKey) // 先去掉映射，避免中间状态错乱
        try? store.deleteRecord(id: recordId) // 删除旧行，失败忽略

        guard let newId = try? store.addRecord(url: url, title: title, favIconUrl: favIconUrl, time: nowMs) else { return } // 插入新行
        lastRecordIdByTab[mapKey] = newId // 更新为新行 id
    }
}
