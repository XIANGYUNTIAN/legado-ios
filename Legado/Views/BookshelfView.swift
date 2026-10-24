import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {
    @EnvironmentObject private var bookStore: BookStore

    @State private var showDocPicker = false
    @State private var showURLSheet = false
    @State private var showSearch = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showMsg = false

    var body: some View {
        List {
            ForEach(bookStore.books) { book in
                NavigationLink {
                    BookDetailView(book: book)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: book.format == .epub ? "book.closed.fill" : "doc.text.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(book.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(book.format.rawValue.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }
            }
            .onDelete(perform: bookStore.delete)
        }
        .navigationTitle("书架（\(bookStore.books.count)）")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showDocPicker = true
                    } label: {
                        Label("本地导入书籍（TXT / EPUB）", systemImage: "square.and.arrow.down.on.square")
                    }
                    Button {
                        showURLSheet = true
                    } label: {
                        Label("URL 添加书籍", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        // 本地导入：内容类型用 .data 兜底——书籍文件常无扩展名或来自云盘
        // （UTI 不是 plain-text），按类型过滤会把它们藏掉导致"选不到文件"；
        // 格式校验与内容嗅探在 importBookData 内完成，选错会给明确提示。
        // fileImporter 的 success 回调里安全作用域 URL 才有效，必须同步读取。
        .fileImporter(
            isPresented: $showDocPicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    handlePickedData(
                        data,
                        name: url.deletingPathExtension().lastPathComponent,
                        ext: url.pathExtension.lowercased()
                    )
                } catch {
                    showMessage("读取文件失败：\(error.localizedDescription)", true)
                }
            case .failure(let error):
                showMessage(error.localizedDescription, true)
            }
        }
        .sheet(isPresented: $showURLSheet) {
            AddBookByURLView { msg, isErr in
                message = msg
                messageIsError = isErr
                showMsg = true
            }
        }
        .sheet(isPresented: $showSearch) {
            BookSearchView()
        }
        .overlay {
            if bookStore.books.isEmpty {
                ContentUnavailableView(
                    "书架还是空的",
                    systemImage: "books.vertical",
                    description: Text("右上角 + ：本地导入 / URL 添加书籍；🔍 可按书源搜索")
                )
            }
        }
        .alert("提示", isPresented: $showMsg) {
            Button("好") { showMsg = false }
        } message: {
            Text(message ?? "")
                .foregroundStyle(messageIsError ? .red : .green)
        }
    }

    private func showMessage(_ msg: String, _ isError: Bool) {
        message = msg
        messageIsError = isError
        showMsg = true
        showDocPicker = false
    }

    /// 数据已在回调内同步读取，这里只做异步骤落盘与入清单
    private func handlePickedData(_ data: Data, name: String, ext: String) {
        Task {
            do {
                let book = try await bookStore.importBook(
                    data: data, suggestedName: name, ext: ext
                )
                showMessage("已导入：《\(book.title)》", false)
            } catch {
                showMessage(error.localizedDescription, true)
            }
        }
    }
}
