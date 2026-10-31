import Foundation

/// 阅读页位置持久化：记录每本书的「退出时所在页」。
///
/// 存 (chapterIndex, offset)——offset 是当前页在章内的字符偏移（页面起始字符位置）。
/// 之所以存字符偏移而非页序号：字号/行距/字距变化后分页会重排，页序号失效，
/// 字符偏移仍能定位到大致相同的内容位置。重新进入时按 offset 找页，满足
/// 「下次进入回到退出前页面」而非「只回到退出前章节」。
@MainActor
final class PagePositionStore {
    static let shared = PagePositionStore()

    private struct Record: Codable {
        var chapter: Int
        var offset: Int
    }

    private var records: [String: Record] = [:]
    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = docs.appendingPathComponent("page_position.json")
        load()
    }

    /// 读取某本书退出时所在章的页 offset（无记录返回 nil）
    func offset(bookId: String?, chapter: Int) -> Int? {
        guard let bookId, let r = records[bookId], r.chapter == chapter else { return nil }
        return r.offset
    }

    /// 保存页位置（bookId 为空时不持久化，避免污染）
    func save(bookId: String?, chapter: Int, offset: Int) {
        guard let bookId, chapter >= 0, offset >= 0 else { return }
        records[bookId] = Record(chapter: chapter, offset: offset)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return
        }
        records = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
