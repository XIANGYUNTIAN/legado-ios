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

    // MARK: - 宽松解码（对齐 BookSource 的容错策略）
    //
    // 关键：Swift 合成 Decodable 不会使用属性默认值——非可选字段的键一旦缺失就抛
    // keyNotFound，而 legado 导出的订阅源 JSON 常省略个别字段（如 sortUrl / ruleImage），
    // 也会把 enabled / enableJs 等 Boolean 写成字符串 "true"/"false"。直接用合成解码器
    // 必然整体失败（表现为「扫码 / 网址导入均解析不了」）。因此改为逐项 decodeIfPresent
    // + 类型宽松强转，缺失或类型不符都不影响其它字段。

    enum CodingKeys: String, CodingKey {
        case sourceUrl, sourceName, sourceIcon, sourceGroup, enabled, sortUrl
        case ruleArticles, ruleNextPage, ruleTitle, rulePubDate, ruleDescription
        case ruleImage, ruleLink, ruleContent, header, enableJs, loadWithBaseUrl, customOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceUrl = Self.ls(c, .sourceUrl) ?? ""
        sourceName = Self.ls(c, .sourceName) ?? ""
        sourceIcon = Self.ls(c, .sourceIcon) ?? ""
        sourceGroup = Self.ls(c, .sourceGroup) ?? ""
        enabled = Self.lb(c, .enabled, default: true)
        sortUrl = Self.ls(c, .sortUrl) ?? ""
        ruleArticles = try? c.decodeIfPresent([String: String].self, forKey: .ruleArticles)
        ruleNextPage = Self.ls(c, .ruleNextPage) ?? ""
        ruleTitle = Self.ls(c, .ruleTitle) ?? ""
        rulePubDate = Self.ls(c, .rulePubDate) ?? ""
        ruleDescription = Self.ls(c, .ruleDescription) ?? ""
        ruleImage = Self.ls(c, .ruleImage) ?? ""
        ruleLink = Self.ls(c, .ruleLink) ?? ""
        ruleContent = Self.ls(c, .ruleContent) ?? ""
        header = Self.ls(c, .header) ?? ""
        enableJs = Self.lb(c, .enableJs, default: false)
        loadWithBaseUrl = Self.lb(c, .loadWithBaseUrl, default: true)
        customOrder = Self.li(c, .customOrder)
    }

    private static func ls(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    private static func lb(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, default def: Bool) -> Bool {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off", "": return false
            default: return def
            }
        }
        return def
    }

    private static func li(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
    }

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
