import SwiftUI

/// 收藏夹列表：与明文历史 sheet 交互一致，点进网页、左滑删除、清空。
struct BookmarksSheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.bookmarkEntries.isEmpty {
                    ContentUnavailableView(
                        "暂无收藏",
                        systemImage: "star",
                        description: Text("在底栏点星形按钮可收藏当前网页")
                    )
                } else {
                    List {
                        ForEach(viewModel.bookmarkEntries) { item in
                            Button {
                                viewModel.openBookmarkEntry(item)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title.isEmpty ? "(无标题)" : item.title)
                                        .lineLimit(1)
                                    Text(item.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            viewModel.deleteBookmarkItems(at: indexSet)
                        }
                    }
                }
            }
            .navigationTitle("收藏夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if !viewModel.bookmarkEntries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空", role: .destructive) {
                            viewModel.clearBookmarks()
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.refreshBookmarksList()
            viewModel.tryRefreshBookmarkTitleForCurrentPageIfNeeded()
        }
    }
}
