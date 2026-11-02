import Foundation

/// 订阅源（对应 legado rssSources 表，字段名与 legado 导出 JSON 对齐，保证导入/导出互通）
struct SubscriptionSource: Codable, Identifiable, Equatable {
    var sourceUrl: String = ""
    var sourceName: String = ""
    var sourceIcon: String = ""
    var sourceGroup: String = ""
    var enabled: Bool = true
    var sortUrl: String = ""
    /// 列表规则：legado ruleArticles 对象（ruleTitle / ruleLink / ruleContent ...），以 [String: String] 承载
    var ruleArticles: [String: String]? = nil
    var ruleNextPage: String = ""
    var ruleTitle: String = ""
    var rulePubDate: String = ""
    var ruleDescription: String = ""
    var ruleImage: String = ""
    var ruleLink: String = ""
    var ruleContent: String = ""
    /// 自定义请求头（legado 存为 JSON 字符串）
    var header: String = ""
    var enableJs: Bool = false
    var loadWithBaseUrl: Bool = true
    var customOrder: Int = 0

    var id: String { sourceUrl.isEmpty ? UUID().uuidString : sourceUrl }

    var typeName: String { "订阅" }

    // MARK: - 解析（单对象 / 数组 / {"sourceUrls": [...]} 包装）

    static func stripBOM(_ text: String) -> String {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析订阅源 JSON：先试单对象，再试数组；任一成功即返回
    static func decode(from text: String) throws -> [SubscriptionSource] {
        let cleaned = Self.stripBOM(text)
        guard !cleaned.isEmpty else {
            throw RuleError.invalidSource("输入内容为空")
        }
        let data = Data(cleaned.utf8)
        let decoder = JSONDecoder()

        let looksLikeArray = cleaned.hasPrefix("[")
        var objectError: Error?
        var arrayError: Error?

        do {
            return [try decoder.decode(SubscriptionSource.self, from: data)]
        } catch {
            objectError = error
        }
        do {
            return try decoder.decode([SubscriptionSource].self, from: data)
        } catch {
            arrayError = error
        }
        let primary = looksLikeArray ? (arrayError ?? objectError) : (objectError ?? arrayError)
        throw RuleError.invalidSource("订阅源 JSON 解析失败：\(primary?.localizedDescription ?? "未知错误")")
    }

    /// 提取 {"sourceUrls": [...]} 包装中的链接列表（legado 用 JsonPath 支持的形式），非该格式返回 nil
    static func extractSourceUrls(from text: String) -> [String]? {
        let cleaned = Self.stripBOM(text)
        guard cleaned.hasPrefix("{") else { return nil }
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let urls = dict["sourceUrls"] as? [String],
              !urls.isEmpty else { return nil }
        return urls
    }
}
