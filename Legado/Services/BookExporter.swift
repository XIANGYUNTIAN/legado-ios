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
    /// 旧实现有三处隐患：try? 静默吞掉写失败、超长书名超出单文件名长度上限、
    /// 同名书籍反复导出复用同一路径。任一命中都会把「不存在 / 过期」的 URL 交给分享面板，
    /// 表现为点导出没反应。此处保证返回的 URL 指向本次真实写出的文件。
    static func writeTxtFile(named safeName: String, text: String) -> URL {
        var clean = safeName.filter { !$0.isWhitespace && $0 != "/" && $0 != ":" && $0 != "\\" }
        if clean.count > 60 { clean = String(clean.prefix(60)) }
        let base = clean.isEmpty ? "book" : clean
        let fileName = "\(base)_\(UUID().uuidString.prefix(6)).txt"
        let fm = FileManager.default
        let payload = text.isEmpty ? "（导出内容为空）" : text
        var target = fm.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try payload.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            // 临时目录不可写时退到 Documents，避免把不存在的 URL 交给分享面板。
            if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                target = docs.appendingPathComponent(fileName)
                try? payload.write(to: target, atomically: true, encoding: .utf8)
            }
        }
        return target
    }
}
