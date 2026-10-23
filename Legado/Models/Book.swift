import Foundation

/// 书籍格式
enum BookFormat: String, Codable, CaseIterable {
    case txt
    case epub
}

/// 书架书籍实体（对应 legado 的本地书籍 + 远程下载书籍）
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

    /// 规则阅读专用：书籍所在书源的 bookSourceUrl（为空表示本地书籍）
    var sourceId: String?
    /// 规则阅读专用：书籍在书源站点上的原始 URL（目录/正文抓取的起点）
    var bookUrl: String?

    var displayTitle: String { title.isEmpty ? "未命名" : title }

    /// 是否走规则阅读（需要书源 + 书籍 URL）
    var supportsRuleReading: Bool {
        (sourceId?.isEmpty ?? true) == false && (bookUrl?.isEmpty ?? true) == false
    }
}
