import Foundation
import CoreFoundation

/// 书籍导入/下载时的错误，便于在界面给出可读提示
enum BookImportError: LocalizedError {
    case invalidURL
    case invalidFormat(String)
    case badStatus(Int)
    case emptyContent
    case encodingFailed
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接格式不正确（需 http(s) 链接）"
        case .invalidFormat(let ext): return "不支持的格式：.\(ext)（仅 TXT / EPUB）"
        case .badStatus(let code): return "服务器返回 HTTP \(code)"
        case .emptyContent: return "文件内容为空"
        case .encodingFailed: return "文本解码失败（非 UTF-8 / GB18030）"
        case .downloadFailed(let msg): return "下载失败：\(msg)"
        }
    }
}

/// 书架本地存储：Documents/Books 存放实体文件，Documents/bookshelf.json 记录清单
@MainActor
final class BookStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    private let documentsDir: URL
    private let booksDir: URL
    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        documentsDir = docs
        booksDir = docs.appendingPathComponent("Books", isDirectory: true)
        fileURL = docs.appendingPathComponent("bookshelf.json")
        try? FileManager.default.createDirectory(at: booksDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = arr
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 由相对路径还原完整文件 URL
    func fileURL(for book: Book) -> URL? {
        guard let rel = book.fileRelativePath else { return nil }
        return documentsDir.appendingPathComponent(rel)
    }

    // MARK: - 导入入口

    /// 从系统文件选择器选中的本地文件导入（TXT / EPUB）
    func importLocalFile(at url: URL) async throws -> Book {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try importBookData(
            data,
            suggestedName: url.deletingPathExtension().lastPathComponent,
            ext: url.pathExtension.lowercased(),
            remoteURL: nil
        )
    }

    /// 从远程书籍链接下载并导入（解析、下载、入库）
    func importRemoteBook(from link: String) async throws -> Book {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw BookImportError.invalidURL
        }

        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await NetworkService.shared.fetchDataWithResponse(
                from: url,
                timeout: 30
            )
        } catch let error as NetworkError {
            switch error {
            case .timeout:
                throw BookImportError.downloadFailed("请求超时，请检查网络或链接")
            case .badStatus(let code):
                throw BookImportError.badStatus(code)
            default:
                throw BookImportError.downloadFailed(error.localizedDescription)
            }
        } catch {
            throw BookImportError.downloadFailed(error.localizedDescription)
        }

        let ext = inferExtension(url: url, response: http)
        let rawName = (url.pathComponents.last?.removingPercentEncoding ?? "remote")
        let name = (rawName as NSString).deletingPathExtension
        return try importBookData(data, suggestedName: name, ext: ext, remoteURL: trimmed)
    }

    // MARK: - 内部

    private func inferExtension(url: URL, response: URLResponse) -> String {
        if let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if mime.contains("epub") { return "epub" }
            if mime.contains("text") { return "txt" }
        }
        let ext = url.pathExtension.lowercased()
        if ext == "txt" || ext == "epub" { return ext }
        return "txt"
    }

    /// 统一校验 + 落盘 + 写清单
    private func importBookData(_ data: Data, suggestedName: String, ext: String, remoteURL: String?) throws -> Book {
        let lower = ext.lowercased()
        guard lower == "txt" || lower == "epub" else {
            throw BookImportError.invalidFormat(ext)
        }
        guard !data.isEmpty else { throw BookImportError.emptyContent }

        if lower == "txt" {
            let decoded = String(data: data, encoding: .utf8)
                ?? {
                    let gb = CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    )
                    return String(data: data, encoding: String.Encoding(rawValue: gb))
                }()
            if decoded == nil { throw BookImportError.encodingFailed }
        } else {
            // EPUB 本质是 zip，校验本地 zip 魔数（PK\x03\x04）
            let isZip = data.count >= 4
                && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
            guard isZip else { throw BookImportError.invalidFormat(ext) }
        }

        let baseName = suggestedName.isEmpty ? "book" : suggestedName
        let safeName = baseName.filter { !$0.isWhitespace && $0 != "/" && $0 != ":" && $0 != "\\" }
        let fileName = "\(safeName)_\(String(UUID().uuidString.prefix(8))).\(lower)"
        let dest = booksDir.appendingPathComponent(fileName)
        try data.write(to: dest, options: .atomic)

        let book = Book(
            id: UUID().uuidString,
            title: baseName,
            author: "未知",
            format: lower == "txt" ? .txt : .epub,
            fileRelativePath: "Books/\(fileName)",
            remoteURL: remoteURL,
            addedAt: Date(),
            fileSize: Int64(data.count)
        )
        books.append(book)
        persist()
        return book
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let book = books[index]
            if let rel = book.fileRelativePath {
                try? FileManager.default.removeItem(at: documentsDir.appendingPathComponent(rel))
            }
        }
        books.remove(atOffsets: offsets)
        persist()
    }

    /// 添加规则阅读书籍（保留 sourceId + bookUrl，不落本地文件）
    func addBook(_ book: Book) {
        books.append(book)
        persist()
    }
}
