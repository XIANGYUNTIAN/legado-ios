import SwiftUI

struct BookshelfView: View {
    var body: some View {
        List {
            Section {
                Label("导入本地书籍（TXT / EPUB）", systemImage: "square.and.arrow.down.on.square")
                Label("WebDav 远程书籍", systemImage: "externaldrive.connected.to.line.below")
                Label("URL 添加书籍", systemImage: "link")
            } header: {
                Text("添加书籍")
            } footer: {
                Text("P1 阶段开放：本地书籍解析与阅读器就绪后启用。当前可先在「书源」页导入 legado 书源 JSON。")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("书架")
    }
}
