import Foundation
import CoreFoundation

/// 从链接抓取书源时可能出现的错误，便于在导入界面给出可读提示
enum SourceFetchError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case emptyResponse
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接格式不正确"
        case .badStatus(let code): return "服务器返回 HTTP \(code)，链接可能已失效"
        case .emptyResponse: return "服务器返回内容为空"
        case .encodingFailed: return "无法解码返回内容（非文本）"
        }
    }
}

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

    /// 仅当输入为单行 http(s) 链接时返回 URL，避免把多行 JSON 误判为链接
    static func linkIfAny(_ text: String) -> URL? {
        guard !text.contains("\n"), !text.contains("\r") else { return nil }
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URL(string: text)
    }

    /// 抓取远端文本（书源 JSON），附带移动端 UA 以规避部分站点拦截
    static func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourceFetchError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw SourceFetchError.emptyResponse }

        if let text = String(data: data, encoding: .utf8) {
            return Self.stripBOM(text)
        }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return Self.stripBOM(text)
        }
        throw SourceFetchError.encodingFailed
    }

    static func stripBOM(_ text: String) -> String {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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
