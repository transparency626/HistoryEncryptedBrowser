// 引入 SwiftUI：声明 App 入口、Scene、WindowGroup 等。
import SwiftUI

// @main：标记这是整个应用的启动点，系统从这里创建进程。
@main
// App 协议：描述应用包含哪些「场景」（通常是一个主窗口）。
struct HistoryEncryptedBrowserApp: App {
    // body 定义根场景结构。
    var body: some Scene {
        // WindowGroup：一组可共存的窗口；iOS 上通常就是一个全屏窗口。
        WindowGroup {
            // 根视图：整个浏览器 UI 从这里开始。
            BrowserView()
        }
    }
}
