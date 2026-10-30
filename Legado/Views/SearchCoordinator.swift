import Foundation


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
        // 共享可变聚合容器（引用类型，供 OperationQueue 自备线程并发写入；
        // 不能让 BlockOperation 闭包直接改外部的 struct outcome——struct 会被值捕获，写入失效）
        let agg = SearchAgg()
        var enqueued = 0

        // Fix-C：专用工作队列，把整段单源搜索（含同步 JS 求值与 JS 桥 semaphore.wait）
        // 挪到 OperationQueue 自备线程，彻底脱离 Swift 协作线程池，
        // 消除线程池饿死导致的覆盖率截断（此前 12 路并发 + 协作池阻塞 → 720 源仅个位数成功）。
        let worker = OperationQueue()
        worker.maxConcurrentOperationCount = 32
        worker.qualityOfService = .userInitiated
        worker.name = "legado.search.worker"

        // doneSem 用于等待全部已入队 Operation 完成（每个 Operation 结束前必定 signal 一次，不会死锁）
        let doneSem = DispatchSemaphore(value: 0)

        for source in sources {
            if Task.isCancelled { break }
            // 命中达标 / 全局预算到期：不再入队新源（在途请求自然收尾，尾部有界）。
            agg.lock.lock(); let shouldStop = agg.stopEnqueue; agg.lock.unlock()
            if shouldStop { break }
            if Date().timeIntervalSince(startTime) > globalBudget { break }
            enqueued += 1
            // 入队即回传：用「已入队」计数给用户即时反馈，消除「长时间无进展」的假死观感
            onProgress?("已入队 \(enqueued)/\(total) 个书源 · 等待响应中…")

            let op = BlockOperation {
                defer { doneSem.signal() }
                // 把 async 单源搜索桥接为同步，阻塞的是 Operation 线程（plentiful），
                // 不占用稀缺的协作线程池；协作池仅承载内层网络续体，不再被饿死。
                var resultPair: [(ExploredBook, String?)] = []
                do {
                    let (books, probeURL) = try Self.runSourceSync(
                        source: source, keyword: keyword, mode: mode, timeout: searchTimeout
                    )
                    // 正常：每项第二元素为 nil（非错误）；源正常返回但 0 命中 → 记录探针 URL
                    resultPair = books.map { ($0, nil) }
                    if books.isEmpty {
                        agg.lock.lock()
                        agg.probeURLs.append("\(sourceLabel(source)): \(probeURL)")
                        agg.lock.unlock()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    let msg: String
                    if let ne = error as? NetworkError, case .cancelled = ne {
                        return
                    } else {
                        msg = error.localizedDescription
                    }
                    resultPair = [(ExploredBook(name: "", author: "", intro: "", bookUrl: "", coverUrl: "", lastChapter: "", sourceId: source.bookSourceUrl, sourceName: sourceLabel(source)), msg)]
                }
                // 聚合进共享容器（引用类型 agg，加锁，多 Operation 并发写）
                agg.lock.lock()
                for item in resultPair {
                    if let msg = item.1 {
                        agg.errors.append(SourceSearchError(name: item.0.sourceName, message: msg))
                    } else {
                        let book = item.0
                        // 去重键优先用详情链接（每本书唯一）；书名为空时仍按书名|作者去重
                        let key = book.bookUrl.isEmpty
                            ? "\(book.name.lowercased())|\(book.author.lowercased())"
                            : book.bookUrl.lowercased()
                        if agg.seen.contains(key) { continue }
                        agg.seen.insert(key)
                        agg.results.append(book)
                    }
                }
                agg.completed += 1
                let elapsed = Date().timeIntervalSince(startTime)
                let curResults = agg.results
                let curErrors = agg.errors
                let curCompleted = agg.completed
                agg.lock.unlock()
                // 命中达标：通知入队循环停止拉新源
                if hitTarget > 0, curResults.count >= hitTarget {
                    agg.lock.lock(); agg.stopEnqueue = true; agg.lock.unlock()
                }
                // 立即推进度 + 流式命中，UI 边搜边出
                onProgress?("已完成 \(curCompleted)/\(total) 个书源 · \(String(format: "%.0fs", elapsed)) · 找到 \(curResults.count) 本")
                onStream?(curResults, curErrors)
            }
            worker.addOperation(op)
        }

        // 等待全部已入队 Operation 完成（每个 Op 结束前 defer signal 一次，不会死锁）
        for _ in 0..<enqueued { doneSem.wait() }

        // 收拢并发聚合结果（agg 为引用类型容器，run 主体此处一次性拷入 var outcome）
        outcome.results = agg.results
        outcome.errors = agg.errors
        outcome.probeURLs = agg.probeURLs
        let completed = agg.completed

        let timedOut = completed < total
        let failed = outcome.errors.count
        if outcome.results.isEmpty && failed == 0 {
            outcome.errorMessage = "全部书源均未搜索到「\(keyword)」"
        }
        var summary = "📊 命中 \(outcome.results.count) 本 · 失败 \(failed) 个"
        if failed > 0 {
            var buckets: [String: Int] = [:]
            for err in outcome.errors {
                buckets[categorizeError(err.message), default: 0] += 1
            }
            let bucketLine = buckets.sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: "  ")
            summary += "\n失败分布：\(bucketLine)"
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
        if !outcome.probeURLs.isEmpty {
            let probeLine = outcome.probeURLs.prefix(10).map { "· \($0)" }.joined(separator: "\n")
            summary += "\n⚠️ \(outcome.probeURLs.count) 个源正常返回但 0 命中（可用 Safari 打开下列 URL 验证搜索是否生效）：\n\(probeLine)"
        }
        outcome.summary = summary
        return outcome
    }

    /// 并发聚合容器：引用类型，供 OperationQueue 自备线程安全地并发写入。
    private class SearchAgg: @unchecked Sendable {
        let lock = NSLock()
        var results: [ExploredBook] = []
        var errors: [SourceSearchError] = []
        var probeURLs: [String] = []
        var completed = 0
        var stopEnqueue = false
        var seen = Set<String>()
    }

    /// async→sync 桥：把单源搜索放到独立 Task 执行，当前 Operation 线程阻塞等待结果。
    /// 阻塞发生在 OperationQueue 自备线程（plentiful），不占用协作线程池，避免饿死。
    private static func runSourceSync(source: BookSource,
                                      keyword: String,
                                      mode: SearchMode,
                                      timeout: TimeInterval) throws -> ([ExploredBook], String) {
        let box = SearchSyncBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            do {
                let r = try await Self.performSingleSourceSearch(source: source, keyword: keyword, mode: mode, timeout: timeout)
                box.store(r)
            } catch {
                box.store(error)
            }
        }
        sem.wait()
        return try box.take()
    }

    private class SearchSyncBox: @unchecked Sendable {
        private var stored: Result<([ExploredBook], String), any Error>?
        private let l = NSLock()
        func store(_ v: ([ExploredBook], String)) { l.lock(); stored = .success(v); l.unlock() }
        func store(_ e: any Error) { l.lock(); stored = .failure(e); l.unlock() }
        func take() throws -> ([ExploredBook], String) {
            l.lock(); let v = stored; l.unlock()
            switch v {
            case .success(let r): return r
            case .failure(let e): throw e
            case .none: throw NSError(domain: "legado.search", code: -1, userInfo: [NSLocalizedDescriptionKey: "未知错误"])
            }
        }
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
    /// 相关性过滤：并发覆盖率恢复（Fix-C）后命中量暴涨，需按模式剔除无关书。
    /// - 精确模式：书名或作者须包含关键词（覆盖《诛仙（全本）》/《诛仙Ⅰ》等变体）；
    ///   书名与作者皆空、无法判断相关性时，仅保留「有详情链接」者以防误删。
    /// - 模糊模式：legado 官方不做关键词二次过滤，全部保留（仅空条目已在上方丢弃）；
    ///   用户原话「模糊可以、精确需限定」，故仅在精确模式做相关性收敛。
    /// 始终丢弃「书名与详情链接皆为空」的无效条目。
    private static func shouldKeep(_ book: ExploredBook, keyword: String, mode: SearchMode) -> Bool {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 书名与链接皆空 → 无效条目，始终丢弃
        guard !name.isEmpty || !url.isEmpty else { return false }
        // 无关键词（理论上不会发生）→ 全部保留
        if k.isEmpty { return true }
        if mode == .precise {
            // 精确：书名须「严格」匹配关键词——去除装饰词/卷册标记/标点数字后，
            // 主干须以关键词为主、不得夹带其他中文字（剔除「诛仙诀」「诛仙传」等无关书）。
            // 书名空无法判断时保留（避免误删）。
            if name.isEmpty { return true }
            return strictMatchName(name, k)
        }
        // 模糊：legado 官方不做二次过滤，全部保留（仅空条目已在上方丢弃）
        return true
    }

    /// 去全部空白（含词间空格/换行），用于精确匹配的归一化。
    private static func stripWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 精确搜索严格匹配：书名去除装饰词 / 卷册标记 / 末尾序号 / 标点后，须以关键词为主干，
    /// 残余不得含任何中文字（否则视为无关书，如「诛仙诀」「诛仙后传」）。
    /// 仅匹配「书名 + 装饰」的合法变体（如「诛仙（全本）」「诛仙I」「诛仙 第一卷」）。
    private static func strictMatchName(_ rawName: String, _ rawKeyword: String) -> Bool {
        let k = stripWhitespace(rawKeyword)
        guard !k.isEmpty else { return true }
        var n = stripWhitespace(rawName)
        guard !n.isEmpty else { return true } // 书名空无法判断 → 保留
        // ① 去掉常见装饰词
        let decorations = ["全本", "完本", "全集", "精校版", "精校", "修订版", "修订",
                           "最新版", "最新", "正版", "简体", "完整版", "完整",
                           "未删节", "无删节", "全集版", "版", "著", "作品"]
        for d in decorations { n = n.replacingOccurrences(of: d, with: "") }
        // ② 去掉卷/册/部/篇/集 + 序号（「第X卷」「卷X」「卷」结尾），以及上下册/第N部
        n = n.replacingOccurrences(of: #"第[0-9一二三四五六七八九十百千零]+[卷册部篇章]"#, with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: #"[卷册部篇章][0-9一二三四五六七八九十百千零]+"#, with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: #"[卷册部篇章]$"#, with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: #"(上|下|上册|下册|上卷|下卷|第一部|第二部|第三部)"#, with: "", options: .regularExpression)
        // ③ 去掉末尾罗马数字 / 圈码 / 数字
        n = n.replacingOccurrences(of: #"[Ⅰ-Ⅻ①②③④⑤⑥⑦⑧⑨⑩0-9]+$"#, with: "", options: .regularExpression)
        // 必须包含关键词
        guard n.contains(k) else { return false }
        // ④ 去掉关键词后，残余不得含中文字（仅允许标点/字母/空格等装饰）
        let rest = n.replacingOccurrences(of: k, with: "")
        for ch in rest {
            if let v = ch.unicodeScalars.first?.value, (0x4E00...0x9FFF).contains(v) {
                return false
            }
        }
        return true
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
            if name == k { return 4 }
            if strictMatchName(name, k) { return 3 }
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
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bookUrlRaw = BookListAnalyzer.field(rules.bookUrl, item: item, engine: engine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // legado 不按书名为空丢弃搜索结果：书名提取为空但详情链接有效时仍可进书架/阅读，
            // 应保留；仅当书名与详情链接皆为空才跳过（无效条目）。
            guard !(name.isEmpty && bookUrlRaw.isEmpty) else { continue }
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
        // 不再因「name 全空」抛错：与 legado 官方搜索「返回搜索页解析出的全部书」语义一致，
        // 书名提取为空但详情链接有效的书已在上循环保留；无有效条目时返回空数组（计为 0 命中，不判失败）。
        return result
    }

    private static func resolveURL(_ relative: String, base: URL?) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        guard let base else { return nil }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}
