import SwiftUI

/// 书籍详情：展示书籍元信息，并提供入口跳转到阅读器。
struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var bookStore: BookStore
    @EnvironmentObject private var sourceStore: BookSourceStore
    @State private var showReader = false
    @State private var exportURL: URL? = nil
    @State private var showExport = false
    @State private var exportMessage: String? = nil
    @State private var showExportMsg = false

    /// 可导出：有本地文件（且非 .doc）
    private var canExport: Bool {
        bookStore.fileURL(for: book) != nil && book.format != .doc
    }

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
            VStack(spacing: 10) {
                if canRead {
                    Button {
                        showReader = true
                    } label: {
                        Label("开始阅读", systemImage: "book.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    if book.format == .doc {
                        Text("该书籍格式（.doc）暂不支持，请另存为 .docx 或 .txt 后导入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("该书籍暂不支持阅读")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if canExport {
                    Button {
                        exportBook()
                    } label: {
                        Label("导出 TXT", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationDestination(isPresented: $showReader) {
            BookReaderView(book: book)
        }
        .sheet(isPresented: $showExport) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
        }
        .alert("提示", isPresented: $showExportMsg) {
            Button("好") { showExportMsg = false }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    /// 可阅读条件：有本地文件（且非 .doc，二进制格式暂不支持），或已关联书源与书籍 URL
    private var canRead: Bool {
        (bookStore.fileURL(for: book) != nil && book.format != .doc) || book.supportsRuleReading
    }

    private func exportBook() {
        guard let url = bookStore.fileURL(for: book) else {
            exportMessage = "该书没有本地文件，无法导出"
            showExportMsg = true
            return
        }
        Task {
            do {
                let text = try await BookExporter.exportText(book: book, fileURL: url)
                let tmp = BookExporter.writeTxtFile(named: book.title, text: text)
                await MainActor.run {
                    exportURL = tmp
                    showExport = true
                }
            } catch {
                await MainActor.run {
                    exportMessage = "导出失败：\(error.localizedDescription)"
                    showExportMsg = true
                }
            }
        }
    }
}