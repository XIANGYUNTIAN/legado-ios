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
    /// 诊断探针：正常返回但 0 命中的源及其最终搜索 URL（供 Safari 人工验证定性）
    var probeURLs: [String] = []
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
                    onProgress: (@Sendable (String) -> Void)? = nil,
                    onStream: (@Sendable ([ExploredBook], [SourceSearchError]) -> Void)? = nil,
                    hitTarget: Int = 20) async -> SearchOutcome {
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
        var stopEnqueue = false
        let lock = NSLock()

        await withTaskGroup(of: [(ExploredBook, String?)].self) { group in
            // 并发档位：JS 桥的网络方法会阻塞协作线程（信号量等待），
            // 并发过高会耗尽协作线程池导致整体挂起——12 路是速度与稳定的平衡点
            let semaphore = SearchSemaphore(value: 12)

            for source in sources {
                if Task.isCancelled { break }
                // 命中达标 / 全局预算到期：不再入队新源（在途请求自然收尾，尾部有界）。
                // 600s 预算被失败源耗满是 0 命中的放大器：命中 hitTarget 本即停，
                // 让结果在 1-3 分钟内落地，而非 10 分钟后才可能出结果。
                lock.lock(); let shouldStop = stopEnqueue; lock.unlock()
                if shouldStop { break }
                if Date().timeIntervalSince(startTime) > globalBudget { break }
                await semaphore.wait()
                enqueued += 1
                // 入队即回传：开始阶段首批并发源还在等待响应时，
                // 用「已入队」计数给用户即时反馈，消除「长时间无进展」的假死观感
                onProgress?("已入队 \(enqueued)/\(total) 个书源 · 等待响应中…")

                group.addTask {
                    // 完成即聚合 + 流式上屏：把结果收集放进每个任务的完成回调，
                    // 而非依赖末尾的 for-await 消费循环。此前 onStream 挂在 for-await，
                    // 而 for-await 要等入队循环（12 并发满时 await 阻塞）全部跑完才开始，
                    // 导致整个入队阶段（数百秒）onStream 一次未触发——即"长时间停在已入队"。
                    let resultPair: [(ExploredBook, String?)]
                    do {
                        let (books, probeURL) = try await performSingleSourceSearch(
                            source: source, keyword: keyword, mode: mode, timeout: searchTimeout
                        )
                        resultPair = books.map { ($0, source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName) }
                        // 诊断探针：源正常返回但 0 命中 → 记录最终搜索 URL，
                        // 供用户用 Safari 人工验证（区分关键词未生效 / 源无此书 / 规则未命中）
                        if books.isEmpty {
                            lock.lock()
                            outcome.probeURLs.append("\(sourceLabel(source)): \(probeURL)")
                            lock.unlock()
                        }
                    } catch {
                        guard !Task.isCancelled else {
                            Task.detached { await semaphore.release() }
                            return []
                        }
                        let msg: String
                        if let ne = error as? NetworkError, case .cancelled = ne {
                            Task.detached { await semaphore.release() }
                            return []
                        } else {
                            msg = error.localizedDescription
                        }
                        resultPair = [(ExploredBook(name: "", author: "", intro: "", bookUrl: "", coverUrl: "", lastChapter: "", sourceId: source.bookSourceUrl, sourceName: sourceLabel(source)), msg)]
                    }
                    // 聚合进 outcome（加锁，多任务并发写）
                    lock.lock()
                    for item in resultPair {
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
                    completed += 1
                    let elapsed = Date().timeIntervalSince(startTime)
                    let curResults = outcome.results
                    let curErrors = outcome.errors
                    let curCompleted = completed
                    lock.unlock()
                    // 信号量释放（保持原 defer 语义：在所有 return 路径后执行）
                    let rel = semaphore
                    Task.detached { await rel.release() }
                    // 命中达标：通知入队循环停止拉新源（任务回调内检测，避免入队侧轮询）
                    if hitTarget > 0, curResults.count >= hitTarget {
                        lock.lock(); stopEnqueue = true; lock.unlock()
                    }
                    // 立即推进度 + 流式命中，UI 边搜边出
                    onProgress?("已完成 \(curCompleted)/\(total) 个书源 · \(String(format: "%.0fs", elapsed)) · 找到 \(curResults.count) 本")
                    onStream?(curResults, curErrors)
                    return []
                }
            }

            for await _ in group {
                // 结果已在每个任务完成回调里聚合 + 流式上屏，此处仅等待全部任务结束
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
            // 每类取 1 条代表样例（按类计数降序，最多 6 类），
            // 此前 prefix(3) 恰好全是 403/超时类，"其他"类原始错误从未露面，
            // 无法坐实 385 条"其他"到底是死域名/区域封锁还是协议差异。
            var sampled: [String] = []
            for (cat, _) in buckets.sorted(by: { $0.value > $1.value }).prefix(6) {
                if let err = outcome.errors.first(where: { categorizeError($0.message) == cat }) {
                    sampled.append("· \(cat)：\(err.name)：\(err.message)")
                }
            }
            summary += "\n失败样例：\n" + sampled.joined(separator: "\n")
        }
        if timedOut {
            let reason = (hitTarget > 0 && outcome.results.count >= hitTarget)
                ? "🎯 命中 \(hitTarget) 本达标，提前停止（完成 \(completed)/\(total)）"
                : "⏱ 已达 \(Int(globalBudget))s 全局预算，提前结束（完成 \(completed)/\(total)）"
            summary = reason + "\n" + summary
        }
        // 探针 URL 段：正常返回但 0 命中的源，列出最终搜索 URL（Safari 可直接打开验证）
        if !outcome.probeURLs.isEmpty {
            let probeLine = outcome.probeURLs.prefix(10).map { "· \($0)" }.joined(separator: "\n")
            summary += "\n⚠️ \(outcome.probeURLs.count) 个源正常返回但 0 命中（可用 Safari 打开下列 URL 验证搜索是否生效）：\n\(probeLine)"
        }
        outcome.summary = summary
        return outcome
    }

    /// 失败原因归类（按关键词粗分），用于摘要里的分桶计数。
    private static func categorizeError(_ message: String) -> String {
        // 底层 NSURLError 英文错误码优先识别——此前它们全落"其他"，是观测盲区。
        // 错误文案形如 "-1005 host：The network connection was lost."，码号在最前。
        if message.contains("CSS 选择器未匹配") || message.contains("XPath 未匹配") || message.contains("页面结构可能已改版") { return "规则不匹配" }
        if message.contains("-1004") { return "域名不存在(-1004)" }
        if message.contains("-1005") { return "连接中断(-1005)" }
        if message.contains("-1003") { return "无法连接(-1003)" }
        if message.contains("-1009") { return "无网络(-1009)" }
        if message.contains("-1011") { return "连接超时(-1011)" }
        if message.contains("-1001") { return "服务器无响应(-1001)" }
        if message.contains("-21") && message.lowercased().contains("certificate") { return "证书(-21xx)" }
        if message.contains("-1200") { return "TLS失败(-1200)" }
        if message.contains("-1012") { return "响应无效(-1012)" }
        if message.contains("-1019") { return "请求无效(-1019)" }
        if message.lowercased().contains("tls") || message.lowercased().contains("certificate") || message.lowercased().contains("secure connection") { return "TLS/证书" }
        if message.lowercased().contains("timed out") { return "请求超时" }
        if message.contains("超时") { return "请求超时" }
        if message.contains("404") { return "HTTP404" }
        if message.contains("403") { return "HTTP403" }
        if message.contains("链接格式不正确") { return "链接格式" }
        if message.contains("JS 规则执行失败") { return "JS规则失败" }
        if message.contains("bookList 解析为空") { return "bookList空" }
        if message.contains("name 字段提取全部为空") { return "name提取空" }
        // 空响应 / 解码失败 显式拆出，便于确认 v30 的 gzip 兜底与 waitsForConnectivity 修复是否见效
        if message.contains("返回内容为空") { return "空响应" }
        if message.contains("无法解码") || message.contains("响应解码失败") { return "解码失败" }
        if message.contains("网络") { return "网络错误" }
        return "其他(含原始错误)"
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

    /// 剥离 legado 的静态分页标记 `<,page/{{page}}/>`（及 `<,page/{{page}}>` 等变体）。
    /// 该标记出现在部分书源 searchUrl 路径段中（如 `/<,page/{{page}}/>?s={{key}}`），
    /// 属 legado 特有语法，iOS 未解析；残留的 `<`/`>` 会导致 URLSanitizer 拒绝、
    /// 整源搜索报错归零。第一页搜索时该标记无实际参数贡献，直接移除即可生成合法 URL。
    private static func stripLegadoPageMarker(_ urlString: String) -> String {
        guard urlString.contains("<,page") else { return urlString }
        guard let regex = try? NSRegularExpression(pattern: "<,page[^>]*>", options: []) else {
            return urlString
        }
        let range = NSRange(urlString.startIndex..., in: urlString)
        return regex.stringByReplacingMatches(in: urlString, options: [], range: range, withTemplate: "")
    }

    /// 阶段二：占位符替换。`{{key}}` / `searchKey` → 编码后关键词；`{{page}}` / `searchPage` → 页码。
    private static func replaceKeyPage(_ urlString: String, keyword: String, page: Int = 1) -> String {
        let encoded = encodeSearchKey(keyword)
        var output = stripLegadoPageMarker(urlString)
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
                                                 timeout: TimeInterval? = nil) async throws -> ([ExploredBook], String) {
        let rawSearchURL = source.searchUrl ?? ""
        guard !rawSearchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }

        let engine = RuleEngine()
        engine.setSource(source)
        engine.setBaseUrl(source.bookSourceUrl)
        engine.setChapter(title: nil, nextUrl: nil)

        // JS 求值（@js/<js> searchUrl 桥网络）必须脱离 Swift 协作线程池执行：
        // 桥内 runSyncNetwork 用信号量同步等网络，会阻塞当前线程；若阻塞协作池线程，
        // 而网络续体（Task.detached）又需协作池线程才能续跑，12 路并发下池被饿死、
        // 请求整体挂起——这是"Safari 能开、App 全超时/空响应"的根因之一。
        // 改在全局并发队列上同步求值：阻塞的是全局队列线程（可安全阻塞、不会饿死池），
        // 协作池保持空闲，桥网络续体得以续跑，信号量正常唤醒。
        let jsEvaluated: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try analyzeSearchUrlJS(rawSearchURL, engine: engine, keyword: keyword)) }
                catch { cont.resume(throwing: error) }
            }
        }
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

        // —— gbk/gb2312/gb18030 健壮解码：Swift 原生不支持 gbk，必须走 GB18030 ——
        // 这是「正常返回但 0 命中」类 gbk 书源（如烟锁重楼/eyushuwu）的根因：响应是 gbk 字节，
        // 若按 utf-8 解码会变成乱码，中文 class 名与文本全失效，选择器全部失配 → 0 命中。
        let gb18030Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x80000632)))
        // 兜底：searchUrl 可能以 JSON 选项声明 charset（如 eyushuwu 的 { "charset":"gbk",... }），
        // 若 parseSearchRequest 未解析出，则从此处补提取，避免 gbk 源走默认 utf-8 解码乱码。
        var fallbackCharset: String?
        if let start = rawSearchURL.firstIndex(of: "{"),
           let end = rawSearchURL.lastIndex(of: "}") {
            let sub = String(rawSearchURL[start...end])
            if let d = sub.data(using: .utf8),
               let opt = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                fallbackCharset = (opt["charset"] as? String)
            }
        }
        let effectiveCharset = (request.charset?.isEmpty == false ? request.charset : fallbackCharset)?.lowercased()

        /// gbk 家族一律用 GB18030 解码（Swift 原生支持，可解 gbk/gb2312/gb18030）；
        /// 其余仍走原有 decodeText，再回落 utf-8。即使 decodeText 有缺陷，gbk 兜底也已生效。
        func decodeBody(_ data: Data, charset: String?) -> String {
            let declared = (charset?.isEmpty == false ? charset! : nil)?.lowercased() ?? effectiveCharset
            if let d = declared, d.contains("gb") {
                if let s = String(data: data, encoding: gb18030Encoding), !s.isEmpty { return s }
            }
            if let c = charset, let s = try? NetworkService.decodeText(data, charset: c), !s.isEmpty { return s }
            return String(data: data, encoding: .utf8) ?? ""
        }

        let html: String
        if request.method.uppercased() == "POST", let bodyTemplate = request.body {
            var finalBody = bodyTemplate
            finalBody = finalBody.replacingOccurrences(of: "{{key}}", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "searchKey", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "{{searchPage}}", with: "1")
            finalBody = finalBody.replacingOccurrences(of: "searchPage", with: "1")
            let useGB = (effectiveCharset?.contains("gb") ?? false)
            let bodyData = finalBody.data(using: useGB ? gb18030Encoding : .utf8) ?? Data()
            let (data, response) = try await NetworkService.shared.fetchDataWithBody(
                from: finalURL, method: "POST", body: bodyData, headers: mergedHeaders, timeout: timeout
            )
            let decoded = decodeBody(data, charset: request.charset)
            guard !decoded.isEmpty else {
                throw NSError(domain: "Search", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "响应解码失败（charset=\(request.charset ?? effectiveCharset ?? "")）"])
            }
            html = decoded
        } else if let charset = request.charset, !charset.isEmpty {
            let (data, response) = try await NetworkService.shared.fetchDataWithResponse(
                from: finalURL, headers: mergedHeaders, timeout: timeout
            )
            let decoded = decodeBody(data, charset: charset)
            guard !decoded.isEmpty else {
                throw NSError(domain: "Search", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "响应解码失败（charset=\(charset)）"])
            }
            html = decoded
        } else if let ec = effectiveCharset, ec.contains("gb") {
            // 兜底：parseSearchRequest 未解析 charset，但 searchUrl JSON 选项声明了 gbk
            let (data, response) = try await NetworkService.shared.fetchDataWithResponse(
                from: finalURL, headers: mergedHeaders, timeout: timeout
            )
            let decoded = decodeBody(data, charset: ec)
            guard !decoded.isEmpty else {
                throw NSError(domain: "Search", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "响应解码失败（charset=\(ec)）"])
            }
            html = decoded
        } else {
            html = try await NetworkService.shared.fetchText(from: finalURL, headers: mergedHeaders, timeout: timeout)
        }

        // 抽取（bookList/name 等规则，含 <js> 桥网络）同样脱离协作线程池，避免阻塞。
        // 整个抽取在全局队列上同步跑，嵌套的桥网络信号量等待也只阻塞该全局队列线程，
        // 协作池线程不被占用，网络续体可正常续跑——彻底消除并发搜索的池饿死死锁。
        let extracted: [ExploredBook] = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[ExploredBook], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try extractSearchResults(
                    html: html, rules: rules, source: source, base: finalURL, engine: engine)) }
                catch { cont.resume(throwing: error) }
            }
        }
        if Task.isCancelled { return ([], finalURL.absoluteString) }
        let sourceName = source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName
        // 🔧 修复（彻底解决「命中恒为 0~2 本」）：
        // 原 precise 过滤要求「书名全等关键词」才保留，把《诛仙（全本）》《诛仙前传》
        // 《诛仙Ⅰ》等合法变体一律丢弃，仅命中恰好名为「诛仙」的本子 → 0~2 本。
        // 现改为：精确模式保留「书名全等 / 书名以关键词开头」的结果（覆盖上述变体），
        // 同时仍剔除「开局签到诛仙神剑」这类关键词仅作书名片段的无关书（书名既不等全
        // 也不以前缀开头）；模糊模式保留书名/作者/简介包含关键词的结果。
        // 过滤后的结果按相关度排序，让最匹配的书置顶。
        let kept = extracted.filter { shouldKeep($0, keyword: keyword, mode: mode) }
        let ranked = kept
            .map { book in (book, relevanceScore(book, keyword: keyword, mode: mode)) }
            .sorted { $0.1 > $1.1 }
            .map { book, _ in
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
        // 探针 URL：最终搜索 URL（含关键词替换后的成品），供 0 命中时人工验证
        return (ranked, finalURL.absoluteString)
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

    /// 关键词与模式的匹配判定（用于「保留」结果，即结果级过滤）：
    /// - 精确模式：书名全等关键词，或书名以关键词开头（覆盖《诛仙（全本）》《诛仙前传》
    ///   《诛仙Ⅰ》等合法变体）；作者全等亦保留（按作者精确检索）。
    ///   以此剔除「开局签到诛仙神剑」这类关键词仅作书名片段的无关书
    ///   （书名既不等全、也不以前缀开头）。
    /// - 模糊模式：书名 / 作者 / 简介包含关键词即保留（宽匹配，对应原模糊语义）。
    private static func shouldKeep(_ book: ExploredBook, keyword: String, mode: SearchMode) -> Bool {
        let k = normalize(keyword)
        guard !k.isEmpty else { return true }
        let name = normalize(book.name)
        let author = normalize(book.author)
        let intro = normalize(book.intro)

        if mode == .precise {
            if name == k || name.hasPrefix(k) || author == k { return true }
            return false
        }
        // 模糊
        return name.contains(k) || author.contains(k) || intro.contains(k)
    }

    /// 归一化书名 / 作者 / 简介：去书名号《》、去首尾与内部多余空白、转小写，
    /// 使「诛仙 」「《诛仙》」「诛仙（全本）」等形态统一比对，避免空白/书名号导致漏匹配。
    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "《", with: "")
            .replacingOccurrences(of: "》", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// 关键词与模式的相关度评分（0~4）：仅用于排序，不用于丢弃（过滤由 `shouldKeep` 负责）。
    /// - 精确模式：书名全等(4) > 书名包含(2) > 作者/简介包含(1) > 不相关(0)
    /// - 模糊模式：书名包含(3) > 作者包含(2) > 简介包含(1) > 不相关(0)
    private static func relevanceScore(_ book: ExploredBook, keyword: String, mode: SearchMode) -> Int {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return 4 }
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let intro = book.intro.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if mode == .precise {
            if name == k || author == k { return 4 }
            if name.contains(k) { return 2 }
            if author.contains(k) || intro.contains(k) { return 1 }
            return 0
        }
        // 模糊
        if name.contains(k) { return 3 }
        if author.contains(k) { return 2 }
        if intro.contains(k) { return 1 }
        return 0
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
