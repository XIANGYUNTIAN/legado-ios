import Foundation
import CoreFoundation

/// 订阅源本地存储（对应 legado rssSources 表，持久化于 Documents/rss_sources.json）
final class SubscriptionSourceStore: ObservableObject {
    @Published private(set) var sources: [SubscriptionSource] = []

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = documents.appendingPathComponent("rss_sources.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SubscriptionSource].self, from: data) else {
            return
        }
        sources = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 导入 legado 订阅源 JSON（单对象、数组或 {"sourceUrls": [...]} 包装），按 sourceUrl 去重更新
    @discardableResult
    func importSources(from text: String) async throws -> Int {
        if let urls = SubscriptionSource.extractSourceUrls(from: text) {
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
                throw lastError ?? RuleError.invalidSource("\(urls.count) 个订阅源链接全部导入失败")
            }
            return total
        }

        let imported = try SubscriptionSource.decode(from: text).filter { !$0.sourceUrl.isEmpty }
        guard !imported.isEmpty else {
            throw RuleError.invalidSource("解析到内容但均缺少 sourceUrl 字段，不是有效订阅源")
        }
        for source in imported {
            if let index = sources.firstIndex(where: { $0.sourceUrl == source.sourceUrl }) {
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

    /// 仅当输入为单行 http(s) 链接时返回 URL（避免把多行 JSON 误判为链接）
    static func linkIfAny(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URLSanitizer.sanitize(trimmed)
    }

    /// 抓取远端文本（订阅源 JSON），复用统一网络层（移动端 UA + UTF-8/GB18030 解码）
    static func fetchText(from url: URL) async throws -> String {
        do {
            return try await NetworkService.shared.fetchText(
                from: url,
                headers: ["Accept": "application/json, text/plain, */*"]
            )
        } catch let error as NetworkError {
            switch error {
            case .invalidURL: throw SourceFetchError.invalidURL
            case .badStatus(let code): throw SourceFetchError.badStatus(code)
            case .emptyResponse: throw SourceFetchError.emptyResponse
            case .encodingFailed: throw SourceFetchError.encodingFailed
            case .timeout: throw SourceFetchError.timeout
            case .cancelled: throw SourceFetchError.cancelled
            case .network(let message): throw SourceFetchError.networkFailed(message)
            }
        } catch {
            throw SourceFetchError.networkFailed(error.localizedDescription)
        }
    }

    func toggle(_ source: SubscriptionSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].enabled.toggle()
        persist()
    }

    func delete(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        persist()
    }

    /// 批量删除（按 sourceUrl 集合），供列表勾选后一键删除
    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        let set = Set(ids)
        sources.removeAll { set.contains($0.sourceUrl) }
        persist()
    }

    /// 序列化全部订阅源为 legado 兼容 JSON 文本（导出用）
    func exportText() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sources)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceFetchError.encodingFailed
        }
        return text
    }
}
