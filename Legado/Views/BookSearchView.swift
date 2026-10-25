import SwiftUI

/// 搜索模式：模糊 = 关键词作为子串命中书名/作者/简介；精确 = 书名/作者完全相等，
/// 或简介中作为独立片段命中（支持按主角名等精确检索）。
enum SearchMode: String, CaseIterable {
    case fuzzy
    case precise
}

/// 单源搜索的失败记录（用于逐源报错展示）
struct SourceSearchError: Identifiable {
    let id = UUID()
    let name: String
    let message: String
}

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

/// 书源搜索：遍历全部可搜索书源，按 ruleSearch 规则检索书籍，一键加入书架。
/// 加入书架的书籍保留 sourceId + bookUrl，阅读时走规则阅读路径。
///
/// searchUrl 三阶段流水线（对齐 legado AnalyzeUrl）：
/// ① analyzeJs —— `@js:` / `<js>` 求值（绑定 key / page / baseUrl / java / source / result）；
/// ② replaceKeyPage —— `{{key}}` / `searchKey` / `{{page}}` / `searchPage` 占位符替换；
/// ③ splitUrlOptions —— 最后按 `,{` 切分 URL 与选项（method / body / headers / charset）。
struct BookSearchView: View {
    @EnvironmentObject private var sourceStore: BookSourceStore
    @EnvironmentObject private var bookStore: BookStore
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var mode: SearchMode = .fuzzy
    @State private var results: [ExploredBook] = []
    @State private var isSearching = false
    @State private var progressText: String?
    @State private var errorMessage: String?
    @State private var addedMessage: String?
    @State private var sourceErrors: [SourceSearchError] = []
    /// 搜索完成后的诊断摘要（命中/成功未命中/失败/超时统计）
    @State private var searchSummary: String = ""
    /// 当前搜索任务句柄，支持随时取消（停止搜索）
    @State private var searchTask: Task<Void, Never>?

    /// 可搜索的书源：配置了含 {{key}} 的 searchUrl 且具备 ruleSearch.bookList
    private var searchableSources: [BookSource] {
        sourceStore.sources.filter { $0.supportsSearch && $0.enabled }
    }

    /// 无可用搜索书源时的可操作诊断：按条件逐层排查，告诉用户差在哪、怎么补
    private var searchUnavailableReason: String {
        let all = sourceStore.sources
        guard !all.isEmpty else {
            return "尚未导入任何书源。请到「书源」页，点右上角 + 或扫码导入 legado 书源 JSON。"
        }
        let trimmedSearchURLCount = all.filter {
            !($0.searchUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        let withPlaceholder = all.filter {
            let raw = $0.searchUrl ?? ""
            return raw.contains("{{key}}") || raw.contains("searchKey")
                || raw.lowercased().hasPrefix("@js:") || raw.hasPrefix("<js>")
        }.count
        let withRule = all.filter { !($0.ruleSearch?.bookList ?? "").isEmpty }.count
        let disabledCount = all.filter { !$0.enabled }.count

        if trimmedSearchURLCount < all.count {
            return "已导入 \(all.count) 个书源，仅 \(trimmedSearchURLCount) 个带 searchUrl 字段。缺失该字段的多为旧版本导入（当时未持久化 searchUrl）——请到「书源」页重新导入同一份书源 JSON 即可刷新。"
        }
        if withPlaceholder < trimmedSearchURLCount {
            return "书源的搜索地址均不含 {{key}} / searchKey 占位符（或 @js: 构造形式），无法拼接搜索请求。"
        }
        if withRule < withPlaceholder {
            return "书源缺少 ruleSearch.bookList 规则，无法解析搜索结果。"
        }
        if disabledCount == all.count {
            return "全部 \(all.count) 个书源均被停用。请到「书源」页开启后再搜索。"
        }
        return "已导入 \(all.count) 个书源，但均不满足搜索条件（需 searchUrl 含 {{key}}/searchKey 占位符或 @js: 构造 + ruleSearch.bookList 规则，且书源处于启用状态）。"
    }

    var body: some View {
        NavigationStack {
            Group {
                if searchableSources.isEmpty {
                    ContentUnavailableView {
                        Label("没有可搜索的书源", systemImage: "magnifyingglass")
                    } description: {
                        Text(searchUnavailableReason)
                    }
                } else {
                    searchContent
                }
            }
            .navigationTitle("搜索书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onDisappear { searchTask?.cancel() }
            .alert("提示", isPresented: .constant(addedMessage != nil)) {
                Button("好") { addedMessage = nil }
            } message: {
                Text(addedMessage ?? "")
            }
        }
    }

    // MARK: - 搜索界面

    private var searchContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                // 匹配模式 + 书源范围
                HStack {
                    Text("匹配模式")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("匹配模式", selection: $mode) {
                        Text("模糊").tag(SearchMode.fuzzy)
                        Text("精确").tag(SearchMode.precise)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
                Text("将遍历全部 \(searchableSources.count) 个可搜索书源；关键词支持书名 / 作者 / 主角名 · build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // 关键词 + 搜索 / 停止
                HStack(spacing: 8) {
                    TextField("书名 / 作者 / 主角名", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit(of: .text) { if !isSearching { runSearch() } }
                    Button {
                        if isSearching {
                            stopSearch()
                        } else {
                            runSearch()
                        }
                    } label: {
                        if isSearching {
                            Text("停止").frame(width: 56)
                        } else {
                            Text("搜索").frame(width: 56)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isSearching && keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()

            if let progress = progressText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            if let error = errorMessage {
                ContentUnavailableView {
                    Label("搜索结束", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(error)
                }
            } else if results.isEmpty && sourceErrors.isEmpty && !isSearching && progressText == nil {
                ContentUnavailableView {
                    Label("输入关键词开始搜索", systemImage: "text.magnifyingglass")
                } description: {
                    Text("将遍历全部可搜索书源，按书名 / 作者 / 主角名匹配")
                }
            } else {
                List {
                    ForEach(results) { book in
                        HStack(alignment: .top, spacing: 12) {
                            if !book.coverUrl.isEmpty, let coverURL = URLSanitizer.sanitize(book.coverUrl) {
                                AsyncImage(url: coverURL)
                                    .frame(width: 44, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Rectangle().fill(.quaternary)
                                    .frame(width: 44, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if !book.author.isEmpty {
                                    Text(book.author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !book.lastChapter.isEmpty {
                                    Text("最新：\(book.lastChapter)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if !book.intro.isEmpty {
                                    Text(book.intro)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if !book.sourceName.isEmpty {
                                    Text("来源：\(book.sourceName)")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                            }
                            Spacer()
                            Button {
                                addToShelf(book)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if !sourceErrors.isEmpty {
                        Section("以下书源未返回结果或失败") {
                            ForEach(sourceErrors) { err in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(err.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(err.message)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    if !searchSummary.isEmpty {
                        Section {
                            Text(searchSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .listStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 多源搜索逻辑

    /// 启动全源并发搜索：同时调度多个书源请求，死源不阻塞活源。
    /// 限流 20 路并发，搜索页超时 6s，全局预算 90s——642 源在 90s 内必然结束，
    /// 不再出现「遍历几十分钟」的情况。搜索页是小 HTML，6s 对绝大多数站点足够；
    /// 超时的源本身就是死源/慢源，继续等待没有意义。
    private func runSearch() {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return }
        let sources = searchableSources
        guard !sources.isEmpty else {
            errorMessage = "没有可搜索的书源"
            return
        }

        searchTask?.cancel()
        results = []
        sourceErrors = []
        errorMessage = nil
        isSearching = true
        let total = sources.count
        let currentMode = mode
        let keywordCopy = trimmedKeyword
        let searchTimeout: TimeInterval = 6   // 搜索页是小 HTML，6s 足够
        let globalBudget: TimeInterval = 90    // 全局搜索预算，超时即停
        let startTime = Date()

        searchTask = Task {
            var seen = Set<String>()
            var completed = 0
            var noMatchCount = 0  // 成功但未命中（返回 200 但结果不含关键词）
            let lock = NSLock()

            // 全局超时：到达预算即取消剩余搜索，避免 642 源遍历几十分钟。
            let globalGuard = Task {
                try? await Task.sleep(nanoseconds: UInt64(globalBudget * 1_000_000_000))
                searchTask?.cancel()
            }

            await withTaskGroup { group in
                // 并发档位：JS 桥的网络方法会阻塞协作线程（信号量等待），
                // 并发过高会耗尽协作线程池导致整体挂起——12 路是速度与稳定的平衡点
                let semaphore = SearchSemaphore(value: 12)

                for source in sources {
                    if Task.isCancelled { break }
                    await semaphore.wait()

                    group.addTask {
                        defer { semaphore.release() }
                        guard !Task.isCancelled else { return }

                        do {
                            let books = try await performSingleSourceSearch(
                                source: source, keyword: keywordCopy, mode: currentMode,
                                timeout: searchTimeout
                            )
                            await MainActor.run {
                                let unique = books.filter { book in
                                    let key = "\(book.name.lowercased())|\(book.author.lowercased())"
                                    if seen.contains(key) { return false }
                                    seen.insert(key)
                                    return true
                                }
                                results.append(contentsOf: unique)
                            }
                            // 成功但未命中：计数但不报错，用于诊断摘要。
                            if books.isEmpty {
                                lock.lock()
                                noMatchCount += 1
                                lock.unlock()
                            }
                        } catch {
                            guard !Task.isCancelled else { return }
                            let msg: String
                            if let ne = error as? NetworkError, case .cancelled = ne {
                                return
                            } else {
                                msg = error.localizedDescription
                            }
                            await MainActor.run {
                                sourceErrors.append(SourceSearchError(name: sourceLabel(source), message: msg))
                            }
                        }

                        lock.lock()
                        completed += 1
                        lock.unlock()
                        await MainActor.run {
                            let elapsed = Date().timeIntervalSince(startTime)
                            progressText = "已完成 \(completed)/\(total) 个书源 · \(String(format: "%.0fs", elapsed)) · 找到 \(results.count) 本"
                        }
                    }
                }
            }

            globalGuard.cancel()

            await MainActor.run {
                isSearching = false
                progressText = nil
                let timedOut = completed < total  // 被全局预算截断

                if results.isEmpty && sourceErrors.isEmpty {
                    errorMessage = "全部书源均未搜索到「\(keywordCopy)」"
                } else {
                    errorMessage = nil
                }
                // 诊断摘要：命中 / 成功但未命中 / 失败 三分类。
                // 「成功但未命中」= HTTP 200 且规则解析成功但无匹配书籍。
                if timedOut {
                    searchSummary = "⏱ 已达 \(Int(globalBudget))s 全局预算，提前结束（完成 \(completed)/\(total) 个书源）"
                } else {
                    searchSummary = "📊 命中 \(results.count) 本 · 成功但未命中 \(noMatchCount) 个 · 失败 \(sourceErrors.count) 个"
                }
            }
        }
    }

    /// 随时停止：取消任务并复位状态
    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        progressText = nil
    }

    // MARK: - searchUrl 三阶段流水线（对齐 legado AnalyzeUrl）

    /// 阶段一：`@js:` / `<js>` 求值。绑定 key / page / baseUrl / java / source / result / cookie。
    /// 非 JS 形态原样返回。
    private func analyzeSearchUrlJS(_ raw: String, engine: RuleEngine, keyword: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.contains("@js:") || trimmed.contains("<js>") else {
            return raw
        }
        return try engine.evaluateSearchUrl(trimmed, keyword: keyword, page: 1)
    }

    /// 阶段二：占位符替换。`{{key}}` / `searchKey` → 编码后关键词；`{{page}}` / `searchPage` → 页码。
    /// `{{searchKey}}` 先归一化为 `{{key}}`——直接替换 "searchKey" 会残留 `{{}}`，
    /// 导致 URL 含非法字符构造失败（legado ImportOldData 的归一化语义）。
    private func replaceKeyPage(_ urlString: String, keyword: String, page: Int = 1) -> String {
        let encoded = Self.encodeSearchKey(keyword)
        var output = urlString
            .replacingOccurrences(of: "{{searchKey}}", with: "{{key}}")
            .replacingOccurrences(of: "{{searchPage}}", with: "{{page}}")
        output = output.replacingOccurrences(of: "{{key}}", with: encoded)
        output = output.replacingOccurrences(of: "searchKey", with: encoded)
        output = output.replacingOccurrences(of: "{{page}}", with: "\(page)")
        output = output.replacingOccurrences(of: "searchPage", with: "\(page)")
        return output
    }

    /// 搜索关键词编码：查询/路径通用安全字符集，`+` 强制编码（避免被当作空格）
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
    /// - Parameter timeout: 请求超时（秒），搜索页用较短值避免死站阻塞整体进度。
    private func performSingleSourceSearch(source: BookSource,
                                            keyword: String,
                                            mode: SearchMode,
                                            timeout: TimeInterval? = nil) async throws -> [ExploredBook] {
        let rawSearchURL = source.searchUrl ?? ""
        guard !rawSearchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }

        // 共享引擎实例：变量跨 searchUrl → bookList → 各字段生效（@put/@get），
        // 同时携带 source / baseUrl 上下文供 JS 绑定使用。
        let engine = RuleEngine()
        engine.setSource(source)
        engine.setBaseUrl(source.bookSourceUrl)
        engine.setChapter(title: nil, nextUrl: nil)

        // 阶段一：JS 求值（JS 形态失败直接抛出，错误对用户可见）
        let jsEvaluated = try analyzeSearchUrlJS(rawSearchURL, engine: engine, keyword: keyword)

        // 阶段二：占位符替换
        let urlStr = replaceKeyPage(jsEvaluated, keyword: keyword, page: 1)

        // 阶段三：切分 URL 与选项（此时 `,{` 才是选项边界）
        let request = parseSearchRequest(raw: urlStr)

        // 占位符校验：非 JS 形态必须真的带过 key（JS 形态由 JS 自行构造，放行）
        let isJSForm = rawSearchURL.lowercased().contains("@js:") || rawSearchURL.contains("<js>")
        if !isJSForm {
            let hasKeyPlaceholder = jsEvaluated.contains("{{key}}")
                || jsEvaluated.contains("searchKey")
                || urlStr.contains(Self.encodeSearchKey(keyword))
            guard hasKeyPlaceholder else {
                throw NetworkError.invalidURL
            }
        }

        let encoded = Self.encodeSearchKey(keyword)
        var finalURLString = request.url
        finalURLString = finalURLString.replacingOccurrences(of: "{{key}}", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "searchKey", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "{{searchPage}}", with: "1")
        finalURLString = finalURLString.replacingOccurrences(of: "searchPage", with: "1")
        // 兜底：占位符替换后仍残留的 {{ }} 做 percent 编码
        //（URL 含花括号会构造失败，报「链接格式不正确」）
        if finalURLString.contains("{{") || finalURLString.contains("}}") {
            finalURLString = finalURLString
                .replacingOccurrences(of: "{{", with: "%7B%7B")
                .replacingOccurrences(of: "}}", with: "%7D%7D")
        }
        // 相对地址（无 scheme，如 /search?kw={{key}}）需拼接书源基准 URL。
        // legado 书源的 searchUrl 大量是相对路径，不解析会导致全部被判「链接格式不正确」。
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

        // 合并书源 header 字段（Referer / Cookie / UA 等）与 searchUrl 选项里的 headers，
        // 修复需要鉴权头的书源返回 HTTP 401/403 的问题。
        var mergedHeaders = sourceHeaders(source)
        for (key, value) in request.headers { mergedHeaders[key] = value }
        // 默认 Referer：中文站点普遍校验，缺失时用书源基准 URL 兜底
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
                // GBK 站点的 POST 表单必须按 gbk 编码，否则关键词乱码
                bodyData = finalBody.data(using: encoding) ?? Data()
            } else {
                bodyData = finalBody.data(using: .utf8) ?? Data()
            }
            if let charset = request.charset {
                // 书源显式声明 charset（如 gbk）：取原始数据按声明解码
                let (data, response) = try await NetworkService.shared.fetchDataWithBody(
                    from: finalURL, method: "POST", body: bodyData, headers: mergedHeaders,
                    timeout: timeout
                )
                html = (try? NetworkService.decodeText(
                    data, charset: charset.isEmpty ? response.textEncodingName : charset
                )) ?? ""
            } else {
                html = try await NetworkService.shared.fetchTextWithBody(
                    from: finalURL, method: "POST", body: bodyData, headers: mergedHeaders,
                    timeout: timeout
                )
            }
        } else if let charset = request.charset, !charset.isEmpty {
            let (data, response) = try await NetworkService.shared.fetchDataWithResponse(
                from: finalURL, headers: mergedHeaders, timeout: timeout
            )
            html = (try? NetworkService.decodeText(
                data, charset: charset.isEmpty ? response.textEncodingName : charset
            )) ?? ""
        } else {
            html = try await NetworkService.shared.fetchText(from: finalURL, headers: mergedHeaders, timeout: timeout)
        }

        let extracted = try extractSearchResults(
            html: html, rules: rules, source: source, base: finalURL, engine: engine
        )
        // 网络/JS 阶段可能耗时较长（如 startBrowserAwait 等待用户操作），
        // 完成后检查取消，避免已取消的任务继续做无谓的解析
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
    /// 找不到选项后缀则视为 GET；body 中的 {{key}} 由调用方替换。
    /// 注意：必须在 @js: 求值之后调用（legado AnalyzeUrl 第三阶段）。
    private func parseSearchRequest(raw: String) -> ParsedSearchRequest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ",{") else {
            return ParsedSearchRequest(url: trimmed, method: "GET", body: nil, headers: [:])
        }
        let urlPart = String(trimmed[trimmed.startIndex..<range.lowerBound])
        let optionsString = String(trimmed[range.lowerBound..<trimmed.endIndex]).dropFirst() // 去掉逗号，留 {…}
        guard let data = optionsString.data(using: .utf8) else {
            return ParsedSearchRequest(url: urlPart, method: "GET", body: nil, headers: [:])
        }
        // 先试标准双引号 JSON，失败则单引号→双引号转换后再试。
        // legado 书源的选项后缀大量使用单引号（如 {'method':'post','body':'...'}），
        // JSONSerialization 只认双引号，不转换会导致 POST body/method 全部丢失。
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
            return ParsedSearchRequest(url: urlPart, method: "GET", body: nil, headers: [:])
        }
        let method = (obj["method"] as? String) ?? "GET"
        let body = obj["body"] as? String
        let charset = obj["charset"] as? String
        var headers: [String: String] = [:]
        if let h = obj["headers"] as? [String: String] {
            headers = h
        }
        return ParsedSearchRequest(url: urlPart, method: method, body: body, headers: headers, charset: charset)
    }

    private struct ParsedSearchRequest {
        let url: String
        let method: String
        let body: String?
        let headers: [String: String]
        /// searchUrl 选项的 charset（如 gbk）；nil 表示未声明
        let charset: String?
    }

    /// 关键词与模式的匹配判定：书名 / 作者 / 简介（简介含主角名等线索）
    private func matches(_ book: ExploredBook, keyword: String, mode: SearchMode) -> Bool {
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
            // 简介中作为独立片段命中（支持按主角名等精确检索）
            let separators = CharacterSet(charactersIn: "，,。.；;、\n\t（）()【】[]“”\"' 　")
            let tokens = intro.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return tokens.contains(k)
        }
    }

    private func sourceLabel(_ source: BookSource) -> String {
        source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName
    }

    /// 解析书源 header 字段（JSON 字符串）为请求头字典。
    /// legado 书源常在此放 Referer / Cookie / User-Agent，缺它会被站点以 401/403 拒绝。
    private func sourceHeaders(_ source: BookSource) -> [String: String] {
        guard let raw = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            return [:]
        }
        // 先试标准双引号 JSON，失败则单引号→双引号转换后再试。
        let obj: [String: Any]?
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = result
        } else {
            let converted = raw.replacingOccurrences(of: "'", with: "\"")
            obj = try? JSONSerialization.jsonObject(
                with: converted.data(using: .utf8) ?? Data()
            ) as? [String: Any]
        }
        guard let obj else {
            return [:]
        }
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

    // MARK: - per-element 规则解析（对应 legado BookListAnalyzer）

    /// 按 ruleSearch 提取结果：bookList 求值产元素列表（CSS / JSON / 正则 / JS），
    /// 再逐元素求值 name / author / intro / bookUrl / coverUrl / lastChapter。
    /// 引擎实例与 searchUrl 阶段共享，保证 @put/@get 变量跨字段生效。
    private func extractSearchResults(html: String,
                                      rules: SourceRuleSet,
                                      source: BookSource,
                                      base: URL,
                                      engine: RuleEngine) throws -> [ExploredBook] {
        let listRule = rules.bookList ?? ""
        guard !listRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }

        var ruleError: String?
        let items = BookListAnalyzer.items(rule: listRule, html: html, engine: engine, error: &ruleError)
        if items.isEmpty {
            if let ruleError {
                // 规则解析失败（区别于「书源没有这本书」）——抛出带具体原因的可见错误
                throw RuleError.ruleFailed(ruleError)
            }
            // 规则正常执行但无匹配：书源未收录该书，不算失败
            return []
        }

        var result: [ExploredBook] = []
        for item in items {
            let name = BookListAnalyzer.field(rules.name, item: item, engine: engine)
            guard !name.isEmpty else { continue }
            let bookUrlRaw = BookListAnalyzer.field(rules.bookUrl, item: item, engine: engine)
            // 书源的 bookUrl 通常相对于书源根路径（如 /book/12345.html），
            // 优先用书源基准 URL 解析，避免拼接到搜索 URL 路径下导致 404。
            let resolved = resolveURL(bookUrlRaw, base: source.bookSourceURL)
                ?? resolveURL(bookUrlRaw, base: base)
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
        return result
    }

    private func addToShelf(_ book: ExploredBook) {
        guard !book.sourceId.isEmpty else {
            addedMessage = "该书目缺少来源书源，无法加入书架"
            return
        }
        guard !book.bookUrl.isEmpty else {
            addedMessage = "该书目没有可用链接，无法加入书架"
            return
        }
        // 去重：同一书源同一 bookUrl 已在书架则跳过
        if bookStore.books.contains(where: { $0.sourceId == book.sourceId && $0.bookUrl == book.bookUrl }) {
            addedMessage = "《\(book.name)》已在书架"
            return
        }
        let newBook = Book(
            id: UUID().uuidString,
            title: book.name,
            author: book.author.isEmpty ? "未知" : book.author,
            format: .txt,
            fileRelativePath: nil,
            remoteURL: book.bookUrl,
            addedAt: Date(),
            fileSize: nil,
            sourceId: book.sourceId,
            bookUrl: book.bookUrl,
            originName: book.sourceName
        )
        bookStore.addBook(newBook)
        addedMessage = "已加入书架：《\(book.name)》"
    }

    // MARK: - 工具

    private func resolveURL(_ relative: String, base: URL?) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        guard let base else { return nil }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}
