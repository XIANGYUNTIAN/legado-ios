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

    var displayTitle: String { title.isEmpty ? "未命名" : title }
}
