// SwiftUI：声明式 UI、View、@State、sheet 等。
import SwiftUI

/// 主界面：地址栏、模式切换、Web、底栏；不出现 WKWebView 类型名。
struct BrowserView: View {
    // StateObject：ViewModel 只创建一次，和本 View 同生命周期；用 ObjectWillChange 驱动刷新。
    @StateObject private var viewModel = BrowserViewModel()
    // FocusState：跟踪地址栏是否在编辑；加载完成时若未聚焦才把网页 URL 写回地址栏。
    @FocusState private var addressFocused: Bool
    // 控制「浏览历史」半屏是否弹出（仅普通模式使用）。
    @State private var showNormalHistory = false
    // 控制「收藏夹」列表 sheet。
    @State private var showBookmarks = false

    /// 是否在 Web 区域上叠一层欢迎文案（空白页且没在转圈时）。
    private var showsWelcome: Bool {
        // 当前展示用 URL（来自 ViewModel 快照，不一定等于 TextField 里的字）。
        let u = viewModel.locationDisplay
        // 认为是空白：显式 about:blank 或空字符串。
        let isBlankPage = u == "about:blank" || u.isEmpty
        // 空白且不在加载：显示叠层；加载中不挡用户看进度。
        return isBlankPage && !viewModel.isLoading
    }

    /// 底栏「分享」用的 URL：无效页面返回 nil，外面用 if let 隐藏按钮。
    private var shareURL: URL? {
        let u = viewModel.locationDisplay
        // 空白不能分享；URL(string:) 失败也视为不能分享。
        guard u != "about:blank", !u.isEmpty, let url = URL(string: u) else { return nil }
        return url
    }

    /// 无痕时外壳用深色（与 Safari 私密大致一致）；普通模式跟系统。
    private var chromeRootBackground: Color {
        if viewModel.browsingMode == .incognito {
            return Color(red: 0.07, green: 0.08, blue: 0.10)
        }
        return Color(.systemGroupedBackground)
    }

    var body: some View {
        // ZStack：下层背景、上层主内容叠在一起。
        ZStack {
            // 铺满含刘海；无痕为深灰底。
            chromeRootBackground
                .ignoresSafeArea()

            // 垂直排列：地址栏 → 模式切换 → Web 区域 → 进度条。
            VStack(spacing: 0) {
                addressChrome
                browsingModePicker

                // Web 和欢迎叠层叠在同一矩形里，再统一圆角裁剪。
                ZStack {
                    // BrowserWebView 是 UIViewRepresentable，里面才是真 WKWebView。
                    BrowserWebView(viewModel: viewModel)
                        // id 随 browsingMode 变：SwiftUI 会拆掉旧 WebView、造新的，从而换 DataStore。
                        .id(viewModel.browsingMode)

                    // 条件视图：只有 showsWelcome 为 true 才构造 welcomeOverlay。
                    if showsWelcome {
                        welcomeOverlay
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(viewModel.browsingMode == .incognito ? chromeRootBackground : Color.clear)
                            // 叠层不参与点击，手势交给下层 WebView（空白页时意义不大，但习惯上避免挡交互）。
                            .allowsHitTesting(false)
                    }
                }
                // 连续圆角矩形；无痕时加淡描边，区分「外壳深色」与网页亮内容区。
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            viewModel.browsingMode == .incognito ? Color.white.opacity(0.12) : Color.clear,
                            lineWidth: 1
                        )
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                progressBar
            }
        }
        // 底栏浮在安全区内侧，不占 VStack 高度，主内容自动让出底部空间。
        .safeAreaInset(edge: .bottom) {
            bottomToolbar
        }
        // 加载状态从 true 变 false：一次导航结束。
        .onChange(of: viewModel.isLoading) { _, loading in
            // 仅在「刚结束加载」时考虑同步地址栏。
            if !loading {
                // 用户正在敲地址时不覆盖，避免打断输入。
                viewModel.syncAddressBarFromWebIfNeeded(addressFieldFocused: addressFocused)
            }
        }
        // 第一个 sheet：绑定到 showNormalHistory，为 true 时以模态呈现。
        .sheet(isPresented: $showNormalHistory) {
            // 传入同一个 viewModel，列表和浏览器共享数据。
            NormalHistorySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksSheet(viewModel: viewModel)
        }
        // 无痕：状态栏、地址栏、分段、底栏等走暗黑语义色；网页本身由 WKWebView.overrideUserInterfaceStyle = .light 保持浅色结果页。
        .preferredColorScheme(viewModel.browsingMode == .incognito ? .dark : nil)
    }

    /// 顶部一行：左侧输入区 + 右侧「前往」。
    private var addressChrome: some View {
        // HStack：子视图横向排，spacing 为默认间隙。
        HStack(spacing: 10) {
            // 左侧圆角框里的图标 + 输入框。
            HStack(spacing: 8) {
                // SF Symbol：HTTPS 给锁图标，否则地球，给用户一点安全提示。
                Image(systemName: viewModel.locationDisplay.lowercased().hasPrefix("https:") ? "lock.fill" : "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                // 双绑到 viewModel.addressBar：用户输入会立刻进 ViewModel。
                TextField("搜索或输入网址", text: $viewModel.addressBar)
                    // 不要句首自动大写（域名里常要小写）。
                    .textInputAutocapitalization(.never)
                    // 关自动纠错，避免 URL 被改坏。
                    .autocorrectionDisabled()
                    // URL 键盘带 .com 等快捷键。
                    .keyboardType(.URL)
                    // 键盘回车显示为「前往」。
                    .submitLabel(.go)
                    // 绑定焦点到 addressFocused，供上面 onChange 判断。
                    .focused($addressFocused)
                    // 软键盘上点「前往」等同点按钮。
                    .onSubmit { viewModel.submitAddress() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // 浅灰圆角底。
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            // 极淡描边，让块从背景里分出来一点。
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

            // 显式「前往」按钮：先收键盘再导航，体验更明确。
            Button {
                addressFocused = false
                viewModel.submitAddress()
            } label: {
                Text("前往")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            }
            // plain：不画系统默认胶囊背景，用我们 label 里的背景。
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// 分段控件：切换普通 / 无痕；setter 必须走 ViewModel，以便清理去重状态等。
    private var browsingModePicker: some View {
        // Picker 的 selection 要 Binding：读 VM、写时调用 setBrowsingMode。
        Picker("", selection: Binding(
            get: { viewModel.browsingMode },
            set: { viewModel.setBrowsingMode($0) }
        )) {
            // 枚举 CaseIterable + Identifiable，适合 ForEach。
            ForEach(BrowsingMode.allCases) { mode in
                // tag 必须与 selection 类型一致，这里都是 BrowsingMode。
                Text(mode.shortTitle).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// 极细的加载进度条，宽度按 estimatedProgress 比例拉伸。
    private var progressBar: some View {
        // GeometryReader 提供父视图给的宽高；这里用来算条的长度。
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                // 宽度 = 总宽 × 进度，限制在 0～1 防止越界。
                .frame(width: geo.size.width * CGFloat(min(max(viewModel.estimatedProgress, 0), 1)), height: 2)
                // 进度变化时略带动画。
                .animation(.easeInOut(duration: 0.2), value: viewModel.estimatedProgress)
        }
        .frame(height: 2)
        // 不在加载或已经 100% 时隐藏，避免一条空线。
        .opacity(viewModel.isLoading && viewModel.estimatedProgress < 1 ? 1 : 0)
    }

    /// 空白页中央提示：文案随当前模式切换。
    private var welcomeOverlay: some View {
        VStack(spacing: 10) {
            // 无痕用「闭眼」图标，普通用地球图标。
            Image(systemName: viewModel.browsingMode == .incognito ? "eye.slash.fill" : "globe.americas.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
            Text(viewModel.browsingMode == .incognito ? "无痕浏览" : "普通浏览")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            // 两段说明文字用三元表达式选其一。
            Text(
                viewModel.browsingMode == .incognito
                    ? "不持久保存 Cookie 与站点数据；关闭 App 后无痕会话内的站点数据会清除。本应用不记录无痕浏览历史。"
                    : "站点数据会持久保存；可使用浏览历史与收藏夹（均为保存在本机的明文数据）。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 40)
    }

    /// 底部工具条：导航 + 历史入口 + 刷新 + 分享。
    private var bottomToolbar: some View {
        HStack {
            // 后退：无历史时 disabled + 半透明。
            toolbarButton("chevron.backward", enabled: viewModel.canGoBack) {
                viewModel.goBack()
            }
            toolbarButton("chevron.forward", enabled: viewModel.canGoForward) {
                viewModel.goForward()
            }
            // 把中间留白，让两侧按钮靠边、中间图标居中。
            Spacer(minLength: 0)
            // 普通模式：打开明文历史 sheet。
            if viewModel.browsingMode == .normal {
                Button {
                    showNormalHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.body.weight(.semibold))
                        // 固定点击区域 44pt，符合人机指南最小触控。
                        .frame(width: 44, height: 44)
                        // 让整个方框可点，不仅图标像素。
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("浏览历史")
            } else {
                // 无痕模式不保存历史：占位与「时钟」同宽，保持底栏对齐。
                Image(systemName: "eye.slash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("无痕模式不记录浏览历史")
            }

            // 星标：当前为 http(s) 页时可点；已收藏为实心星，再点取消收藏。
            Button {
                viewModel.toggleBookmarkForCurrentPage()
            } label: {
                Image(systemName: viewModel.isCurrentPageBookmarked ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(shareURL == nil || viewModel.browsingMode == .incognito)
            .opacity((shareURL == nil || viewModel.browsingMode == .incognito) ? 0.35 : 1)
            .accessibilityLabel(viewModel.isCurrentPageBookmarked ? "取消收藏" : "收藏本页")

            // 收藏夹：无痕模式下仍可打开列表并跳转，但不会新增收藏。
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "book.closed")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收藏夹")

            // 加载中显示停止，否则显示刷新。
            Button {
                viewModel.reloadOrStop()
            } label: {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isLoading ? "停止加载" : "刷新")

            // 有合法 URL 才显示系统分享；否则用透明占位保持布局不乱。
            if let url = shareURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // 毛玻璃材质，底栏与内容有层次区分。
        .background(.ultraThinMaterial)
    }

    /// 统一风格的工具栏图标按钮，避免重复写 modifier。
    private func toolbarButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 不可点时禁用点击。
        .disabled(!enabled)
        // 不可点时视觉上变淡，提示不可用。
        .opacity(enabled ? 1 : 0.35)
    }
}

// Xcode 画布预览用，运行时不会自动执行。
#Preview {
    BrowserView()
}
