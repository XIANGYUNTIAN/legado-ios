import Foundation
import Compression
import SwiftSoup

// MARK: - 错误

enum EPUBError: LocalizedError {
    case notAZip
    case noContainerXML
    case noOPF
    case unsupportedCompression
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAZip:
            return "不是有效的 EPUB 文件（zip 魔数校验失败）"
        case .noContainerXML:
            return "EPUB 缺少 META-INF/container.xml"
        case .noOPF:
            return "EPUB 缺少 OPF 清单文件"
        case .unsupportedCompression:
            return "EPUB 使用了暂不支持的压缩格式"
        case .extractionFailed(let msg):
            return "EPUB 解析失败：\(msg)"
        }
    }
}

/// EPUB 章节
struct EPUBChapter: Identifiable {
    let id = UUID()
    let href: String       // OPF 内的相对路径
    let title: String
    let text: String
}

/// 最小可用的 EPUB 解析器（纯 Swift，无第三方依赖）
///
/// 流程：读 zip 中央目录 → 定位 META-INF/container.xml → 解析 OPF 路径 →
/// 解析 spine itemref → 逐章读取 HTML → SwiftSoup 抽取正文。
/// 支持 stored（无压缩）与 raw-deflate（zip 常用压缩）两种内容编码。
final class EPUBReader {
    static let shared = EPUBReader()

    /// 从本地 EPUB 文件抽取章节正文列表
    func chapters(from epubURL: URL) throws -> [EPUBChapter] {
        let data = try Data(contentsOf: epubURL)
        let entries = try parseZip(data)

        guard let container = entries["META-INF/container.xml"] else {
            throw EPUBError.noContainerXML
        }
        let containerXML = try readEntry(data, entry: container)
        let opfPath = try parseContainerXML(containerXML)
        guard let opfEntry = entries[opfPath] else {
            throw EPUBError.noOPF
        }
        let opfXML = try readEntry(data, entry: opfEntry)
        let spine = try parseOPF(opfXML, opfBase: (opfPath as NSString).deletingPathExtension)
        guard !spine.isEmpty else { throw EPUBError.noOPF }

        let opfDir = (opfPath as NSString).deletingPathExtension
            .split(separator: "/").dropLast().joined(separator: "/")
        var chapters: [EPUBChapter] = []
        for item in spine {
            let fullPath = opfDir.isEmpty ? item.href : (opfDir + "/" + item.href)
            guard let entry = entries[fullPath] else { continue }
            let html = try? readEntry(data, entry: entry)
            let text = html.flatMap { try? extractText($0) } ?? ""
            chapters.append(EPUBChapter(href: fullPath, title: item.title, text: text))
        }
        return chapters
    }

    // MARK: - ZIP 解析

    private struct ZipEntry {
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var localHeaderOffset: UInt32
    }

    /// 扫描中央目录，返回 文件名 → ZipEntry
    private func parseZip(_ data: Data) throws -> [String: ZipEntry] {
        // 校验本地文件头魔数
        guard data.count >= 22,
              data[0] == 0x50, data[1] == 0x4B,
              data[2] == 0x03, data[3] == 0x04 else {
            throw EPUBError.notAZip
        }

        // 查找 EOCD（PK\x05\x06），从文件末尾向后扫描
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
        guard eocdOffset >= 0 else { throw EPUBError.notAZip }

        let cdOffset = Int(le32(data, eocdOffset + 16))
        let cdSize = Int(le32(data, eocdOffset + 12))
        let totalEntries = Int(le16(data, eocdOffset + 10))

        var entries: [String: ZipEntry] = [:]
        var cursor = cdOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count else { break }
            guard data[cursor] == 0x50, data[cursor+1] == 0x4B,
                  data[cursor+2] == 0x01, data[cursor+3] == 0x02 else { break }
            let method = le16(data, cursor + 10)
            let compressedSize = le32(data, cursor + 20)
            let uncompressedSize = le32(data, cursor + 24)
            let nameLen = Int(le16(data, cursor + 28))
            let extraLen = Int(le16(data, cursor + 30))
            let commentLen = Int(le16(data, cursor + 32))
            let localOffset = le32(data, cursor + 42)
            let name = String(bytes: data[(cursor + 46)..<(cursor + 46 + nameLen)], encoding: .utf8) ?? ""
            entries[name] = ZipEntry(
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                method: method,
                localHeaderOffset: localOffset
            )
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 读取单个条目的内容（解压）
    private func readEntry(_ data: Data, entry: ZipEntry) throws -> String {
        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset + 30 <= data.count,
              data[localOffset] == 0x50, data[localOffset+1] == 0x4B,
              data[localOffset+2] == 0x03, data[localOffset+3] == 0x04 else {
            throw EPUBError.extractionFailed("本地文件头损坏")
        }
        let nameLen = Int(le16(data, localOffset + 26))
        let extraLen = Int(le16(data, localOffset + 28))
        let dataStart = localOffset + 30 + nameLen + extraLen
        let end = min(dataStart + Int(entry.compressedSize), data.count)
        guard dataStart <= end else { throw EPUBError.extractionFailed("条目数据越界") }
        let raw = data[dataStart..<end]

        let decompressed: Data
        switch entry.method {
        case 0:  // stored
            decompressed = Data(raw)
        case 8:  // deflate
            decompressed = try inflateRaw(Data(raw))
        default:
            throw EPUBError.unsupportedCompression
        }
        return String(data: decompressed, encoding: .utf8) ?? ""
    }

    /// raw deflate → 包装 zlib 头后用系统 zlib 解压
    private func inflateRaw(_ raw: Data) throws -> Data {
        let candidates: [Data] = [
            Data([0x78, 0x9c]) + raw,  // 默认压缩
            Data([0x78, 0x01]) + raw,  // 无/低压缩
            Data([0x78, 0xda]) + raw,  // 最佳压缩
        ]
        for candidate in candidates {
            if let result = try? candidate.decompressed(using: .zlib), !result.isEmpty {
                return result
            }
        }
        throw EPUBError.unsupportedCompression
    }

    // MARK: - 小端读取

    private func le16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }

    private func le32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    // MARK: - container.xml / OPF 解析

    private struct SpineItem {
        let href: String
        let title: String
    }

    private func parseContainerXML(_ xml: String) throws -> String {
        do {
            let doc = try SwiftSoup.parse(xml)
            guard let rootfile = (try? doc.select("rootfile")).first() else {
                throw EPUBError.noOPF
            }
            guard let path = (try? rootfile.attr("full-path")), !path.isEmpty else { throw EPUBError.noOPF }
            return path
        } catch let error as EPUBError {
            throw error
        } catch {
            throw EPUBError.extractionFailed(error.localizedDescription)
        }
    }

    private func parseOPF(_ xml: String, opfBase: String) throws -> [SpineItem] {
        do {
            let doc = try SwiftSoup.parse(xml)
            // manifest: id -> href
            var manifest: [String: String] = [:]
            var titles: [String: String] = [:]
            guard let manifestItems = (try? doc.select("manifest item")) else { return [] }
            for item in manifestItems {
                guard let id = (try? item.attr("id")), !id.isEmpty else { continue }
                guard let href = (try? item.attr("href")), !href.isEmpty else { continue }
                let title = (try? item.attr("title")) ?? ""
                manifest[id] = href
                if !title.isEmpty { titles[id] = title }
            }
            // spine itemref
            var spine: [SpineItem] = []
            guard let spineItems = (try? doc.select("spine itemref")) else { return [] }
            for itemref in spineItems {
                guard let idref = (try? itemref.attr("idref")) else { continue }
                guard let href = manifest[idref] else { continue }
                let title = titles[idref] ?? (href as NSString).deletingPathExtension
                spine.append(SpineItem(href: href, title: title))
            }
            return spine
        } catch let error as EPUBError {
            throw error
        } catch {
            throw EPUBError.extractionFailed(error.localizedDescription)
        }
    }

    /// 从 HTML 抽取正文文本（去掉脚本/样式，取 body 文本）
    private func extractText(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        // 去除脚本与样式内容
        try? doc.select("script, style").remove()
        let body = (try? doc.select("body")).first() ?? doc
        let text = (try? body.text()) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}