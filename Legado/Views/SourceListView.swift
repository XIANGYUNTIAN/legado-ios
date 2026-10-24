import SwiftUI

struct SourceListView: View {
    @EnvironmentObject private var store: BookSourceStore
    @State private var showImport = false
    @State private var showScan = false

    var body: some View {
        List {
            ForEach(store.sources) { source in
                // 可自动发现的进发现页；exploreUrl 是 JS 规则/不可请求的进详情页，
                // 避免打开已存书源即触发无效网络请求并报 "unsupported URL"
                NavigationLink {
                    if source.hasUsableExploreUrl {
                        SourceExploreView(source: source)
                    } else {
                        SourceDetailView(source: source)
                    }
                } label: {
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
            }
            .onDelete(perform: store.delete)
        }
        .navigationTitle("书源（\(store.sources.count)）")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
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
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportSourceView()
        }
        .sheet(isPresented: $showScan) {
            QRSourceScanSheet()
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
}
