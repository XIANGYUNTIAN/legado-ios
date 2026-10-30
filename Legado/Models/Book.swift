import Foundation

/// 书籍格式
enum BookFormat: String, Codable, CaseIterable {
    case txt
    case epub
    case pdf
    case docx
    case mobi
    case azw3
    case doc
}

/// 书架书籍实体（对应 legado 的本地书籍 + 远程下载书籍）
///
/// 自定义 Decodable：新增字段（阅读进度）在旧版 bookshelf.json 中不存在，
/// 合成 Decodable 不会使用默认值、缺键即失败，会导致书架被清空。
struct Book: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var author: String
    var format: BookFormat
    /// 相对 App Documents 的路径，形如 "Books/xxx.txt"
    var fileRelativePath: String?
    /// 远程来源链接（下载入库时保留以便溯源）
    var remoteURL: String?
    var addedAt: Date
    var fileSize: Int64?
    /// 书源名称快照（book.originName，JS 规则可用；加入书架时从书源复制）
    var originName: String?

    /// 规则阅读专用：书籍所在书源的 bookSourceUrl（为空表示本地书籍）
    var sourceId: String?
    /// 规则阅读专用：书籍在书源站点上的原始 URL（目录/正文抓取的起点）
    var bookUrl: String?

    /// 阅读进度：最近阅读的章节下标（跨会话恢复）
    var lastChapterIndex: Int = 0
    /// 阅读进度：最近阅读时间
    var lastReadAt: Date?

    var displayTitle: String { title.isEmpty ? "未命名" : title }

    /// 是否走规则阅读（需要书源 + 书籍 URL）
    var supportsRuleReading: Bool {
        (sourceId?.isEmpty ?? true) == false && (bookUrl?.isEmpty ?? true) == false
    }

    enum CodingKeys: String, CodingKey {
        case id, title, author, format
        case fileRelativePath, remoteURL, addedAt, fileSize
        case sourceId, bookUrl, originName
        case lastChapterIndex, lastReadAt
    }

    /// 显式成员初始化器（自定义 init(from:) 后合成成员初始化器被抑制，需手动补回）
    init(id: String = UUID().uuidString,
         title: String = "",
         author: String = "未知",
         format: BookFormat = .txt,
         fileRelativePath: String? = nil,
         remoteURL: String? = nil,
         addedAt: Date = Date(),
         fileSize: Int64? = nil,
         sourceId: String? = nil,
         bookUrl: String? = nil,
         originName: String? = nil,
         lastChapterIndex: Int = 0,
         lastReadAt: Date? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.fileRelativePath = fileRelativePath
        self.remoteURL = remoteURL
        self.addedAt = addedAt
        self.fileSize = fileSize
        self.sourceId = sourceId
        self.bookUrl = bookUrl
        self.originName = originName
        self.lastChapterIndex = lastChapterIndex
        self.lastReadAt = lastReadAt
    }

    /// 宽松解码：旧数据缺字段时用默认值兜底，保证升级不丢书架
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        author = (try? c.decodeIfPresent(String.self, forKey: .author)) ?? "未知"
        if let raw = try? c.decodeIfPresent(String.self, forKey: .format),
           let f = BookFormat(rawValue: raw) {
            format = f
        } else {
            format = .txt
        }
        fileRelativePath = try? c.decodeIfPresent(String.self, forKey: .fileRelativePath)
        remoteURL = try? c.decodeIfPresent(String.self, forKey: .remoteURL)
        addedAt = (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date()
        if let i = try? c.decodeIfPresent(Int64.self, forKey: .fileSize) {
            fileSize = i
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .fileSize) {
            fileSize = Int64(i)
        } else {
            fileSize = nil
        }
        sourceId = try? c.decodeIfPresent(String.self, forKey: .sourceId)
        bookUrl = try? c.decodeIfPresent(String.self, forKey: .bookUrl)
        originName = try? c.decodeIfPresent(String.self, forKey: .originName)
        lastChapterIndex = (try? c.decodeIfPresent(Int.self, forKey: .lastChapterIndex)) ?? 0
        lastReadAt = try? c.decodeIfPresent(Date.self, forKey: .lastReadAt)
    }
}
