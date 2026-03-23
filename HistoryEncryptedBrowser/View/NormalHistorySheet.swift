// SwiftUI：列表、导航、模态展示。
import SwiftUI

/// 「普通浏览」下的明文历史列表：从磁盘读、展示、点进、删、清空。
struct NormalHistorySheet: View {
    // 与 BrowserView 共用 ViewModel，读 normalHistoryEntries、调刷新/删除。
    @ObservedObject var viewModel: BrowserViewModel
    // 关闭当前 sheet 的环境闭包。
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   //提供标题栏、toolbar，可内嵌导航
            Group {   //本身不产生视觉，只是包住 if/else 多个分支。
                // 没有任何记录：不显示空 List，用系统占位更友好。
                if viewModel.normalHistoryEntries.isEmpty { 
                    ContentUnavailableView(
                        "暂无浏览记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("在「普通」模式下访问的网页会出现在这里")
                    )
                } else {
                    List {
                        // 每条历史一行；NormalHistoryEntry 符合 Identifiable。
                        ForEach(viewModel.normalHistoryEntries) { item in
                            Button {
                                // 主界面地址栏 + WebView 导航到该 URL。
                                viewModel.openNormalHistoryEntry(item)
                                // 关掉 sheet 让用户直接看网页。
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    // 标题过长单行省略。
                                    Text(item.title.isEmpty ? "(无标题)" : item.title)
                                        .lineLimit(1)
                                    // URL 用小字次要色。
                                    Text(item.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        // iOS 标准左滑删除；indexSet 对应 ForEach 的行号。
                        .onDelete { indexSet in
                            viewModel.deleteNormalHistoryItems(at: indexSet)
                        }
                    }
                }
            }
            .navigationTitle("浏览历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                // 有数据才显示「清空」，避免空列表时多余按钮。
                if !viewModel.normalHistoryEntries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        // destructive：系统可能用红色强调危险操作。
                        Button("清空", role: .destructive) {
                            viewModel.clearNormalHistory()
                        }
                    }
                }
            }
        }
        // sheet 每次呈现时拉一次磁盘，保证和后台写入同步。
        .onAppear {
            viewModel.refreshNormalHistoryList()
        }
    }
}
