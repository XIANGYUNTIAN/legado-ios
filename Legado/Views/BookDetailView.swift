import SwiftUI

/// 书籍详情：展示书籍元信息，并提供入口跳转到阅读器。
struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var bookStore: BookStore
    @EnvironmentObject private var sourceStore: BookSourceStore
    @State private var showReader = false

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
            if book.supportsRuleReading {
                LabeledContent("阅读方式", value: "书源规则阅读")
            }
        }
        .navigationTitle(book.title)
        .safeAreaInset(edge: .bottom) {
            if canRead {
                Button {
                    showReader = true
                } label: {
                    Label("开始阅读", systemImage: "book.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            } else {
                Text("该书籍暂不支持阅读")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(.bar)
            }
        }
        .navigationDestination(isPresented: $showReader) {
            BookReaderView(book: book)
        }
    }

    /// 可阅读条件：有本地文件，或已关联书源与书籍 URL
    private var canRead: Bool {
        bookStore.fileURL(for: book) != nil || book.supportsRuleReading
    }
}