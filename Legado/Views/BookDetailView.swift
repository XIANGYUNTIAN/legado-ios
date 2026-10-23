import SwiftUI

/// 书籍详情（阅读器将在后续版本开放）
struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var bookStore: BookStore

    var body: some View {
        List {
            LabeledContent("书名", value: book.title)
            LabeledContent("作者", value: book.author)
            LabeledContent("格式", value: book.format.rawValue.uppercased())
            if let size = book.fileSize {
                LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let p = book.fileRelativePath {
                LabeledContent("本地文件", value: p)
            }
            if let u = book.remoteURL {
                LabeledContent("来源链接", value: u)
            }
        }
        .navigationTitle(book.title)
        .safeAreaInset(edge: .bottom) {
            if bookStore.fileURL(for: book) != nil {
                Text("阅读器将于后续版本开放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.bar)
            }
        }
    }
}
