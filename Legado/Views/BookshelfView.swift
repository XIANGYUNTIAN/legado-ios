import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct BookshelfView: View {
    @EnvironmentObject private var bookStore: BookStore
    @EnvironmentObject private var shelfSettings: BookshelfSettings

    // 阅读器呈现
    @State private var selectedBook: Book? = nil
    @State private var showReader = false

    // 搜索 / URL 添加
    @State private var showURLSheet = false
    @State private var showSearch = false

    // 提示
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showMsg = false

    // 批量选择（导出 / 删除）
    @State private var isSelecting = false
    @State private var selection = Set<String>()   // 存 book.id
    @State private var showDeleteConfirm = false

    // TXT 导出
    @State private var exportURL: URL? = nil
    @State private var showExport = false

    // 行内详情展开
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        Group {
            if shelfSettings.layout == .grid {
                gridShelf
            } else {
                listShelf
            }
        }
        .navigationTitle("书架（\(bookStore.books.count)）")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isSelecting {
                    Button("取消") { exitSelecting() }
                } else {
                    EmptyView()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 18) {
                    if isSelecting {
                        Button {
                            toggleSelectAll()
                        } label: {
                            Text(selection.count == bookStore.books.count ? "取消全选" : "全选")
                        }
                    } else {
                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        Menu {
                            Button {
                                DocumentImporter.present(
                                    onPick: { url in handlePickedURL(url) },
                                    onCancel: { }
                                )
                            } label: {
                                Label("本地导入书籍（TXT/EPUB/PDF/DOCX/MOBI/AZW3）", systemImage: "square.and.arrow.down.on.square")
                            }
                            Button {
                                showURLSheet = true
                            } label: {
                                Label("URL 添加书籍", systemImage: "link")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button {
                            shelfSettings.layout = (shelfSettings.layout == .grid) ? .list : .grid
                            shelfSettings.save()
                        } label: {
                            Image(systemName: shelfSettings.layout == .grid ? "list.bullet" : "square.grid.2x2")
                        }
                        if shelfSettings.layout == .grid {
                            Menu {
                                ForEach(BookshelfSettings.gridColumnOptions, id: \.self) { n in
                                    Button {
                                        shelfSettings.gridColumns = n
                                        shelfSettings.save()
                                    } label: {
                                        Label("\(n) 列", systemImage: shelfSettings.gridColumns == n ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                        }
                        Button {
                            tapExport()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button {
                            tapDelete()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        // 行内选择态底部条
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack {
                    Text("已选 \(selection.count) 本")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        tapExport()
                    } label: {
                        Text("导出（\(selection.count)）")
                    }
                    .disabled(selection.isEmpty)
                    Button {
                        tapDelete()
                    } label: {
                        Text("删除（\(selection.count)）")
                            .foregroundStyle(.red)
                    }
                    .disabled(selection.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
        }
        .navigationDestination(isPresented: $showReader) {
            if let book = selectedBook {
                BookReaderView(book: book)
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
        .confirmationDialog("确认删除", isPresented: $showDeleteConfirm) {
            Button("删除 \(selection.count) 本书", role: .destructive) {
                bookStore.delete(ids: Array(selection))
                exitSelecting()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将永久删除选中的 \(selection.count) 本书（含本地文件），且不可恢复。")
        }
        .sheet(isPresented: $showExport) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(book.id) ? Color.accentColor : Color.secondary)
                        .font(.title3)
                }
                BookCoverView(book: book)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.displayTitle)
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
                // 展开/收起详情
                Button {
                    if expandedIDs.contains(book.id) { expandedIDs.remove(book.id) }
                    else { expandedIDs.insert(book.id) }
                } label: {
                    Image(systemName: expandedIDs.contains(book.id) ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    toggle(book)
                } else {
                    selectedBook = book
                    showReader = true
                }
            }
            // 行内展开的详情（点击行右侧箭头展开/收起，避免进入二级详情页）
            if expandedIDs.contains(book.id) {
                bookDetails(book)
            }
        }
    }

    // MARK: - 列表 / 网格渲染

    private var listShelf: some View {
        List {
            ForEach(bookStore.books) { book in
                bookRow(book)
            }
            .onDelete { offsets in
                bookStore.delete(at: offsets)
            }
        }
    }

    private var gridShelf: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(bookStore.books) { book in
                    gridCell(book)
                }
            }
            .padding(16)
        }
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: shelfSettings.gridColumns)
    }

    /// 网格封面尺寸：列数越多封面越小（保持 1:1.4 书籍比例）
    private func gridCoverSize(columns: Int) -> CGSize {
        let w: CGFloat = columns >= 5 ? 56 : columns == 4 ? 72 : columns == 3 ? 92 : 120
        return CGSize(width: w, height: w * 1.4)
    }

    private func gridCell(_ book: Book) -> some View {
        VStack(alignment: .center, spacing: 6) {
            if isSelecting {
                Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(book.id) ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            BookCoverView(book: book, size: gridCoverSize(columns: shelfSettings.gridColumns))
            Text(book.displayTitle)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Text(book.author)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            isSelecting && selection.contains(book.id)
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggle(book)
            } else {
                selectedBook = book
                showReader = true
            }
        }
    }

    /// 行内文件详情（点击行右侧箭头展开/收起，避免进入二级详情页）
    private func bookDetails(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let size = book.fileSize {
                HStack {
                    Text("大小").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                .font(.caption)
            }
            if let p = book.fileRelativePath {
                HStack(alignment: .top) {
                    Text("本地文件").foregroundStyle(.secondary)
                    Text(p).textSelection(.enabled)
                }
                .font(.caption)
            }
            if let u = book.remoteURL {
                HStack(alignment: .top) {
                    Text("来源链接").foregroundStyle(.secondary)
                    Text(u).textSelection(.enabled)
                }
                .font(.caption)
            }
            if book.supportsRuleReading {
                Text("阅读方式：书源规则阅读")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 单本导出 TXT（有本地文件且非 .doc 时可导）
            if bookStore.fileURL(for: book) != nil && book.format != .doc {
                Button {
                    exportSingle(book)
                } label: {
                    Label("导出 TXT", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
            }
        }
        .padding(.leading, 34)
        .padding(.vertical, 6)
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

    /// 顶部「导出」按钮：未在选择态→进入选择态；已在选择态→执行导出
    private func tapExport() {
        if isSelecting {
            exportSelected()
        } else {
            guard !bookStore.books.isEmpty else {
                showMessage("书架是空的", false)
                return
            }
            selection = []
            isSelecting = true
        }
    }

    /// 顶部「删除」按钮：未在选择态→进入选择态；已在选择态→执行删除
    private func tapDelete() {
        if isSelecting {
            guard !selection.isEmpty else {
                showMessage("请先选择要删除的书籍", true)
                return
            }
            showDeleteConfirm = true
        } else {
            guard !bookStore.books.isEmpty else {
                showMessage("书架是空的", false)
                return
            }
            selection = []
            isSelecting = true
        }
    }

    // MARK: - 导出 TXT

    /// 把勾选的本地书籍（含 txt / epub / pdf / docx / mobi / azw3）合并导出为 TXT。
    /// 规则阅读书籍（无本地文件）与 .doc 无法导出，会被跳过。
    private func exportSelected() {
        let selected = bookStore.books.filter { selection.contains($0.id) }
        let localItems = selected.compactMap { book -> (Book, URL)? in
            if book.format == .doc { return nil }
            if let url = bookStore.fileURL(for: book) { return (book, url) }
            return nil
        }
        guard !localItems.isEmpty else {
            showMessage("所选书籍没有可导出的本地文件（规则书或无本地实体）", true)
            return
        }
        Task {
            do {
                let text = try await BookExporter.exportMultiple(localItems)
                let fileName = localItems.count == 1
                    ? (localItems.first?.0.title ?? "book")
                    : "书架导出\(localItems.count)本"
                let tmp = BookExporter.writeTxtFile(named: fileName, text: text)
                await MainActor.run {
                    exportURL = tmp
                    showExport = true
                }
            } catch {
                await MainActor.run { showMessage("导出失败：\(error.localizedDescription)", true) }
            }
        }
    }

    /// 单本导出（行内详情里的按钮）
    private func exportSingle(_ book: Book) {
        guard let url = bookStore.fileURL(for: book) else {
            showMessage("该书没有本地文件，无法导出", true)
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
                await MainActor.run { showMessage("导出失败：\(error.localizedDescription)", true) }
            }
        }
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
