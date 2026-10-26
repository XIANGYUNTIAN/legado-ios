import Foundation

/// 并发搜索的简单信号量（actor 保证线程安全）。
/// 限流同时请求数，避免弱网下连接池耗尽或触发站点反爬。
private actor SearchSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { available = max(1, value) }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func release() {
        if let cont = waiters.first {
            waiters.removeFirst()
            cont.resume()
        } else {
            available += 1
        }
    }
}

/// searchUrl 解析结果：`url,{"method":...,"body":...,"headers":...,"charset":...}`。
struct ParsedSearchRequest {
    let url: String
    let method: String
    let body: String?
    let headers: [String: String]
    /// searchUrl 选项的 charset（如 gbk）；nil 表示未声明
    let charset: String?
}

/// 单源搜索的失败记录（用于逐源报错展示）
struct SourceSearchError: Identifiable {
    let id = UUID()
    let name: String
    let message: String
}

/// 搜索结果包（协调器在后台跑完后一次性回传，由 View 在 MainActor 应用）
struct SearchOutcome {
    var results: [ExploredBook] = []
    var errors: [SourceSearchError] = []
    var summary: String = ""
    var errorMessage: String?
    var progress: String?
}

/// 书籍搜索协调器：**独立于 SwiftUI View 的 main actor**。
///
/// 所有搜索算法（searchUrl 三阶段、per-element 解析、过滤、限流）都在这里以非隔离
/// 静态方法运行，因此被 `Task.detached` 调用时落在后台线程——JS 桥内的
/// `semaphore.wait`（同步网络）与 `startBrowserAwait` 的 `DispatchQueue.main.async`
/// 不再阻塞 UI 线程，彻底消除「一搜就卡死」的主线程死锁。
enum SearchCoordinator {

    /// 入口：遍历全部可搜索书源，按 ruleSearch 规则检索书籍。
    /// - Parameters:
    ///   - keyword: 已 trim 的关键词
    ///   - mode: 模糊 / 精确
    ///   - sources: 可搜索书源
    ///   - searchTimeout: 单源请求超时（秒）
    ///   - globalBudget: 全局搜索预算（秒）
    ///   - onProgress: 进度回调（在后台调用，调用方负责切回主线程）
    static func run(keyword: String,
                    mode: SearchMode,
                    sources: [BookSource],
                    searchTimeout: TimeInterval,
                    globalBudget: TimeInterval,
                    onProgress: (@Sendable (String) -> Void)? = nil) async -> SearchOutcome {
        // 批量搜索期间抑制 WebView UI：书源 JS 的 java.webView（素书卷过冷却等）
        // 降级为直接抓取，不弹登录页打断用户；退出时恢复，保留手动 Cookie 验证流
        JsJavaBridge.suppressWebViewUI = true
        defer { JsJavaBridge.suppressWebViewUI = false }
        var outcome = SearchOutcome()
        let total = sources.count
        let startTime = Date()
        var seen = Set<String>()
        var completed = 0
        var noMatchCount = 0
        var enqueued = 0
        let lock = NSLock()

        await withTaskGroup(of: [(ExploredBook, String?)].self) { group in
            // 并发档位：JS 桥的网络方法会阻塞协作线程（信号量等待），
            // 并发过高会耗尽协作线程池导致整体挂起——12 路是速度与稳定的平衡点
            let semaphore = SearchSemaphore(value: 12)

            for source in sources {
                if Task.isCancelled { break }
                // 全局预算到期：不再入队新源（在途请求仍受各自超时约束，尾部有界）
                if Date().timeIntervalSince(startTime) > globalBudget { break }
                await semaphore.wait()
                enqueued += 1
                // 入队即回传：开始阶段首批并发源还在等待响应时，
                // 用「已入队」计数给用户即时反馈，消除「长时间无进展」的假死观感
                onProgress?("已入队 \(enqueued)/\(total) 个书源 · 等待响应中…")

                group.addTask {
                    defer { Task.detached { await semaphore.release() } }
                    guard !Task.isCancelled else { return [] }
                    do {
                        let books = try await performSingleSourceSearch(
                            source: source, keyword: keyword, mode: mode, timeout: searchTimeout
                        )
                        return books.map { ($0, source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName) }
                    } catch {
                        guard !Task.isCancelled else { return [] }
                        let msg: String
                        if let ne = error as? NetworkError, case .cancelled = ne {
                            return []
                        } else {
                            msg = error.localizedDescription
                        }
                        return [(ExploredBook(name: "", author: "", intro: "", bookUrl: "", coverUrl: "", lastChapter: "", sourceId: source.bookSourceUrl, sourceName: sourceLabel(source)), msg)]
                    }
                }
            }

            for await pair in group {
                for item in pair {
                    if let msg = item.1 {
                        outcome.errors.append(SourceSearchError(name: item.0.sourceName, message: msg))
                    } else {
                        let book = item.0
                        let key = "\(book.name.lowercased())|\(book.author.lowercased())"
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        outcome.results.append(book)
                    }
                }
                lock.lock()
                completed += 1
                lock.unlock()
                let elapsed = Date().timeIntervalSince(startTime)
                onProgress?("已完成 \(completed)/\(total) 个书源 · \(String(format: "%.0fs", elapsed)) · 找到 \(outcome.results.count) 本")
            }
        }

        let timedOut = completed < total
        let failed = outcome.errors.count
        if outcome.results.isEmpty && failed == 0 {
            outcome.errorMessage = "全部书源均未搜索到「\(keyword)」"
        }
        // 始终暴露命中/失败分布，避免超时分支吞掉诊断信息。此前"完成 X/Y"无法区分
        // 网络失败与规则解析失败，是反复修不好的观测盲区；失败样例直接展示原因，
        // 便于定位是 URL 构造 / 网络 / 规则解析哪一环（对应 P1-6 错误可见性）。
        var summary = "📊 命中 \(outcome.results.count) 本 · 失败 \(failed) 个"
        if failed > 0 {
            // 失败分类计数：一眼区分「网络/死源」与「规则解析 bug」——前者需查网络，
            // 后者（bookList解析为空 / name提取全空 / JS规则失败）才是引擎要修的地方。
            var buckets: [String: Int] = [:]
            for err in outcome.errors {
                buckets[categorizeError(err.message), default: 0] += 1
            }
            let bucketLine = buckets.sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: "  ")
            summary += "\n失败分布：\(bucketLine)"
            let samples = outcome.errors.prefix(3).map { "· \($0.name)：\($0.message)" }
            summary += "\n失败样例：\n" + samples.joined(separator: "\n")
        }
        if timedOut {
            summary = "⏱ 已达 \(Int(globalBudget))s 全局预算，提前结束（完成 \(completed)/\(total)）\n" + summary
        }
        outcome.summary = summary
        return outcome
    }

    /// 失败原因归类（按关键词粗分），用于摘要里的分桶计数。
    private static func categorizeError(_ message: String) -> String {
        if message.contains("超时") { return "请求超时" }
        if message.contains("404") { return "HTTP404" }
        if message.contains("403") { return "HTTP403" }
        if message.contains("链接格式不正确") { return "链接格式" }
        if message.contains("JS 规则执行失败") { return "JS规则失败" }
        if message.contains("bookList 解析为空") { return "bookList空" }
        if message.contains("name 字段提取全部为空") { return "name提取空" }
        if message.contains("响应解码失败") { return "解码失败" }
        if message.contains("网络") { return "网络错误" }
        return "其他"
    }
    }

    // MARK: - searchUrl 三阶段流水线（对齐 legado AnalyzeUrl）

    /// 阶段一：`@js:` / `<js>` 求值。绑定 key / page / baseUrl / java / source / result / cookie。
    /// 非 JS 形态原样返回。
    private static func analyzeSearchUrlJS(_ raw: String, engine: RuleEngine, keyword: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.contains("@js:") || trimmed.contains("<js>") else {
            return raw
        }
        return try engine.evaluateSearchUrl(trimmed, keyword: keyword, page: 1)
    }

    /// 阶段二：占位符替换。`{{key}}` / `searchKey` → 编码后关键词；`{{page}}` / `searchPage` → 页码。
    private static func replaceKeyPage(_ urlString: String, keyword: String, page: Int = 1) -> String {
        let encoded = encodeSearchKey(keyword)
        var output = urlString
            .replacingOccurrences(of: "{{searchKey}}", with: "{{key}}")
            .replacingOccurrences(of: "{{searchPage}}", with: "{{page}}")
        output = output.replacingOccurrences(of: "{{key}}", with: encoded)
        output = output.replacingOccurrences(of: "searchKey", with: encoded)
        output = output.replacingOccurrences(of: "{{page}}", with: "\(page)")
        output = output.replacingOccurrences(of: "searchPage", with: "\(page)")
        return output
    }

    static let searchKeyAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert("/")
        allowed.remove("+")
        return allowed
    }()

    static func encodeSearchKey(_ keyword: String) -> String {
        keyword.addingPercentEncoding(withAllowedCharacters: searchKeyAllowed) ?? keyword
    }

    /// 单个书源搜索：三阶段求值 searchUrl → 发请求 → per-element 规则解析 → 按模式过滤。
    private static func performSingleSourceSearch(source: BookSource,
                                                 keyword: String,
                                                 mode: SearchMode,
                                                 timeout: TimeInterval? = nil) async throws -> [ExploredBook] {
        let rawSearchURL = source.searchUrl ?? ""
        guard !rawSearchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }

        let engine = RuleEngine()
        engine.setSource(source)
        engine.setBaseUrl(source.bookSourceUrl)
        engine.setChapter(title: nil, nextUrl: nil)

        let jsEvaluated = try analyzeSearchUrlJS(rawSearchURL, engine: engine, keyword: keyword)
        let urlStr = replaceKeyPage(jsEvaluated, keyword: keyword, page: 1)
        let request = parseSearchRequest(raw: urlStr)

        let isJSForm = rawSearchURL.lowercased().contains("@js:") || rawSearchURL.contains("<js>")
        if !isJSForm {
            let hasKeyPlaceholder = jsEvaluated.contains("{{key}}")
                || jsEvaluated.contains("searchKey")
                || urlStr.contains(encodeSearchKey(keyword))
            guard hasKeyPlaceholder else {
                throw NetworkError.invalidURL
            }
        }

        let encoded = encodeSearchKey(keyword)
        var finalURLString = request.url
        finalURLString = finalURLString.replacingOccurrences(of: "{{key}}", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "searchKey", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "{{searchPage}}", with: "1")
        finalURLString = finalURLString.replacingOccurrences(of: "searchPage", with: "1")
        if finalURLString.contains("{{") || finalURLString.contains("}}") {
            finalURLString = finalURLString
                .replacingOccurrences(of: "{{", with: "%7B%7B")
                .replacingOccurrences(of: "}}", with: "%7D%7D")
        }
        let finalURL: URL
        if let sanitized = URLSanitizer.sanitize(finalURLString) {
            finalURL = sanitized
        } else if let base = URLSanitizer.sanitize(source.bookSourceUrl),
                  let resolved = URL(string: finalURLString, relativeTo: base)?.absoluteURL {
            finalURL = resolved
        } else {
            throw NetworkError.invalidURL
        }
        guard let rules = source.ruleSearch, !(rules.bookList ?? "").isEmpty else {
            throw NetworkError.invalidURL
        }

        var mergedHeaders = sourceHeaders(source)
        for (key, value) in request.headers { mergedHeaders[key] = value }
        if mergedHeaders["Referer"] == nil && mergedHeaders["referer"] == nil,
           let base = URLSanitizer.sanitize(source.bookSourceUrl) {
            mergedHeaders["Referer"] = base.absoluteString
        }

        let html: String
        if request.method.uppercased() == "POST", let bodyTemplate = request.body {
            var finalBody = bodyTemplate
            finalBody = finalBody.replacingOccurrences(of: "{{key}}", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "searchKey", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "{{searchPage}}", with: "1")
            finalBody = finalBody.replacingOccurrences(of: "searchPage", with: "1")
            let bodyData: Data
            if let charset = request.charset,
               let encoding = NetworkService.encoding(named: charset) {
                bodyData = finalBody.data(using: encoding) ?? Data()
            } else {
                bodyData = finalBody.data(using: .utf8) ?? Data()
            }
            if let charset = request.charset {
                let (data, response) = try await NetworkService.shared.fetchDataWithBody(
                    from: finalURL, method: "POST", body: bodyData, headers: mergedHeaders, timeout: timeout
                )
                guard let decoded = try? NetworkService.decodeText(
                    data, charset: charset.isEmpty ? response.textEncodingName : charset
                ), !decoded.isEmpty else {
                    throw NSError(domain: "Search", code: -3,
                                  userInfo: [NSLocalizedDescriptionKey: "响应解码失败（charset=\(charset)）"])
                }
                html = decoded
            } else {
                html = try await NetworkService.shared.fetchTextWithBody(
                    from: finalURL, method: "POST", body: bodyData, headers: mergedHeaders, timeout: timeout
                )
            }
        } else if let charset = request.charset, !charset.isEmpty {
            let (data, response) = try await NetworkService.shared.fetchDataWithResponse(
                from: finalURL, headers: mergedHeaders, timeout: timeout
            )
            guard let decoded = try? NetworkService.decodeText(
                data, charset: charset.isEmpty ? response.textEncodingName : charset
            ), !decoded.isEmpty else {
                throw NSError(domain: "Search", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "响应解码失败（charset=\(charset)）"])
            }
            html = decoded
        } else {
            html = try await NetworkService.shared.fetchText(from: finalURL, headers: mergedHeaders, timeout: timeout)
        }

        let extracted = try extractSearchResults(
            html: html, rules: rules, source: source, base: finalURL, engine: engine
        )
        if Task.isCancelled { return [] }
        let sourceName = source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName
        return extracted
            .filter { matches($0, keyword: keyword, mode: mode) }
            .map { book in
                ExploredBook(
                    name: book.name,
                    author: book.author,
                    intro: book.intro,
                    bookUrl: book.bookUrl,
                    coverUrl: book.coverUrl,
                    lastChapter: book.lastChapter,
                    sourceId: source.bookSourceUrl,
                    sourceName: sourceName
                )
            }
    }

    /// 解析 legado 的 searchUrl：`url,{"method":"POST","body":"...","headers":{...}}`。
    private static func parseSearchRequest(raw: String) -> ParsedSearchRequest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ",{") else {
            return ParsedSearchRequest(url: trimmed, method: "GET", body: nil, headers: [:], charset: nil)
        }
        let urlPart = String(trimmed[trimmed.startIndex..<range.lowerBound])
        let optionsString = String(trimmed[range.lowerBound..<trimmed.endIndex]).dropFirst()
        guard let data = optionsString.data(using: .utf8) else {
            return ParsedSearchRequest(url: urlPart, method: "GET", body: nil, headers: [:], charset: nil)
        }
        let obj: [String: Any]?
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = result
        } else {
            let converted = optionsString.replacingOccurrences(of: "'", with: "\"")
            obj = try? JSONSerialization.jsonObject(
                with: converted.data(using: .utf8) ?? Data()
            ) as? [String: Any]
        }
        guard let obj else {
            return ParsedSearchRequest(url: urlPart, method: "GET", body: nil, headers: [:], charset: nil)
        }
        let method = (obj["method"] as? String) ?? "GET"
        let body = obj["body"] as? String
        let charset = obj["charset"] as? String
        var headers: [String: String] = [:]
        if let h = obj["headers"] as? [String: String] {
            headers = h
        } else {
            for (key, value) in obj where key != "method" && key != "body" {
                headers[key] = String(describing: value)
            }
        }
        return ParsedSearchRequest(url: urlPart, method: method, body: body, headers: headers, charset: charset)
    }

    /// 关键词与模式的匹配判定：书名 / 作者 / 简介（简介含主角名等线索）
    private static func matches(_ book: ExploredBook, keyword: String, mode: SearchMode) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return true }
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let intro = book.intro.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch mode {
        case .fuzzy:
            return name.contains(k) || author.contains(k) || intro.contains(k)
        case .precise:
            if name == k || author == k { return true }
            let separators = CharacterSet(charactersIn: "，,。.；;、\n\t（）()【】[]“”\"' 　")
            let tokens = intro.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return tokens.contains(k)
        }
    }

    private static func sourceLabel(_ source: BookSource) -> String {
        source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName
    }

    /// 解析书源 header 字段（JSON 字符串）为请求头字典。
    private static func sourceHeaders(_ source: BookSource) -> [String: String] {
        guard let raw = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            return [:]
        }
        let obj: [String: Any]?
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = result
        } else {
            let converted = raw.replacingOccurrences(of: "'", with: "\"")
            obj = try? JSONSerialization.jsonObject(
                with: converted.data(using: .utf8) ?? Data()
            ) as? [String: Any]
        }
        guard let obj else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in obj {
            if let text = value as? String {
                result[key] = text
            } else {
                result[key] = String(describing: value)
            }
        }
        return result
    }

    /// 按 ruleSearch 提取结果：bookList 求值产元素列表（CSS / JSON / 正则 / JS），
    /// 再逐元素求值 name / author / intro / bookUrl / coverUrl / lastChapter。
    private static func extractSearchResults(html: String,
                                            rules: SourceRuleSet,
                                            source: BookSource,
                                            base: URL,
                                            engine: RuleEngine) throws -> [ExploredBook] {
        let listRule = rules.bookList ?? ""
        guard !listRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }

        var ruleError: String?
        let items = BookListAnalyzer.items(rule: listRule, html: html, engine: engine, ruleError: &ruleError)
        if items.isEmpty {
            if let ruleError {
                throw RuleError.ruleFailed(ruleError)
            }
            // 解析静默为空：此前会被吞掉导致「无结果也无报错」，这里显式抛出便于诊断
            throw NSError(domain: "Search", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "bookList 解析为空（HTML 长度 \(html.count)）"])
        }

        var result: [ExploredBook] = []
        for item in items {
            let name = BookListAnalyzer.field(rules.name, item: item, engine: engine)
            guard !name.isEmpty else { continue }
            let bookUrlRaw = BookListAnalyzer.field(rules.bookUrl, item: item, engine: engine)
            // legado 基准：bookUrl 优先相对「搜索结果页（bookList 求值页）」解析，源根兜底。
            // 原顺序（先源根后搜索页）会让「相对搜索页目录」的详情 URL 解析到错误地址，
            // 进书架后目录/正文请求 404。
            let resolved = resolveURL(bookUrlRaw, base: base)
                ?? resolveURL(bookUrlRaw, base: source.bookSourceURL)
                ?? URLSanitizer.sanitize(bookUrlRaw)
            result.append(ExploredBook(
                name: name,
                author: BookListAnalyzer.field(rules.author, item: item, engine: engine),
                intro: BookListAnalyzer.field(rules.intro, item: item, engine: engine),
                bookUrl: resolved?.absoluteString ?? bookUrlRaw,
                coverUrl: BookListAnalyzer.field(rules.coverUrl, item: item, engine: engine),
                lastChapter: BookListAnalyzer.field(rules.lastChapter, item: item, engine: engine)
            ))
        }
        if result.isEmpty {
            // 静默空分支（此前被吞掉，无法区分 A 网络/规则不匹配 与 B 字段提取 bug）：
            // bookList 已命中元素，但逐元素的 name 字段全部提取为空。显式抛出错误，
            // 配合 e37a62b 的失败样例展示，下一轮可一眼定位是哪一类。
            throw NSError(domain: "Search", code: -5,
                          userInfo: [NSLocalizedDescriptionKey:
                            "bookList 命中 \(items.count) 个元素，但 name 字段提取全部为空（name 规则：『\(rules.name ?? "")』）"])
        }
        return result
    }

    private static func resolveURL(_ relative: String, base: URL?) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        guard let base else { return nil }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}
