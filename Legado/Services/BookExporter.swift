import Foundation

/// 书架书籍 → TXT 导出：把本地书籍（txt / epub / pdf / docx / mobi / azw3）抽取章节并合并为纯文本。
///
/// 复用 `LocalBookReader` 的统一解析链路，保证「能读就能导」。
struct BookExporter {

    /// 单本书导出文本（异步：内部经 LocalBookReader 解析章节）。
    static func exportText(book: Book, fileURL: URL) async throws -> String {
        let chapters = try await LocalBookReader.chapters(format: book.format, title: book.title, at: fileURL)
        return Self.composeChapters(title: book.title, author: book.author, chapters: chapters)
    }

    /// 多本书合并导出（书名之间用分隔线隔开），用于书架「批量导出」。
    static func exportMultiple(_ items: [(Book, URL)]) async throws -> String {
        var blocks: [String] = []
        for (book, url) in items {
            let chapters = try await LocalBookReader.chapters(format: book.format, title: book.title, at: url)
            blocks.append(Self.composeChapters(title: book.title, author: book.author, chapters: chapters))
        }
        return blocks.joined(separator: "\n\n" + String(repeating: "=", count: 40) + "\n\n")
    }

    /// 把章节合并为带书名的纯文本（公开入口，供阅读器按范围下载复用）。
    static func compose(title: String, author: String, chapters: [ReaderChapter]) -> String {
        Self.composeChapters(title: title, author: author, chapters: chapters)
    }

    /// 把章节合并为带书名的纯文本。
    private static func composeChapters(title: String, author: String, chapters: [ReaderChapter]) -> String {
        var out = title.isEmpty ? "未命名" : title
        if !author.isEmpty, author != "未知" {
            out += "\n作者：\(author)"
        }
        out += "\n\n"
        for ch in chapters {
            let t = ch.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out += "\(t)\n\n" }
            out += (ch.text ?? "")
            out += "\n\n"
        }
        return out
    }

    /// 写入临时目录并返回文件 URL（供 UIActivityViewController 分享 / 存储到文件）。
    /// 文件名取自 safeName，统一加 .txt 后缀。
    static func writeTxtFile(named safeName: String, text: String) -> URL {
        let clean = safeName.filter { !$0.isWhitespace && $0 != "/" && $0 != ":" && $0 != "\\" }
        let base = clean.isEmpty ? "book" : clean
        let fileName = "\(base).txt"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? text.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }
}
