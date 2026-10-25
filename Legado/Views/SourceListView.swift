import SwiftUI

struct SourceListView: View {
    @EnvironmentObject private var store: BookSourceStore
    @State private var showImport = false
    @State private var showScan = false
    @State private var showExport = false

    // 批量选择模式
    @State private var isSelecting = false
    @State private var selection = Set<String>()   // 存 bookSourceUrl
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            ForEach(store.sources) { source in
                if isSelecting {
                    selectableRow(source)
                } else {
                    // 可自动发现的进发现页；exploreUrl 是 JS 规则/不可请求的进详情页，
                    // 避免打开已存书源即触发无效网络请求并报 "unsupported URL"
                    NavigationLink {
                        if source.hasUsableExploreUrl {
                            SourceExploreView(source: source)
                        } else {
                            SourceDetailView(source: source)
                        }
                    } label: {
                        rowLabel(source)
                    }
                }
            }
            .onDelete(perform: store.delete)
        }
        .navigationTitle("书源（\(store.sources.count)）")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    Button("取消") { exitSelecting() }
                } else {
                    EditButton()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if isSelecting {
                        Button {
                            toggleSelectAll()
                        } label: {
                            Text(selection.count == store.sources.count ? "取消全选" : "全选")
                        }
                        Button {
                            showDeleteConfirm = true
                        } label: {
                            Text("删除（\(selection.count)）")
                                .foregroundStyle(.red)
                        }
                        .disabled(selection.isEmpty)
                    } else {
                        Button {
                            showScan = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                        }
                        Button {
                            showImport = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button {
                            showExport = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(store.sources.isEmpty)
                        Button {
                            isSelecting = true
                            selection = []
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSourceView()
        }
        .sheet(isPresented: $showScan) {
            QRSourceScanSheet()
        }
        .sheet(isPresented: $showExport) {
            SourceExportSheet(sources: store.sources)
        }
        .confirmationDialog("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除 \(selection.count) 个书源", role: .destructive) {
                store.delete(ids: Array(selection))
                exitSelecting()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将永久删除选中的 \(selection.count) 个书源，且不可恢复。")
        }
        .overlay {
            if store.sources.isEmpty {
                ContentUnavailableView(
                    "暂无书源",
                    systemImage: "server.rack",
                    description: Text("点击右上角 + 导入 legado 格式书源 JSON")
                )
            }
        }
    }

    // MARK: - 行视图

    private func rowLabel(_ source: BookSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName)
                    .font(.body)
                    .foregroundStyle(source.enabled ? Color.primary : Color.secondary)
                Text(source.bookSourceGroup ?? "未分组")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(source.typeName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
        }
    }

    private func selectableRow(_ source: BookSource) -> some View {
        let selected = selection.contains(source.bookSourceUrl)
        return HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .font(.title3)
            rowLabel(source)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(source) }
    }

    // MARK: - 选择逻辑

    private func toggle(_ source: BookSource) {
        let id = source.bookSourceUrl
        if selection.contains(id) { selection.remove(id) }
        else { selection.insert(id) }
    }

    private func toggleSelectAll() {
        if selection.count == store.sources.count {
            selection = []
        } else {
            selection = Set(store.sources.map { $0.bookSourceUrl })
        }
    }

    private func exitSelecting() {
        isSelecting = false
        selection = []
    }
}
