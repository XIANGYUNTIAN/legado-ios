import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {
    @EnvironmentObject private var bookStore: BookStore

    @State private var showQR = false
    @State private var showDocPicker = false
    @State private var showURLSheet = false
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
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showQR = true
                    } label: {
                        Label("扫一扫添加书源", systemImage: "qrcode.viewfinder")
                    }
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
        .sheet(isPresented: $showQR) {
            QRSourceScanSheet()
        }
        .fileImporter(
            isPresented: $showDocPicker,
            allowedContentTypes: [UTType.text, UTType.epub],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { handlePicked(url) }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showURLSheet) {
            AddBookByURLView { msg, isErr in
                message = msg
                messageIsError = isErr
                showMsg = true
            }
        }
        .overlay {
            if bookStore.books.isEmpty {
                ContentUnavailableView(
                    "书架还是空的",
                    systemImage: "books.vertical",
                    description: Text("右上角 + ：扫码加书源 / 本地导入 / URL 添加书籍")
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

    private func handlePicked(_ url: URL) {
        Task {
            do {
                let book = try await bookStore.importLocalFile(at: url)
                message = "已导入：《\(book.title)》"
                messageIsError = false
            } catch {
                message = error.localizedDescription
                messageIsError = true
            }
            showMsg = true
            showDocPicker = false
        }
    }
}
