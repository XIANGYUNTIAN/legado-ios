import Foundation
import zlib

// MARK: - ZIP 归档读取（纯 Swift，无第三方依赖）

/// 最小可用的 ZIP 读取器：扫描中央目录 → 定位条目 → 按 method 解压。
///
/// 支持：
/// - method 0（stored，无压缩）
/// - method 8（deflate，**raw deflate**，windowBits = -15）
///
/// 关键修复：旧 `EPUBReader` 用「伪造 zlib 头 + 15+32 自动探测」解 raw deflate，
/// 大量条目因缺少 adler32 尾校验而 inflate 失败 → 报错「暂不支持的压缩格式」。
/// 正确做法是对 method 8 直接按 raw deflate（无 zlib/gzip 头）解压，即 windowBits = -15。
struct ZipArchive {
    let data: Data
    let entries: [String: ZipEntry]

    // MARK: - 打开

    static func open(url: URL) throws -> ZipArchive {
        try open(data: Data(contentsOf: url))
    }

    static func open(data: Data) throws -> ZipArchive {
        guard data.count >= 22,
              data[0] == 0x50, data[1] == 0x4B,
              data[2] == 0x03, data[3] == 0x04 else {
            throw ZipArchiveError.notAZip
        }

        // 从文件末尾向前扫描 EOCD（PK\x05\x06）
        var eocdOffset = -1
        let searchStart = max(0, data.count - 65557)  // EOCD + 注释上限
        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            if i + 4 <= data.count,
               data[i] == 0x50, data[i+1] == 0x4B,
               data[i+2] == 0x05, data[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else { throw ZipArchiveError.notAZip }

        let cdOffset = Int(le32(data, eocdOffset + 16))
        let totalEntries = Int(le16(data, eocdOffset + 10))

        var entries: [String: ZipEntry] = [:]
        var cursor = cdOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count else { break }
            guard data[cursor] == 0x50, data[cursor+1] == 0x4B,
                  data[cursor+2] == 0x01, data[cursor+3] == 0x02 else { break }
            let method = Int(le16(data, cursor + 10))
            var compressedSize: UInt64 = UInt64(le32(data, cursor + 20))
            var uncompressedSize: UInt64 = UInt64(le32(data, cursor + 24))
            let nameLen = Int(le16(data, cursor + 28))
            let extraLen = Int(le16(data, cursor + 30))
            let commentLen = Int(le16(data, cursor + 32))
            var localOffset: UInt64 = UInt64(le32(data, cursor + 42))

            // ZIP64：标准字段为 0xFFFFFFFF 时，真实值位于「ZIP64 扩展信息」额外字段中。
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                let extraStart = cursor + 46 + nameLen
                if extraStart + extraLen <= data.count {
                    let extra = data[extraStart..<(extraStart + extraLen)]
                    let z64 = Self.parseZip64Extra(extra, comp: compressedSize, uncomp: uncompressedSize, local: localOffset)
                    compressedSize = z64.comp
                    uncompressedSize = z64.uncomp
                    localOffset = z64.local
                }
            }

            let name = String(bytes: data[(cursor + 46)..<(cursor + 46 + nameLen)], encoding: .utf8) ?? ""
            entries[name] = ZipEntry(
                name: name,
                method: method,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localOffset)
            )
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return ZipArchive(data: data, entries: entries)
    }

    // MARK: - 条目读取

    func entry(named name: String) -> ZipEntry? { entries[name] }

    /// 按谓词匹配第一个条目（用于「忽略大小写/路径前缀」查找，如 word/document.xml）
    func entry(matching predicate: (String) -> Bool) -> ZipEntry? {
        entries.first { predicate($0.key) }?.value
    }

    /// 读取条目内容为字符串（UTF-8 优先，回退 UTF-16）
    func readString(_ entry: ZipEntry, encoding: String.Encoding = .utf8) throws -> String {
        let d = try readData(entry)
        if let s = String(data: d, encoding: encoding), !s.isEmpty { return s }
        if let s = String(data: d, encoding: .utf16) { return s }
        return String(data: d, encoding: encoding) ?? ""
    }

    /// 读取条目内容为原始 Data（含解压）
    func readData(_ entry: ZipEntry) throws -> Data {
        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset + 30 <= data.count,
              data[localOffset] == 0x50, data[localOffset+1] == 0x4B,
              data[localOffset+2] == 0x03, data[localOffset+3] == 0x04 else {
            throw ZipArchiveError.readFailed("本地文件头损坏：\(entry.name)")
        }
        let nameLen = Int(ZipArchive.le16(data, localOffset + 26))
        // 注意：本地文件头 +28 处是「额外字段长度」，仅占 2 字节，必须用 le16。
        // 误用 le32 会把后 2 字节文件名一并读入，导致 extraLen 被撑成巨值、
        // dataStart 远超文件，报「条目数据越界」。这正是 EPUB/DOCX 首条目必越界的根因。
        let extraLen = Int(ZipArchive.le16(data, localOffset + 28))
        let dataStart = localOffset + 30 + nameLen + extraLen
        let end = min(dataStart + Int(entry.compressedSize), data.count)
        guard dataStart <= end else { throw ZipArchiveError.readFailed("条目数据越界：\(entry.name)") }
        let raw = data[dataStart..<end]

        switch entry.method {
        case 0:  // stored
            return Data(raw)
        case 8:  // deflate（raw，无 zlib 头）
            return try inflateRawDeflate(Data(raw))
        default:
            throw ZipArchiveError.unsupportedCompression("method \(entry.method)（\(entry.name)）")
        }
    }

    /// raw deflate 解压（windowBits = -15，对应 RFC 1951，无 zlib/gzip 头）
    private func inflateRawDeflate(_ raw: Data) throws -> Data {
        var zstream = z_stream()
        defer { inflateEnd(&zstream) }

        var out = Data()
        var capacity = max(raw.count * 10, 4096)
        var produced = 0
        var complete = false

        try raw.withUnsafeBytes { inBytes in
            guard let inBase = inBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw ZipArchiveError.readFailed("内存映射失败")
            }
            zstream.next_in = UnsafeMutablePointer<UInt8>(mutating: inBase)
            zstream.avail_in = uInt(raw.count)

            let version = strdup("1.3")
            defer { free(version) }
            guard inflateInit2_(&zstream, -15, version, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw ZipArchiveError.readFailed("inflateInit 失败")
            }

            while !complete {
                var chunk = Data(count: capacity)
                let before = produced
                try chunk.withUnsafeMutableBytes { outBytes in
                    guard let outBase = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                        throw ZipArchiveError.readFailed("内存映射失败")
                    }
                    zstream.next_out = UnsafeMutablePointer<UInt8>(mutating: outBase)
                    zstream.avail_out = uInt(capacity)
                    let result = inflate(&zstream, Z_NO_FLUSH)
                    produced = Int(zstream.total_out)
                    if result == Z_STREAM_END {
                        complete = true
                    } else if result != Z_OK {
                        throw ZipArchiveError.readFailed("inflate 失败（\(result)）")
                    }
                }
                out.append(chunk.prefix(produced - before))
                if !complete {
                    if zstream.avail_in == 0 && produced == before {
                        throw ZipArchiveError.readFailed("输入耗尽且未产出")
                    }
                    capacity *= 2
                }
            }
        }
        guard produced > 0 else { throw ZipArchiveError.readFailed("解压结果为空") }
        return out
    }

    // MARK: - 小端读取

    private static func le16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }

    private static func le32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    private static func le64(_ d: Data, _ o: Int) -> UInt64 {
        UInt64(d[o]) | (UInt64(d[o + 1]) << 8) | (UInt64(d[o + 2]) << 16) | (UInt64(d[o + 3]) << 24)
            | (UInt64(d[o + 4]) << 32) | (UInt64(d[o + 5]) << 40) | (UInt64(d[o + 6]) << 48) | (UInt64(d[o + 7]) << 56)
    }

    /// 解析 ZIP64 扩展信息额外字段（header id 0x0001）：当 CEN 的标准字段为
    /// 0xFFFFFFFF 时，真实值（未压缩/压缩尺寸、本地头偏移，按顺序）写入此字段。
    /// 仅解析那些被置为 0xFFFFFFFF 的字段。
    private static func parseZip64Extra(_ extra: Data, comp: UInt64, uncomp: UInt64, local: UInt64)
        -> (comp: UInt64, uncomp: UInt64, local: UInt64) {
        guard comp == 0xFFFFFFFF || uncomp == 0xFFFFFFFF || local == 0xFFFFFFFF else {
            return (comp, uncomp, local)
        }
        var i = 0
        while i + 4 <= extra.count {
            let hid = le16(extra, i)
            let dsize = Int(le16(extra, i + 2))
            let start = i + 4
            if hid == 0x0001, start + dsize <= extra.count {
                var p = start
                var u = uncomp, c = comp, l = local
                if uncomp == 0xFFFFFFFF {
                    u = le64(extra, p); p += 8
                }
                if comp == 0xFFFFFFFF {
                    c = le64(extra, p); p += 8
                }
                if local == 0xFFFFFFFF {
                    l = le64(extra, p); p += 8
                }
                return (c, u, l)
            }
            i = start + dsize
        }
        return (comp, uncomp, local)
    }
}

/// ZIP 条目元信息
struct ZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

/// ZIP 读取错误
enum ZipArchiveError: LocalizedError {
    case notAZip
    case readFailed(String)
    case unsupportedCompression(String)

    var errorDescription: String? {
        switch self {
        case .notAZip:
            return "不是有效的 ZIP / EPUB / DOCX 文件"
        case .readFailed(let msg):
            return "ZIP 读取失败：\(msg)"
        case .unsupportedCompression(let msg):
            return "ZIP 使用了暂不支持的压缩格式：\(msg)"
        }
    }
}
