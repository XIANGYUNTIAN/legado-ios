import SwiftUI
import Foundation

struct SourceListView: View {
    @EnvironmentObject private var store: BookSourceStore
    @State private var showImport = false
    @State private var showScan = false
    @State private var showExport = false

    // 本地文件导入结果提示
    @State private var importResult: String?

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
                        // 加号「+」展开菜单：粘贴/网址导入 + 本地文件导入（合并原独立 folder 入口）
                        Menu {
                            Button {
                                showImport = true
                            } label: {
                                Label("粘贴 / 网址导入", systemImage: "doc.on.clipboard")
                            }
                            Button {
                                DocumentImporter.present(
                                    onPick: { url in
                                        Task { await importFromLocalFile(url) }
                                    },
                                    onCancel: { }
                                )
                            } label: {
                                Label("从文件导入", systemImage: "folder")
                            }
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
        .alert("书源导入", isPresented: Binding(
            get: { importResult != nil },
            set: { if !$0 { importResult = nil } }
        )) {
            Button("好") { importResult = nil }
        } message: {
            Text(importResult ?? "")
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

    // MARK: - 本地文件导入

    private func importFromLocalFile(_ url: URL) async {
        do {
            let text = try readSourceFileText(from: url)
            let count = try await store.importSources(from: text)
            importResult = count > 0
                ? "成功导入 \(count) 个书源"
                : "未解析到有效书源（请确认是 legado 格式书源 JSON）"
        } catch {
            importResult = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 读取本地书源文件文本，按 UTF-8 → UTF-16 → GB18030 顺序尝试解码，
    /// 兼容中文书源常见的 GBK/GB18030 编码文件。
    private func readSourceFileText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let candidates: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        for enc in candidates {
            if let s = String(data: data, encoding: enc),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return s
            }
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let s = String(data: data, encoding: gb18030),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        throw NSError(
            domain: "SourceImport",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "文件编码无法识别（需 UTF-8 / UTF-16 / GB18030）"]
        )
    }
}
