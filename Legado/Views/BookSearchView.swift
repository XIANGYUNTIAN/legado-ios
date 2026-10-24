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
                Text("将遍历全部 \(searchableSources.count) 个可搜索书源；关键词支持书名 / 作者 / 主角名")
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
            } else if results.isEmpty && !isSearching && progressText == nil {
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
                }
                .listStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 多源搜索逻辑

    /// 启动全源遍历搜索。取消上一次未完成任务，再并发无关地逐源检索。
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
        progressText = "正在遍历 \(sources.count) 个书源…"
        let currentMode = mode
        let keywordCopy = trimmedKeyword

        searchTask = Task {
            var seen = Set<String>()
            for (index, source) in sources.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    progressText = "正在搜索 \(sourceLabel(source))（\(index + 1)/\(sources.count)）"
                }
                do {
                    let books = try await performSingleSourceSearch(
                        source: source, keyword: keywordCopy, mode: currentMode
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
                } catch {
                    if Task.isCancelled { break }
                    let msg: String
                    if let ne = error as? NetworkError, case .cancelled = ne {
                        break
                    } else {
                        msg = error.localizedDescription
                    }
                    await MainActor.run {
                        sourceErrors.append(SourceSearchError(name: sourceLabel(source), message: msg))
                    }
                }
            }
            await MainActor.run {
                isSearching = false
                progressText = nil
                if results.isEmpty {
                    if sourceErrors.isEmpty {
                        errorMessage = "全部书源均未搜索到「\(keywordCopy)」"
                    } else {
                        errorMessage = "未找到匹配结果（部分书源失败，详见下方列表）"
                    }
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
    private func performSingleSourceSearch(source: BookSource,
                                            keyword: String,
                                            mode: SearchMode) async throws -> [ExploredBook] {
        let rawSearchURL = source.searchUrl ?? ""
        guard !rawSearchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkError.invalidURL
        }
        let request = parseSearchRequest(raw: rawSearchURL)
        guard request.url.contains("{{key}}") || request.url.contains("searchKey") else {
            throw NetworkError.invalidURL
        }
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // 占位符替换：{{key}} / searchKey → 关键词；{{searchPage}} / searchPage → 页码。
        var finalURLString = request.url
        finalURLString = finalURLString.replacingOccurrences(of: "{{key}}", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "searchKey", with: encoded)
        finalURLString = finalURLString.replacingOccurrences(of: "{{searchPage}}", with: "1")
        finalURLString = finalURLString.replacingOccurrences(of: "searchPage", with: "1")
        guard let finalURL = URLSanitizer.sanitize(finalURLString) else {
            throw NetworkError.invalidURL
        }
        guard let rules = source.ruleSearch, !(rules.bookList ?? "").isEmpty else {
            throw NetworkError.invalidURL
        }

        let html: String
        if request.method.uppercased() == "POST", let bodyTemplate = request.body {
            var finalBody = bodyTemplate
            finalBody = finalBody.replacingOccurrences(of: "{{key}}", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "searchKey", with: encoded)
            finalBody = finalBody.replacingOccurrences(of: "{{searchPage}}", with: "1")
            finalBody = finalBody.replacingOccurrences(of: "searchPage", with: "1")
            let bodyData = finalBody.data(using: .utf8)
            html = try await NetworkService.shared.fetchTextWithBody(
                from: finalURL, method: "POST", body: bodyData, headers: request.headers
            )
        } else {
            html = try await NetworkService.shared.fetchText(from: finalURL, headers: request.headers)
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
            let document = try SwiftSoup.parse(html)
            let elements = try document.select(selector)
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
