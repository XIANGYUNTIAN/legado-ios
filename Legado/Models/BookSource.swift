import Foundation

/// 书源类型（对应 legado BookSource.bookSourceType）
enum BookSourceType: Int, Codable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
    case video = 4
}

/// 书源规则集：字段与 legado 书源 JSON 的 ruleSearch / ruleExplore /
/// ruleBookInfo / ruleToc / ruleContent 完全对齐，未使用的字段留空。
struct SourceRuleSet: Codable, Equatable {
    // 搜索 / 发现（BookListRule）
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
    // 详情（BookInfoRule）
    var `init`: String?
    var tocUrl: String?
    var downloadUrls: String?
    // 目录（TocRule）
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVolume: String?
    var nextTocUrl: String?
    // 正文（ContentRule）
    var content: String?
    var nextContentUrl: String?
    var subContent: String?
    var title: String?

    enum CodingKeys: String, CodingKey {
        case bookList, name, author, intro, kind, lastChapter, bookUrl, coverUrl, wordCount
        case `init`, tocUrl, downloadUrls
        case chapterList, chapterName, chapterUrl, isVolume, nextTocUrl
        case content, nextContentUrl, subContent, title
    }

    var isEmpty: Bool {
        [bookList, name, author, intro, kind, lastChapter, bookUrl, coverUrl, wordCount,
         `init`, tocUrl, downloadUrls, chapterList, chapterName, chapterUrl, isVolume,
         nextTocUrl, content, nextContentUrl, subContent, title]
            .allSatisfy { $0?.isEmpty ?? true }
    }
}

/// 书源实体：与 legado BookSource JSON 一一对应。
/// 所有可选字段均带默认值，保证数组中个别字段异常不会导致整体导入失败。
struct BookSource: Codable, Identifiable, Equatable {
    var bookSourceUrl: String = ""
    var bookSourceName: String = ""
    var bookSourceGroup: String?
    var bookSourceType: BookSourceType = .text
    var bookSourceComment: String = ""
    var enabled: Bool = true
    var enabledExplore: Bool = true
    var header: String?
    var loginUrl: String?
    var jsLib: String?
    var concurrentRate: String?
    var exploreUrl: String?
    var lastUpdateTime: Int64 = 0
    var ruleSearch: SourceRuleSet?
    var ruleBookInfo: SourceRuleSet?
    var ruleToc: SourceRuleSet?
    var ruleContent: SourceRuleSet?
    var ruleExplore: SourceRuleSet?

    var id: String { bookSourceUrl }

    var typeName: String {
        switch bookSourceType {
        case .text: return "文本"
        case .audio: return "音频"
        case .image: return "图片"
        case .file: return "文件"
        case .video: return "视频"
        }
    }

    /// 支持单个书源对象或书源数组（对应 ImportBookSourceViewModel 的四种输入之一）
    static func decode(from text: String) throws -> [BookSource] {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(BookSource.self, from: data) {
            return [single]
        }
        if let array = try? decoder.decode([BookSource].self, from: data) {
            return array
        }
        throw RuleError.invalidJSON
    }
}
