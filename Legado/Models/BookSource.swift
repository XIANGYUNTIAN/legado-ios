import Foundation

/// 书源类型（对应 legado BookSource.bookSourceType）
enum BookSourceType: Int, Codable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
    case video = 4
}

/// 书源规则集：字段与 legado 书源 JSON 的 ruleSearch / ruleExplore /
/// ruleBookInfo / ruleToc / ruleContent 完全对齐，未使用的字段留空。
///
/// 解码策略（对齐 GSON 的宽松语义）：
/// - 所有字段可选，缺失 / null 均解析为 nil，绝不因单个字段失败；
/// - 规则值在个别书源里可能是数字或布尔，统一强转为字符串。
struct SourceRuleSet: Codable, Equatable {
    // 搜索 / 发现（BookListRule）
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
    // 详情（BookInfoRule）
    var initRule: String?
    var tocUrl: String?
    var downloadUrls: String?
    // 目录（TocRule）
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVolume: String?
    var nextTocUrl: String?
    // 正文（ContentRule）
    var content: String?
    var nextContentUrl: String?
    var subContent: String?
    var title: String?

    /// initRule 的 JSON 键名为 "init"（避开关键字作为 CodingKey 用例）
    enum CodingKeys: String, CodingKey {
        case bookList, name, author, intro, kind, lastChapter, bookUrl, coverUrl, wordCount
        case initRule = "init", tocUrl, downloadUrls
        case chapterList, chapterName, chapterUrl, isVolume, nextTocUrl
        case content, nextContentUrl, subContent, title
    }

    init() {}

    /// 宽松解码：字段缺失 / null → nil；数字、布尔强转为字符串。
    /// 这样即使第三方工具导出的规则对象类型不纯，也不会整体导入失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookList = Self.lenientString(c, .bookList)
        name = Self.lenientString(c, .name)
        author = Self.lenientString(c, .author)
        intro = Self.lenientString(c, .intro)
        kind = Self.lenientString(c, .kind)
        lastChapter = Self.lenientString(c, .lastChapter)
        bookUrl = Self.lenientString(c, .bookUrl)
        coverUrl = Self.lenientString(c, .coverUrl)
        wordCount = Self.lenientString(c, .wordCount)
        initRule = Self.lenientString(c, .initRule)
        tocUrl = Self.lenientString(c, .tocUrl)
        downloadUrls = Self.lenientString(c, .downloadUrls)
        chapterList = Self.lenientString(c, .chapterList)
        chapterName = Self.lenientString(c, .chapterName)
        chapterUrl = Self.lenientString(c, .chapterUrl)
        isVolume = Self.lenientString(c, .isVolume)
        nextTocUrl = Self.lenientString(c, .nextTocUrl)
        content = Self.lenientString(c, .content)
        nextContentUrl = Self.lenientString(c, .nextContentUrl)
        subContent = Self.lenientString(c, .subContent)
        title = Self.lenientString(c, .title)
    }

    /// 依次尝试 String → Int → Double → Bool，覆盖书源 JSON 里个别非字符串规则值
    private static func lenientString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    var isEmpty: Bool {
        [bookList, name, author, intro, kind, lastChapter, bookUrl, coverUrl, wordCount,
         initRule, tocUrl, downloadUrls, chapterList, chapterName, chapterUrl, isVolume,
         nextTocUrl, content, nextContentUrl, subContent, title]
            .allSatisfy { $0?.isEmpty ?? true }
    }
}

/// 书源实体：与 legado BookSource JSON 一一对应。
///
/// 解码策略（对齐 GSON 的宽松语义，这是修复「不是合法的书源 JSON」误报的关键）：
/// Swift 合成 Decodable **不会使用属性默认值**——非可选字段的键一旦缺失就整体抛
/// keyNotFound。legado 原生模型里 `bookSourceComment` 等字段可空，GSON 导出时直接
/// 省略该键，于是用户从阅读 App 导出的书源 JSON 普遍缺少这些键，导入必然失败。
/// 因此这里全部改为 `decodeIfPresent` + 默认值，并对类型做宽松强转。
struct BookSource: Codable, Identifiable, Equatable {
    var bookSourceUrl: String = ""

    /// 书源基准 URL（用于拼接相对路径）。bookSourceUrl 可能是相对路径或非法链接，
    /// 此处只做 best-effort 解析，失败则返回 nil（调用方需自行处理）。
    var bookSourceURL: URL? {
        URLSanitizer.sanitize(bookSourceUrl)
            ?? URL(string: bookSourceUrl)
    }
    var bookSourceName: String = ""
    var bookSourceGroup: String?
    var bookSourceType: BookSourceType = .text
    var bookSourceComment: String = ""
    var enabled: Bool = true
    var enabledExplore: Bool = true
    var header: String?
    var loginUrl: String?
    /// 书源级持久变量（对应 legado BaseSource.variable，source.getVariable/setVariable 读写）
    var variable: String?
    /// 登录信息键值表（source.getLoginInfoMap 读取，如「密钥」）
    var loginInfo: [String: String]?
    var jsLib: String?
    var concurrentRate: String?
    var exploreUrl: String?
    /// 搜索地址（legado 书源 JSON 的 searchUrl，含 {{key}} 占位符）
    var searchUrl: String?
    var lastUpdateTime: Int64 = 0
    var ruleSearch: SourceRuleSet?
    var ruleBookInfo: SourceRuleSet?
    var ruleToc: SourceRuleSet?
    var ruleContent: SourceRuleSet?
    var ruleExplore: SourceRuleSet?

    var id: String { bookSourceUrl }

    var typeName: String {
        switch bookSourceType {
        case .text: return "文本"
        case .audio: return "音频"
        case .image: return "图片"
        case .file: return "文件"
        case .video: return "视频"
        }
    }

    /// exploreUrl 是否为可直接请求的链接。
    /// legado 的 exploreUrl 大量是 `@js:` / 多行 / 带 {{}} 的规则串，
    /// 直接交给 URLSession 会抛 "unsupported URL"（打开已存书源即报错）。
    var hasUsableExploreUrl: Bool {
        guard let raw = exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        if raw.contains("\n") || raw.contains("{{") { return false }
        let lower = raw.lowercased()
        if lower.hasPrefix("@js:") || lower.hasPrefix("<js>") || lower.hasPrefix("@@") { return false }
        return URLSanitizer.sanitize(raw) != nil
    }

    /// 是否具备搜索能力（搜索地址 + 搜索规则容器）。
    /// 占位符兼容两种：新格式 `{{key}}` 与遗留格式 `searchKey`
    /// （legado ImportOldData 会把 searchKey 替换为 {{key}}，说明存量书源
    /// 大量使用 searchKey，原生默认书源即是如此）。
    /// `@js:` / `<js>` 型 searchUrl 由 JS 通过 key 绑定自行构造地址，
    /// 不要求字面占位符（legado AnalyzeUrl 语义）。
    var supportsSearch: Bool {
        guard let raw = searchUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        // @js: / <js> / @@ 前缀的搜索地址走 JS 引擎，跳过 URL 格式与占位符校验
        let lower = raw.lowercased()
        if lower.hasPrefix("@js:") || lower.hasPrefix("<js>") || lower.hasPrefix("@@") {
            guard let list = ruleSearch?.bookList, !list.isEmpty else { return false }
            return true
        }
        guard raw.contains("{{key}}") || raw.contains("searchKey") else { return false }
        // 地址部分（截掉 ,{"method":...} 选项后缀）。
        // 相对地址（无 scheme，如 /search?kw={{key}}）由调用方拼接书源基准 URL，
        // 此处只拒绝明显非法的地址（非相对路径、非绝对 URL）。
        let address = raw.components(separatedBy: ",{").first ?? raw
        if URLSanitizer.sanitize(address) == nil,
           !address.hasPrefix("/") {
            return false
        }
        guard let list = ruleSearch?.bookList, !list.isEmpty else { return false }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType
        case bookSourceComment, enabled, enabledExplore
        case header, loginUrl, variable, loginInfo, jsLib, concurrentRate, exploreUrl, searchUrl, lastUpdateTime
        case ruleSearch, ruleBookInfo, ruleToc, ruleContent, ruleExplore
    }

    /// 宽松解码：缺失 / null → 默认值；类型不符 → 尽力强转，绝不整体失败。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = Self.lenientString(c, .bookSourceUrl) ?? ""
        bookSourceName = Self.lenientString(c, .bookSourceName) ?? ""
        bookSourceGroup = Self.lenientString(c, .bookSourceGroup)
        bookSourceType = Self.lenientSourceType(c)
        bookSourceComment = Self.lenientString(c, .bookSourceComment) ?? ""
        enabled = Self.lenientBool(c, .enabled, default: true)
        enabledExplore = Self.lenientBool(c, .enabledExplore, default: true)
        header = Self.lenientString(c, .header)
        loginUrl = Self.lenientString(c, .loginUrl)
        variable = Self.lenientString(c, .variable)
        loginInfo = Self.lenientStringMap(c, .loginInfo)
        jsLib = Self.lenientString(c, .jsLib)
        concurrentRate = Self.lenientString(c, .concurrentRate)
        exploreUrl = Self.lenientString(c, .exploreUrl)
        searchUrl = Self.lenientString(c, .searchUrl)
        lastUpdateTime = Self.lenientInt64(c, .lastUpdateTime)
        ruleSearch = try? c.decodeIfPresent(SourceRuleSet.self, forKey: .ruleSearch)
        ruleBookInfo = try? c.decodeIfPresent(SourceRuleSet.self, forKey: .ruleBookInfo)
        ruleToc = try? c.decodeIfPresent(SourceRuleSet.self, forKey: .ruleToc)
        ruleContent = try? c.decodeIfPresent(SourceRuleSet.self, forKey: .ruleContent)
        ruleExplore = try? c.decodeIfPresent(SourceRuleSet.self, forKey: .ruleExplore)
    }

    // MARK: - 宽松字段读取

    private static func lenientString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    private static func lenientBool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, default def: Bool) -> Bool {
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

    private static func lenientInt64(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64 {
        if let i = try? c.decodeIfPresent(Int64.self, forKey: key) { return i }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Int64(i) }
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return 0
    }

    /// 宽松字符串字典解码：仅接受全字符串值（loginInfo 的键值均为字符串，如「密钥」）；
    /// 结构不符整体忽略，不影响书源导入
    private static func lenientStringMap(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: String]? {
        guard let raw = try? c.decodeIfPresent([String: String].self, forKey: key), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private static func lenientSourceType(_ c: KeyedDecodingContainer<CodingKeys>) -> BookSourceType {
        if let i = try? c.decodeIfPresent(Int.self, forKey: .bookSourceType) {
            return BookSourceType(rawValue: i) ?? .text
        }
        if let s = try? c.decodeIfPresent(String.self, forKey: .bookSourceType) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return BookSourceType(rawValue: Int(trimmed) ?? 0) ?? .text
        }
        return .text
    }

    // MARK: - 导入解析

    /// 支持单对象、数组两种 legado 书源 JSON 形式。
    /// 解析失败时抛出带真实原因的错误（不再笼统报「不是合法的书源 JSON」）。
    static func decode(from text: String) throws -> [BookSource] {
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
            return [try decoder.decode(BookSource.self, from: data)]
        } catch {
            objectError = error
        }
        do {
            return try decoder.decode([BookSource].self, from: data)
        } catch {
            arrayError = error
        }
        let primary = looksLikeArray ? (arrayError ?? objectError) : (objectError ?? arrayError)
        throw RuleError.invalidSource("书源 JSON 解析失败：\(Self.describe(primary))")
    }

    /// 提取 `{"sourceUrls": [...]}` 包装中的书源链接列表（legado 用 JsonPath 支持的形式）。
    /// 返回 nil 表示不是该包装格式，按普通书源 JSON 处理。
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

    /// 去除 UTF-8 BOM 并修剪首尾空白（粘贴 / 抓取的内容都可能带 BOM）
    static func stripBOM(_ text: String) -> String {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 DecodingError 翻译成用户可操作的中文提示
    private static func describe(_ error: Error?) -> String {
        guard let error else { return "格式无法识别" }
        guard let dec = error as? DecodingError else {
            return error.localizedDescription
        }
        switch dec {
        case .keyNotFound(let key, _):
            return "缺少字段 \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "字段 \"\(path)\" 类型应为 \(type)"
        case .valueNotFound(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "字段 \"\(path)\" 的 \(type) 值为空"
        case .dataCorrupted(let context):
            return "JSON 结构损坏（\(context.debugDescription)）"
        @unknown default:
            return error.localizedDescription
        }
    }
}
