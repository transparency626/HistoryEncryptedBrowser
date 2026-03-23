import SwiftUI

/// 无痕加密历史：原生界面，对应扩展 popup 中「无痕」流程（去掉了扩展管理页 / 权限检测）。
struct VaultHistorySheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var setPassword1 = ""
    @State private var setPassword2 = ""
    @State private var unlockPassword = ""
    @State private var errorMessage = ""
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.vaultNeedsPasswordSetup {
                    setupForm
                } else if !viewModel.vaultUnlocked {
                    unlockForm
                } else {
                    unlockedList
                }
            }
            .navigationTitle("无痕加密历史")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: viewModel.vaultUnlocked) { _, unlocked in
                if !unlocked {
                    unlockPassword = ""
                    errorMessage = ""
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
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

    private var setupForm: some View {
        Form {
            Section {
                Text("设置保险库密码后，才会开始记录无痕访问（与扩展一致：无公钥则不写入）。密码用于加密 RSA 私钥；记录为 RSA + AES-GCM。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("新密码（8～16 位）") {
                SecureField("密码", text: $setPassword1)
                SecureField("再次输入", text: $setPassword2)
            }
            Section {
                Text("须同时包含：数字、大写、小写字母、符号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
            Section {
                Button {
                    Task { await runSetup() }
                } label: {
                    HStack {
                        if isBusy { ProgressView() }
                        Text("创建保险库")
                    }
                }
                .disabled(isBusy)
            }
        }
    }

    private var unlockForm: some View {
        Form {
            Section {
                SecureField("保险库密码", text: $unlockPassword)
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

    private var unlockedList: some View {
        Group {
            if viewModel.vaultListItems.isEmpty {
                ContentUnavailableView(
                    "暂无加密记录",
                    systemImage: "lock.doc",
                    description: Text("成功加载的网页会写入加密保险库")
                )
            } else {
                List {
                    ForEach(viewModel.vaultListItems) { item in
                        Button {
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
                    .onDelete { indexSet in
                        viewModel.deleteVaultListItems(at: indexSet)
                    }
                }
            }
        }
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

    @MainActor
    private func runSetup() async {
        errorMessage = ""
        isBusy = true
        defer { isBusy = false }
        do {
            try await viewModel.validateAndSetVaultPassword(setPassword1, setPassword2)
            setPassword1 = ""
            setPassword2 = ""
        } catch let e as VaultSetupValidationError {
            errorMessage = e.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runUnlock() async {
        errorMessage = ""
        isBusy = true
        defer { isBusy = false }
        do {
            try await viewModel.unlockVault(password: unlockPassword)
            unlockPassword = ""
        } catch {
            errorMessage = "密码错误"
        }
    }
}
