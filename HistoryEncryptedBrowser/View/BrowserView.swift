import SwiftUI

/// View 层：只负责展示与交互绑定，不包含地址解析或 WebKit 细节。
struct BrowserView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = BrowserViewModel()
    @FocusState private var addressFocused: Bool
    @State private var showNormalHistory = false
    @State private var showVaultHistory = false

    private var showsWelcome: Bool {
        let u = viewModel.locationDisplay
        let isBlankPage = u == "about:blank" || u.isEmpty
        return isBlankPage && !viewModel.isLoading
    }

    private var shareURL: URL? {
        let u = viewModel.locationDisplay
        guard u != "about:blank", !u.isEmpty, let url = URL(string: u) else { return nil }
        return url
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                addressChrome
                browsingModePicker

                ZStack {
                    BrowserWebView(viewModel: viewModel)
                        .id(viewModel.browsingMode)

                    if showsWelcome {
                        welcomeOverlay
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                progressBar
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomToolbar
        }
        .onChange(of: viewModel.isLoading) { _, loading in
            if !loading {
                viewModel.syncAddressBarFromWebIfNeeded(addressFieldFocused: addressFocused)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 离开前台即锁定保险库（含切应用、上滑回主屏幕、多任务界面），避免回到前台仍显示解密列表。
            if phase != .active {
                viewModel.lockVault()
            }
        }
        .sheet(isPresented: $showNormalHistory) {
            NormalHistorySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showVaultHistory) {
            VaultHistorySheet(viewModel: viewModel)
        }
    }

    private var addressChrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.locationDisplay.lowercased().hasPrefix("https:") ? "lock.fill" : "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("搜索或输入网址", text: $viewModel.addressBar)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit { viewModel.submitAddress() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )

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
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var browsingModePicker: some View {
        Picker("", selection: Binding(
            get: { viewModel.browsingMode },
            set: { viewModel.setBrowsingMode($0) }
        )) {
            ForEach(BrowsingMode.allCases) { mode in
                Text(mode.shortTitle).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.accentColor.opacity(0.35))
                .frame(width: geo.size.width * CGFloat(min(max(viewModel.estimatedProgress, 0), 1)), height: 2)
                .animation(.easeInOut(duration: 0.2), value: viewModel.estimatedProgress)
        }
        .frame(height: 2)
        .opacity(viewModel.isLoading && viewModel.estimatedProgress < 1 ? 1 : 0)
    }

    private var welcomeOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: viewModel.browsingMode == .incognito ? "eye.slash.fill" : "globe.americas.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)
            Text(viewModel.browsingMode == .incognito ? "无痕浏览" : "普通浏览")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(
                viewModel.browsingMode == .incognito
                    ? "不持久保存 Cookie 与站点数据；访问记录可加密写入保险库（底部锁图标，需先设密码）。"
                    : "站点数据会持久保存；浏览历史为明文列表（底部时钟图标），与无痕加密库互不混用。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 40)
    }

    private var bottomToolbar: some View {
        HStack {
            toolbarButton("chevron.backward", enabled: viewModel.canGoBack) {
                viewModel.goBack()
            }
            toolbarButton("chevron.forward", enabled: viewModel.canGoForward) {
                viewModel.goForward()
            }
            Spacer(minLength: 0)
            if viewModel.browsingMode == .normal {
                Button {
                    showNormalHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("浏览历史")
            } else {
                Button {
                    showVaultHistory = true
                } label: {
                    Image(systemName: "lock.rectangle.stack")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("无痕加密历史")
            }

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
        .background(.ultraThinMaterial)
    }

    private func toolbarButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

#Preview {
    BrowserView()
}
