// SwiftUI：Form、NavigationStack、sheet 内 UI。
import SwiftUI

/// 无痕模式下的「加密保险库」半屏：根据状态显示建库 / 解锁 / 列表。
struct VaultHistorySheet: View {
    // 与父视图共享同一个 BrowserViewModel，读 vault 状态、调异步方法。
    @ObservedObject var viewModel: BrowserViewModel
    // dismiss 是环境值：调用即关闭当前 sheet。
    @Environment(\.dismiss) private var dismiss

    // MARK: - 仅本 sheet 需要的临时状态（不必放进 ViewModel）

    // 创建保险库时第一次输入的密码。
    @State private var setPassword1 = ""
    // 创建保险库时第二次输入，用于确认一致。
    @State private var setPassword2 = ""
    // 解锁时输入的密码。
    @State private var unlockPassword = ""
    // 校验失败或解锁失败时给用户看的红字。
    @State private var errorMessage = ""
    // true 时按钮禁用并显示转圈，防止连点触发多次 Task。
    @State private var isBusy = false

    var body: some View {
        // NavigationStack：提供标题栏、toolbar，可内嵌导航（本页未用 push）。
        NavigationStack {
            // Group 本身不产生视觉，只是包住 if/else 多个分支。
            Group {
                // 磁盘上还没有 meta：走首次建库流程。
                if viewModel.vaultNeedsPasswordSetup {
                    setupForm
                } else if !viewModel.vaultUnlocked {
                    // 有 meta 但内存里没私钥：显示解锁表单。
                    unlockForm
                } else {
                    // 已解锁：显示解密后的列表。
                    unlockedList
                }
            }
            // 导航栏大标题。
            .navigationTitle("无痕加密历史")
            // inline：标题缩小顶栏中间，适合 sheet。
            .navigationBarTitleDisplayMode(.inline)
            // vaultUnlocked 从 true 变 false（用户点锁定或 App 进后台）：清敏感输入。
            .onChange(of: viewModel.vaultUnlocked) { _, unlocked in
                if !unlocked {
                    unlockPassword = ""
                    errorMessage = ""
                }
            }
            .toolbar {
                // 左上角关闭，只关 sheet 不关 App。
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                // 只有解锁后才显示「锁定」，手动清内存私钥。
                if viewModel.vaultUnlocked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("锁定") {
                            viewModel.lockVault()
                        }
                    }
                }
            }
        }
    }

    /// 第一次使用：说明文字 + 密码规则 + 提交按钮。
    private var setupForm: some View {
        Form {
            // Section 把内容分组，带系统分组样式。
            Section {
                Text("设置保险库密码后，才会开始记录无痕访问（与扩展一致：无公钥则不写入）。密码用于加密 RSA 私钥；记录为 RSA + AES-GCM。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Section 标题作为 header。
            Section("新密码（8～16 位）") {
                // SecureField：输入不可见，适合密码。
                SecureField("密码", text: $setPassword1)
                SecureField("再次输入", text: $setPassword2)
            }
            Section {
                Text("须同时包含：数字、大写、小写字母、符号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 有错误才插入一块红字，避免空白 Section。
            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            Section {
                Button {
                    // Task 里 await 异步，不阻塞 UI 线程点击响应。
                    Task { await runSetup() }
                } label: {
                    HStack {
                        // 忙碌时左侧小菊花。
                        if isBusy { ProgressView() }
                        Text("创建保险库")
                    }
                }
                // 进行中禁止重复点。
                .disabled(isBusy)
            }
        }
    }

    /// 已有保险库：输入密码解锁。
    private var unlockForm: some View {
        Form {
            Section {
                SecureField("保险库密码", text: $unlockPassword)
                    // 系统可建议钥匙串里的密码（若用户存过）。
                    .textContentType(.password)
            }
            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            Section {
                Button {
                    Task { await runUnlock() }
                } label: {
                    HStack {
                        if isBusy { ProgressView() }
                        Text("解锁")
                    }
                }
                .disabled(isBusy)
            }
        }
    }

    /// 解锁成功：展示 vaultListItems；空则占位图。
    private var unlockedList: some View {
        Group {
            if viewModel.vaultListItems.isEmpty {
                // 系统标准「无内容」样式，带图标和说明。
                ContentUnavailableView(
                    "暂无加密记录",
                    systemImage: "lock.doc",
                    description: Text("成功加载的网页会写入加密保险库")
                )
            } else {
                List {
                    // Identifiable 的数组直接 ForEach。
                    ForEach(viewModel.vaultListItems) { item in
                        Button {
                            // 让主 WebView 打开该条 URL，并关掉 sheet。
                            viewModel.openVaultEntry(item)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.payload.title.isEmpty ? "(无标题)" : item.payload.title)
                                    .lineLimit(1)
                                Text(item.payload.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    // 左滑删除：indexSet 是用户在列表里选中的行索引。
                    .onDelete { indexSet in
                        viewModel.deleteVaultListItems(at: indexSet)
                    }
                }
            }
        }
        // 列表非空时右上角「清空」全部加密记录。
        .toolbar {
            if viewModel.vaultUnlocked, !viewModel.vaultListItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空", role: .destructive) {
                        viewModel.clearVaultRecords()
                    }
                }
            }
        }
    }

    /// 异步创建保险库：VM 里会做 PBKDF2+RSA，耗时长。
    @MainActor
    private func runSetup() async {
        // 新一轮提交先清旧错误。
        errorMessage = ""
        isBusy = true
        // defer：函数任意 return 都会执行，保证 isBusy 复位。
        defer { isBusy = false }
        do {
            // 成功则 VM 更新 vaultMetaPresent、reload 公钥等。
            try await viewModel.validateAndSetVaultPassword(setPassword1, setPassword2)
            // 成功后清密码，减少留在内存里的时间（仍可能被系统快照，主要靠锁库）。
            setPassword1 = ""
            setPassword2 = ""
        } catch let e as VaultSetupValidationError {
            // 规则错误：用我们自定义的中文 message。
            errorMessage = e.message
        } catch {
            // 其它错误：用系统 localizedDescription。
            errorMessage = error.localizedDescription
        }
    }

    /// 异步解锁：密码错会 throw，catch 里统一显示「密码错误」。
    @MainActor
    private func runUnlock() async {
        errorMessage = ""
        isBusy = true
        defer { isBusy = false }
        do {
            try await viewModel.unlockVault(password: unlockPassword)
            unlockPassword = ""
        } catch {
            // 不区分具体错误类型，避免向用户泄露细节。
            errorMessage = "密码错误"
        }
    }
}
