import SwiftUI
import SwiftSoup

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
        }.count
        let withRule = all.filter { !($0.ruleSearch?.bookList ?? "").isEmpty }.count
        let disabledCount = all.filter { !$0.enabled }.count

        if trimmedSearchURLCount < all.count {
            return "已导入 \(all.count) 个书源，仅 \(trimmedSearchURLCount) 个带 searchUrl 字段。缺失该字段的多为旧版本导入（当时未持久化 searchUrl）——请到「书源」页重新导入同一份书源 JSON 即可刷新。"
        }
        if withPlaceholder < trimmedSearchURLCount {
            return "书源的搜索地址均不含 {{key}} / searchKey 占位符，无法拼接搜索请求。"
        }
        if withRule < withPlaceholder {
            return "书源缺少 ruleSearch.bookList 规则，无法解析搜索结果。"
        }
        if disabledCount == all.count {
            return "全部 \(all.count) 个书源均被停用。请到「书源」页开启后再搜索。"
        }
        return "已导入 \(all.count) 个书源，但均不满足搜索条件（需 searchUrl 含 {{key}}/searchKey 占位符 + ruleSearch.bookList 规则，且书源处于启用状态）。"
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
                let semaphore = SearchSemaphore(value: 20)

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
                // 诊断摘要：让用户理解「成功但未命中」与「失败」的区别。
                // 成功但未命中 = HTTP 200 但搜索结果不含关键词（书源内容不覆盖该小说）。
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

    /// 单个书源搜索：解析 searchUrl（含 POST 选项后缀）、发请求、按规则解析、
    /// 再按关键词与模式过滤。返回已标注来源、已按模式过滤的结果。
    /// - Parameter timeout: 请求超时（秒），搜索页用较短值避免死站阻塞整体进度。
    private func performSingleSourceSearch(source: BookSource,
                                            keyword: String,
                                            mode: SearchMode,
                                            timeout: TimeInterval? = nil) async throws -> [ExploredBook] {
        let rawSearchURL = source.searchUrl ?? ""
        guard !rawSearchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }
        let request = parseSearchRequest(raw: rawSearchURL)
        // 占位符可能在 URL，也可能只在 POST body（如 method=POST, body=key={{key}}）。
        // 旧实现只查 URL，导致 body-only 的 POST 书源被误判「链接格式不正确」而全部失败。
        let bodyTemplateText = request.body ?? ""
        let hasKeyPlaceholder = request.url.contains("{{key}}")
            || request.url.contains("searchKey")
            || bodyTemplateText.contains("{{key}}")
            || bodyTemplateText.contains("searchKey")
            || rawSearchURL.contains("{{key}}")
            || rawSearchURL.contains("searchKey")
        guard hasKeyPlaceholder else {
            throw NetworkError.invalidURL
        }
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // 占位符替换：{{key}} / searchKey → 关键词；{{searchPage}} / searchPage → 页码。
        var finalURLString = request.url
        finalURLString = finalURLString.replacingOccurrences(of: "{{key}}", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "searchKey", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "{{searchPage}}", with: "1")
        finalURLString = finalURLString.replacingOccurrences(of: "searchPage", with: "1")
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

        let html: String
        if request.method.uppercased() == "POST", let bodyTemplate = request.body {
            var finalBody = bodyTemplate
            finalBody = finalBody.replacingOccurrences(of: "{{key}}", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "searchKey", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "{{searchPage}}", with: "1")
            finalBody = finalBody.replacingOccurrences(of: "searchPage", with: "1")
            let bodyData = finalBody.data(using: .utf8)
            html = try await NetworkService.shared.fetchTextWithBody(
                from: finalURL, method: "POST", body: bodyData, headers: mergedHeaders,
                timeout: timeout
            )
        } else {
            html = try await NetworkService.shared.fetchText(from: finalURL, headers: mergedHeaders, timeout: timeout)
        }

        let extracted = try extractSearchResults(html: html, rules: rules, base: finalURL)
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
    private func parseSearchRequest(raw: String) -> ParsedSearchRequest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: ",{") else {
            return ParsedSearchRequest(url: trimmed, method: "GET", body: nil, headers: [:])
        }
        let urlPart = String(trimmed[trimmed.startIndex..<range.lowerBound])
        let optionsString = String(trimmed[range.lowerBound..<trimmed.endIndex]).dropFirst() // 去掉逗号，留 {…}
        guard let data = optionsString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                ?? try? JSONSerialization.jsonObject(
                    with: optionsString.replacingOccurrences(of: "'", with: "\"").data(using: .utf8) ?? Data()
                ) as? [String: Any] else {
            return ParsedSearchRequest(url: urlPart, method: "GET", body: nil, headers: [:])
        }
        let method = (obj["method"] as? String) ?? "GET"
        let body = obj["body"] as? String
        var headers: [String: String] = [:]
        if let h = obj["headers"] as? [String: String] {
            headers = h
        }
        return ParsedSearchRequest(url: urlPart, method: method, body: body, headers: headers)
    }

    private struct ParsedSearchRequest {
        let url: String
        let method: String
        let body: String?
        let headers: [String: String]
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
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                ?? try? JSONSerialization.jsonObject(
                    with: raw.replacingOccurrences(of: "'", with: "\"").data(using: .utf8) ?? Data()
                ) as? [String: Any] else {
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

    // MARK: - 规则解析（逐源复用）

    /// 按 ruleSearch 提取结果：优先 per-element（bookList 选容器，逐元素求值），
    /// 回退整页规则 + 按索引压缩。
    private func extractSearchResults(html: String, rules: SourceRuleSet, base: URL) throws -> [ExploredBook] {
        let listRule = rules.bookList ?? ""
        let nameRule = rules.name ?? ""
        let authorRule = rules.author ?? ""
        let introRule = rules.intro ?? ""
        let bookUrlRule = rules.bookUrl ?? ""
        let coverRule = rules.coverUrl ?? ""
        let lastRule = rules.lastChapter ?? ""

        // per-element 模式（仅 CSS 选择器可直接取元素节点）
        if listRule.hasPrefix("@css:") || listRule.hasPrefix("@@") {
            let selector = stripCssPrefix(listRule)
            // SwiftSoup 解析/选择器可能因 malformed HTML 或选择器不匹配而抛出，
            // 这里静默失败并回退到整页规则路径，避免单个书源的 HTML 小瑕疵拖垮全局搜索。
            guard let document = try? SwiftSoup.parse(html),
                  let elements = try? document.select(selector) else {
                break
            }
            var result: [ExploredBook] = []
            for element in elements {
                let name = HtmlRuleEngine.extractValue(nameRule, on: element)
                guard !name.isEmpty else { continue }
                let bookUrl = HtmlRuleEngine.extractValue(bookUrlRule, on: element)
                let resolved = resolveURL(bookUrl, base: base)
                result.append(ExploredBook(
                    name: name,
                    author: HtmlRuleEngine.extractValue(authorRule, on: element),
                    intro: HtmlRuleEngine.extractValue(introRule, on: element),
                    bookUrl: resolved?.absoluteString ?? bookUrl,
                    coverUrl: HtmlRuleEngine.extractValue(coverRule, on: element),
                    lastChapter: HtmlRuleEngine.extractValue(lastRule, on: element)
                ))
            }
            if !result.isEmpty { return result }
        }

        // 回退：整页规则 + 按索引压缩
        let nameEngine = RuleEngine()
        let urlEngine = RuleEngine()
        let names = (try? nameEngine.getStringList(nameRule, content: html)) ?? []
        let urls = (try? urlEngine.getStringList(bookUrlRule, content: html)) ?? []
        let count = min(names.count, urls.count)
        var result: [ExploredBook] = []
        for i in 0..<count {
            let resolved = resolveURL(urls[i], base: base)
            result.append(ExploredBook(
                name: names[i],
                author: "",
                intro: "",
                bookUrl: resolved?.absoluteString ?? urls[i],
                coverUrl: "",
                lastChapter: ""
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
            bookUrl: book.bookUrl
        )
        bookStore.addBook(newBook)
        addedMessage = "已加入书架：《\(book.name)》"
    }

    // MARK: - 工具

    private func stripCssPrefix(_ rule: String) -> String {
        var body = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("@css:") {
            body = String(body.dropFirst(5))
        } else if body.hasPrefix("@@") {
            body = String(body.dropFirst(2))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveURL(_ relative: String, base: URL) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}
