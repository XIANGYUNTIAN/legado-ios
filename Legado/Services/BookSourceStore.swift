import Foundation

/// 书源本地存储（P0：Documents/book_sources.json，对应 Room book_sources 表的子集）
final class BookSourceStore: ObservableObject {
    @Published private(set) var sources: [BookSource] = []

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = documents.appendingPathComponent("book_sources.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BookSource].self, from: data) else {
            return
        }
        sources = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 导入 legado 书源 JSON（单对象或数组），按 bookSourceUrl 去重更新
    @discardableResult
    func importSources(from text: String) throws -> Int {
        let imported = try BookSource.decode(from: text).filter { !$0.bookSourceUrl.isEmpty }
        guard !imported.isEmpty else {
            throw RuleError.invalidJSON
        }
        for source in imported {
            if let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                sources[index] = source
            } else {
                sources.append(source)
            }
        }
        persist()
        return imported.count
    }

    func toggle(_ source: BookSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].enabled.toggle()
        persist()
    }

    func delete(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        persist()
    }
}
