import SwiftUI

// MARK: - 浏览历史（仅普通模式有数据）

struct NormalHistorySheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.normalHistoryEntries.isEmpty {
                    ContentUnavailableView(
                        "暂无浏览记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("在「普通」模式下访问的网页会出现在这里")
                    )
                } else {
                    List {
                        ForEach(viewModel.normalHistoryEntries) { item in
                            Button {
                                viewModel.openNormalHistoryEntry(item)
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
                if !viewModel.normalHistoryEntries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空", role: .destructive) {
                            viewModel.clearNormalHistory()
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.refreshNormalHistoryList()
        }
    }
}

// MARK: - 收藏夹

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
