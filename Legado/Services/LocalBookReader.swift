import Foundation
import SwiftSoup
#if canImport(PDFKit)
import PDFKit
#endif

// MARK: - 本地书籍阅读错误

enum LocalBookError: LocalizedError {
    case unsupportedDoc
    case mobiCompressionUnsupported(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedDoc:
            return "暂不支持 .doc 二进制格式。请将文件另存为 .docx 或 .txt 后重新导入。"
        case .mobiCompressionUnsupported(let msg):
            return "该 MOBI / AZW3 使用了暂不支持的压缩方式（\(msg)）。请转换为 EPUB 或 TXT 后导入。"
        case .parseFailed(let msg):
            return "本地书籍解析失败：\(msg)"
        }
    }
}

/// 本地书籍解析：按 `BookFormat` 把各类本地文件抽取为统一的可读章节列表。
///
/// - txt：按中文章节标题切分（复用与历史一致的切章规则）。
/// - epub：经 `EPUBReader`（底层 `ZipArchive` 正确解压 method 8）。
/// - pdf：用 PDFKit 逐页抽取文本，每页为一章。
/// - docx：用 `ZipArchive` 解析 `word/document.xml`，按段落 / 标题切分。
/// - mobi / azw3：PalmDOC 解压（仅支持经典压缩 method 2；KF8/Huffman 给出友好提示）。
/// - doc：二进制 OLE2，纯 Swift 不可行，给出「另存为 docx/txt」提示。
struct LocalBookReader {

    /// 统一入口：返回章节列表（每章 text 已填充，url 为 nil）。
    static func chapters(format: BookFormat, title: String, at url: URL) async throws -> [ReaderChapter] {
        switch format {
        case .txt:
            let data = try Data(contentsOf: url)
            let text = decodeText(data)
            return splitPlainText(text, title: title)
        case .epub:
            let eps = try EPUBReader.shared.chapters(from: url)
            return eps.map { ReaderChapter(title: $0.title, text: $0.text, url: nil) }
        case .pdf:
            return try pdfChapters(at: url, title: title)
        case .docx:
            return try docxChapters(at: url, title: title)
        case .mobi, .azw3:
            return try mobiChapters(at: url, title: title)
        case .doc:
            throw LocalBookError.unsupportedDoc
        }
    }

    // MARK: - 文本解码

    /// TXT 解码：UTF-8 优先，回退 GB18030（中文 Windows 记事本常见）。
    private static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)), !s.isEmpty { return s }
        return String(data: data, encoding: .utf16) ?? ""
    }

    // MARK: - TXT 切章

    /// 按中文章节标题切分，无结构时按 ~8000 字兜底分段（与 BookReaderView 历史规则一致）。
    static func splitPlainText(_ rawText: String?, title: String) -> [ReaderChapter] {
        guard let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [ReaderChapter(title: title, text: "", url: nil)]
        }
        var text = rawText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")

        let pattern = #"(?m)^[ \t]*(?:第[0-9０-９零一二三四五六七八九十百千万两]+\s*[章回节卷集部篇][^\n]*|序[章幕言折][^\n]*|楔子[^\n]*|番外[篇卷]?[0-9零一二三四五六七八九十百千万]*[^\n]*|Chapter\s*[0-9]+[^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return fallbackSegments(text, title: title)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count > 1 else {
            return fallbackSegments(text, title: title)
        }
        var result: [ReaderChapter] = []
        let firstRange = matches[0].range
        if firstRange.location > 0 {
            let prefix = ns.substring(with: NSRange(location: 0, length: firstRange.location))
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(ReaderChapter(title: "序言", text: prefix, url: nil))
            }
        }
        for (i, match) in matches.enumerated() {
            let start = match.range.location
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            guard end > start else { continue }
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let t = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ReaderChapter(title: t.isEmpty ? "第\(i + 1)章" : t, text: body, url: nil))
        }
        return result
    }

    /// 无章节标记时的兜底：按 ~8000 字分段（尽量在换行处断开）。
    private static func fallbackSegments(_ text: String, title: String) -> [ReaderChapter] {
        let threshold = 8000
        guard text.count > threshold else {
            return [ReaderChapter(title: title, text: text, url: nil)]
        }
        var result: [ReaderChapter] = []
        var start = text.startIndex
        var seg = 1
        while start < text.endIndex {
            let hardEnd = text.index(start, offsetBy: threshold, limitedBy: text.endIndex) ?? text.endIndex
            var cut = hardEnd
            if cut < text.endIndex, let nl = text[start..<hardEnd].lastIndex(of: "\n") {
                cut = text.index(after: nl)
            }
            let body = String(text[start..<cut])
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(ReaderChapter(title: "第 \(seg) 段", text: body, url: nil))
                seg += 1
            }
            start = cut
        }
        return result.isEmpty ? [ReaderChapter(title: title, text: text, url: nil)] : result
    }

    // MARK: - PDF

    private static func pdfChapters(at url: URL, title: String) throws -> [ReaderChapter] {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else {
            throw LocalBookError.parseFailed("无法打开 PDF（可能为加密或扫描版）")
        }
        var chapters: [ReaderChapter] = []
        let count = doc.pageCount
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            // 优先用 page.string；为空时回退 attributedString（部分 PDF 用富文本编码正文）。
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = page.attributedString?.string ?? ""
            }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(ReaderChapter(
                title: "第 \(i + 1) 页",
                text: t.isEmpty ? "（本页无文本，可能为扫描图片）" : t,
                url: nil
            ))
        }
        if chapters.isEmpty {
            throw LocalBookError.parseFailed("PDF 未提取到任何文本（可能为扫描版，请使用 OCR 工具转文字）")
        }
        return chapters
        #else
        throw LocalBookError.parseFailed("当前平台不支持 PDFKit")
        #endif
    }

    // MARK: - DOCX

    private static func docxChapters(at url: URL, title: String) throws -> [ReaderChapter] {
        let archive = try ZipArchive.open(url: url)
        guard let docEntry = archive.entry(matching: { $0.lowercased().hasSuffix("word/document.xml") }) else {
            throw LocalBookError.parseFailed("DOCX 缺少 word/document.xml")
        }
        let xml = try archive.readString(docEntry)
        return try parseDocx(xml, title: title)
    }

    /// 从 document.xml 抽取段落；遇标题样式（Heading / 标题）即为新章节起点。
    private static func parseDocx(_ xml: String, title: String) throws -> [ReaderChapter] {
        guard let pRegex = try? NSRegularExpression(pattern: #"<w:p[ >][\s\S]*?</w:p>"#, options: []) else {
            throw LocalBookError.parseFailed("DOCX 段落解析失败")
        }
        let ns = xml as NSString
        let pMatches = pRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        var chapters: [ReaderChapter] = []
        var currentTitle = title
        var currentBody = ""

        func flush() {
            let t = currentBody.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                chapters.append(ReaderChapter(title: currentTitle, text: t, url: nil))
            }
            currentBody = ""
        }

        for m in pMatches {
            let pBlock = ns.substring(with: m.range)
            var isHeading = false
            if let styleRegex = try? NSRegularExpression(pattern: #"w:pStyle\s+w:val="([^"]*)""#, options: []),
               let sm = styleRegex.firstMatch(in: pBlock, range: NSRange(location: 0, length: (pBlock as NSString).length)),
               let srange = sm.range(at: 1) as? NSRange {
                let style = (pBlock as NSString).substring(with: srange).lowercased()
                if style.contains("heading") || style.contains("标题") {
                    isHeading = true
                }
            }
            let text = extractWText(pBlock)
            if isHeading {
                flush()
                if !text.isEmpty { currentTitle = text }
            } else if !text.isEmpty {
                currentBody += text + "\n"
            }
        }
        flush()

        if chapters.isEmpty {
            let all = extractWText(xml)
            return [ReaderChapter(title: title, text: all, url: nil)]
        }
        return chapters
    }

    /// 取段落内全部 <w:t> 文本。
    private static func extractWText(_ block: String) -> String {
        guard let r = try? NSRegularExpression(pattern: #"<w:t[^>]*>([\s\S]*?)</w:t>"#, options: []) else { return "" }
        let ns = block as NSString
        let ms = r.matches(in: block, range: NSRange(location: 0, length: ns.length))
        return ms.map { ns.substring(with: $0.range(at: 1)) }.joined()
    }

    // MARK: - MOBI / AZW3（PalmDOC）

    private static func mobiChapters(at url: URL, title: String) throws -> [ReaderChapter] {
        let data = try Data(contentsOf: url)
        let plain = try decompressMobi(data)
        let stripped = stripHTML(plain)
        return splitPlainText(stripped, title: title)
    }

    /// 解析 PalmDB + PalmDOC 头，解压文本记录为 HTML，再清洗为纯文本。
    private static func decompressMobi(_ data: Data) throws -> String {
        guard data.count > 78 else { throw LocalBookError.parseFailed("文件过小，非 MOBI/AZW3") }
        // 偏移 60..64 应为 "BOOK"（Palm Database type）
        let type = String(bytes: data[60..<64], encoding: .ascii) ?? ""
        guard type == "BOOK" else {
            throw LocalBookError.parseFailed("不是有效的 MOBI / AZW3 文件")
        }
        let numRecords = Int(be16(data, 76))
        guard numRecords > 1 else { throw LocalBookError.parseFailed("MOBI 记录数为 0") }

        // 记录偏移表：每项 8 字节（offset 4 + attr 1 + uid 3）
        var offsets: [Int] = []
        for i in 0..<numRecords {
            offsets.append(Int(be32(data, 78 + i * 8)))
        }

        // 记录 0 = PalmDOC 头（16 字节）
        let rec0 = offsets[0]
        guard rec0 + 16 <= data.count else { throw LocalBookError.parseFailed("MOBI 头越界") }
        let compression = be16(data, rec0 + 0)
        let textRecordCount = be16(data, rec0 + 6)
        let encryption = be16(data, rec0 + 10)

        guard encryption == 0 else {
            throw LocalBookError.parseFailed("MOBI 已加密，无法读取")
        }

        let textRecords: Int
        if textRecordCount > 0 {
            textRecords = Int(textRecordCount)
        } else {
            // 部分文件未声明 textRecordCount，按后续记录数估算
            textRecords = max(0, numRecords - 1)
        }
        guard textRecords > 0 else { throw LocalBookError.parseFailed("MOBI 文本记录为 0") }

        var out = Data()
        for i in 1...min(textRecords, numRecords - 1) {
            let start = offsets[i]
            let end = (i + 1 < offsets.count) ? offsets[i + 1] : data.count
            guard start < end, end <= data.count else { continue }
            let chunk = data[start..<end]
            switch compression {
            case 1:
                out.append(chunk)
            case 2:
                out.append(try palmDocDecompress(Data(chunk)))
            default:
                throw LocalBookError.mobiCompressionUnsupported("压缩类型 \(compression)")
            }
        }
        // MOBI 文本为 UTF-8（部分含 latin1），先按 UTF-8，失败按 latin1→保留字节
        if let s = String(data: out, encoding: .utf8), !s.isEmpty { return s }
        return String(data: out, encoding: .isoLatin1) ?? ""
    }

    /// PalmDOC 解压（压缩类型 2），经典 LZ 方案：逐字节解释字面量 / 字面量串 / 回指。
    private static func palmDocDecompress(_ data: Data) throws -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 4)
        var i = data.startIndex
        let n = data.endIndex
        while i < n {
            let b = data[i]
            if b == 0x00 {
                out.append(0x20)  // 空字节在 PalmDOC 中表示空格
                i += 1
            } else if b <= 0x08 {
                let count = Int(b)
                i += 1
                for _ in 0..<count {
                    if i < n { out.append(data[i]); i += 1 }
                }
            } else if b <= 0x7F {
                out.append(b)
                i += 1
            } else {
                guard i + 1 < n else { out.append(b); i += 1; break }
                let b2 = data[i + 1]
                let distance = ((Int(b) & 0x3F) << 8) | Int(b2)
                let length = (Int(b) >> 6) + 3
                let startIdx = out.count - distance
                if distance > 0 && startIdx >= 0 {
                    for k in 0..<length {
                        let src = startIdx + k
                        if src >= 0 && src < out.count {
                            out.append(out[src])
                        }
                    }
                }
                i += 2
            }
        }
        return Data(out)
    }

    /// HTML → 纯文本（MOBI 文本为 HTML 标记），优先 SwiftSoup，失败回退正则去标签。
    private static func stripHTML(_ html: String) -> String {
        if let doc = try? SwiftSoup.parse(html) {
            try? doc.select("script, style").remove()
            let body = (try? doc.select("body"))?.first() ?? doc
            let text = (try? body.text()) ?? ""
            if !text.isEmpty { return text }
        }
        // 回退：去 script/style + 去标签
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return s
    }

    // MARK: - 大端读取

    private static func be16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) << 8 | UInt16(d[o + 1])
    }

    private static func be32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
}
