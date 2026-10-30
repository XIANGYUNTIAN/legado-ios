import Foundation
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
        let archive = try ZipArchive.open(url: epubURL)

        guard let containerEntry = archive.entry(named: "META-INF/container.xml") else {
            throw EPUBError.noContainerXML
        }
        let containerXML = try archive.readString(containerEntry)
        let opfPath = try parseContainerXML(containerXML)
        guard let opfEntry = archive.entry(named: opfPath) else {
            throw EPUBError.noOPF
        }
        let opfXML = try archive.readString(opfEntry)
        let spine = try parseOPF(opfXML, opfBase: (opfPath as NSString).deletingPathExtension)
        guard !spine.isEmpty else { throw EPUBError.noOPF }

        let opfDir = (opfPath as NSString).deletingPathExtension
            .split(separator: "/").dropLast().joined(separator: "/")
        var chapters: [EPUBChapter] = []
        for item in spine {
            let fullPath = opfDir.isEmpty ? item.href : (opfDir + "/" + item.href)
            guard let entry = archive.entry(named: fullPath) else { continue }
            let html = (try? archive.readString(entry)) ?? ""
            let text = (try? extractText(html)) ?? ""
            chapters.append(EPUBChapter(href: fullPath, title: item.title, text: text))
        }
        return chapters
    }

    // MARK: - container.xml / OPF 解析

    private struct SpineItem {
        let href: String
        let title: String
    }

    private func parseContainerXML(_ xml: String) throws -> String {
        do {
            let doc = try SwiftSoup.parse(xml)
            guard let rootfile = (try? doc.select("rootfile"))?.first() else {
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
        let body = (try? doc.select("body"))?.first() ?? doc
        let text = (try? body.text()) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}