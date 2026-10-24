import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {
    @EnvironmentObject private var bookStore: BookStore

    @State private var showURLSheet = false
    @State private var showSearch = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showMsg = false

    // 批量选择模式
    @State private var isSelecting = false
    @State private var selection = Set<String>()   // 存 book.id
    @State private var showDeleteConfirm = false

    var body: some View {
        List {
            ForEach(bookStore.books) { book in
                if isSelecting {
                    selectableRow(book)
                } else {
                    NavigationLink {
                        BookDetailView(book: book)
                    } label: {
                        bookRow(book)
                    }
                }
            }
            .onDelete(perform: bookStore.delete)
        }
        .navigationTitle("书架（\(bookStore.books.count)）")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    Button("取消") { exitSelecting() }
                } else {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if isSelecting {
                        Button {
                            toggleSelectAll()
                        } label: {
                            Text(selection.count == bookStore.books.count ? "取消全选" : "全选")
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
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isSelecting {
                    EmptyView()
                } else {
                    Menu {
                        Button {
                            // 顶层 VC 直接呈现文档选择器：绕开 SwiftUI 呈现栈
                            // （.fileImporter 由 Menu 触发时可能不呈现），且系统
                            // asCopy 拷贝本地文件，无安全作用域/iCloud 依赖
                            DocumentImporter.present(
                                onPick: { url in handlePickedURL(url) },
                                onCancel: { }
                            )
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
        }
        // 本地导入已改为 DocumentImporter.present（顶层 VC + asCopy），
        // 不再依赖 SwiftUI .fileImporter 与安全作用域 URL。
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
        .confirmationDialog("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除 \(selection.count) 本书", role: .destructive) {
                bookStore.delete(ids: Array(selection))
                exitSelecting()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将永久删除选中的 \(selection.count) 本书（含本地文件），且不可恢复。")
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

    // MARK: - 行视图

    private func bookRow(_ book: Book) -> some View {
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

    private func selectableRow(_ book: Book) -> some View {
        let selected = selection.contains(book.id)
        return HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? .tint : .secondary)
                .font(.title3)
            bookRow(book)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(book) }
    }

    // MARK: - 选择逻辑

    private func toggle(_ book: Book) {
        let id = book.id
        if selection.contains(id) { selection.remove(id) }
        else { selection.insert(id) }
    }

    private func toggleSelectAll() {
        if selection.count == bookStore.books.count {
            selection = []
        } else {
            selection = Set(bookStore.books.map { $0.id })
        }
    }

    private func exitSelecting() {
        isSelecting = false
        selection = []
    }

    // MARK: - 导入

    private func showMessage(_ msg: String, _ isError: Bool) {
        message = msg
        messageIsError = isError
        showMsg = true
    }

    /// asCopy 模式给出的 URL 指向系统拷贝到本地临时目录的文件，可直接读
    private func handlePickedURL(_ url: URL) {
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
    }

    /// 数据已读取，这里只做异步骤落盘与入清单
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
