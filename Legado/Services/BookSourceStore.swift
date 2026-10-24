import Foundation
import CoreFoundation

/// 从链接抓取书源时可能出现的错误，便于在导入界面给出可读提示
enum SourceFetchError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case emptyResponse
    case encodingFailed
    case timeout
    case cancelled
    case networkFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接格式不正确（需 http/https 链接，且不含非法字符）"
        case .badStatus(let code): return "服务器返回 HTTP \(code)，链接可能已失效"
        case .emptyResponse: return "服务器返回内容为空"
        case .encodingFailed: return "无法解码返回内容（非文本）"
        case .timeout: return "请求超时，请检查网络或稍后重试"
        case .cancelled: return "请求已取消"
        case .networkFailed(let msg): return "网络错误：\(msg)"
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

    /// 导入 legado 书源 JSON（单对象、数组或 {"sourceUrls": [...]} 包装），按 bookSourceUrl 去重更新
    @discardableResult
    func importSources(from text: String) async throws -> Int {
        // 1) {"sourceUrls": [...]} 包装：逐条抓取后导入（对应 legado JsonPath 分支）
        if let urls = BookSource.extractSourceUrls(from: text) {
            var total = 0
            var lastError: Error?
            for raw in urls {
                guard let url = URL(string: raw) else { continue }
                do {
                    let body = try await Self.fetchText(from: url)
                    total += try await importSources(from: body)
                } catch {
                    lastError = error
                }
            }
            if total == 0 {
                throw lastError ?? RuleError.invalidSource("\(urls.count) 个书源链接全部导入失败")
            }
            return total
        }

        // 2) 普通书源 JSON（单对象或数组）
        let imported = try BookSource.decode(from: text).filter { !$0.bookSourceUrl.isEmpty }
        guard !imported.isEmpty else {
            throw RuleError.invalidSource("解析到内容但均缺少 bookSourceUrl 字段，不是有效书源")
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

    /// 二维码/链接统一入口：单行 http(s) 链接先抓取再解析；否则按 JSON 文本解析
    @discardableResult
    func importFromTextOrLink(_ input: String) async throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuleError.invalidSource("扫描内容为空") }
        if let url = Self.linkIfAny(trimmed) {
            let body = try await Self.fetchText(from: url)
            return try await importSources(from: body)
        }
        return try await importSources(from: trimmed)
    }

    /// 仅当输入为单行 http(s) 链接时返回 URL，避免把多行 JSON 误判为链接。
    /// 经 URLSanitizer 修复非法字符（空格/中文），否则 URLSession 会抛
    /// "unsupported URL" 且被误报为解码失败。
    static func linkIfAny(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URLSanitizer.sanitize(trimmed)
    }

    /// 抓取远端文本（书源 JSON），委托给统一网络层（移动端 UA + UTF-8/GB18030 解码）
    static func fetchText(from url: URL) async throws -> String {
        do {
            return try await NetworkService.shared.fetchText(
                from: url,
                headers: ["Accept": "application/json, text/plain, */*"]
            )
        } catch let error as NetworkError {
            throw Self.mapNetworkError(error)
        } catch {
            throw SourceFetchError.networkFailed(error.localizedDescription)
        }
    }

    /// 保留旧接口语义（去除 BOM / 首尾空白），供其他模块复用
    static func stripBOM(_ text: String) -> String {
        NetworkService.stripBOM(text)
    }

    /// 将网络层错误映射为书源抓取错误。
    /// 注意：旧版 default 分支把 invalidURL / timeout / network 全部映射成
    /// encodingFailed，导致真实原因（如 URL 非法、超时）被"无法解码返回内容
    /// （非文本）"掩盖，必须逐 case 映射。
    private static func mapNetworkError(_ error: NetworkError) -> Error {
        switch error {
        case .invalidURL: return SourceFetchError.invalidURL
        case .badStatus(let code): return SourceFetchError.badStatus(code)
        case .emptyResponse: return SourceFetchError.emptyResponse
        case .encodingFailed: return SourceFetchError.encodingFailed
        case .timeout: return SourceFetchError.timeout
        case .cancelled: return SourceFetchError.cancelled
        case .network(let message): return SourceFetchError.networkFailed(message)
        }
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

    /// 批量删除（按书源 URL 集合），供列表勾选后一键删除
    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        sources.removeAll { set.contains($0.bookSourceUrl) }
        persist()
    }
}
