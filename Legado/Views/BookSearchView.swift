import SwiftUI
import SwiftSoup

/// 书源搜索：用已导入书源的 searchUrl + ruleSearch 规则搜索书籍，一键加入书架。
/// 加入书架的书籍保留 sourceId + bookUrl，阅读时走规则阅读路径。
struct BookSearchView: View {
    @EnvironmentObject private var sourceStore: BookSourceStore
    @EnvironmentObject private var bookStore: BookStore
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var selectedSourceURL: String?
    @State private var results: [ExploredBook] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var addedMessage: String?

    /// 可搜索的书源：配置了含 {{key}} 的 searchUrl 且具备 ruleSearch.bookList
    private var searchableSources: [BookSource] {
        sourceStore.sources.filter { $0.supportsSearch && $0.enabled }
    }

    var body: some View {
        NavigationStack {
            Group {
                if searchableSources.isEmpty {
                    ContentUnavailableView {
                        Label("没有可搜索的书源", systemImage: "magnifyingglass")
                    } description: {
                        Text("请先导入带 searchUrl 与搜索规则的 legado 书源")
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
            .onAppear {
                if selectedSourceURL == nil {
                    selectedSourceURL = searchableSources.first?.bookSourceUrl
                }
            }
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
                // 书源选择
                HStack {
                    Text("书源")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("书源", selection: $selectedSourceURL) {
                        ForEach(searchableSources, id: \.bookSourceUrl) { source in
                            Text(source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName)
                                .tag(source.bookSourceUrl as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                }

                // 关键词 + 搜索
                HStack(spacing: 8) {
                    TextField("书名 / 作者关键词", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit(of: .text) { startSearch() }
                    Button {
                        startSearch()
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(width: 56)
                        } else {
                            Text("搜索")
                                .frame(width: 56)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()

            if let error = errorMessage {
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(error)
                }
            } else if results.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("输入关键词开始搜索", systemImage: "text.magnifyingglass")
                } description: {
                    Text("搜索结果来自所选书源的搜索规则")
                }
            } else {
                List(results) { book in
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
                .listStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 搜索逻辑

    private func startSearch() {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return }
        guard let source = searchableSources.first(where: { $0.bookSourceUrl == selectedSourceURL }) else {
            errorMessage = "请选择可搜索的书源"
            return
        }
        guard let rawSearchURL = source.searchUrl, !rawSearchURL.isEmpty else {
            errorMessage = "该书源未配置 searchUrl"
            return
        }
        // legado 约定：searchUrl 可带 ,{"method":...} 选项后缀，截取地址部分
        let urlPart: String
        if let optionsRange = rawSearchURL.range(of: ",{") {
            urlPart = String(rawSearchURL[rawSearchURL.startIndex..<optionsRange.lowerBound])
        } else {
            urlPart = rawSearchURL
        }

        guard urlPart.contains("{{key}}") else {
            errorMessage = "该书源搜索地址缺少 {{key}} 占位符，暂不支持"
            return
        }
        let encoded = trimmedKeyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedKeyword
        let finalString = urlPart.replacingOccurrences(of: "{{key}}", with: encoded)
        guard let finalURL = URLSanitizer.sanitize(finalString) else {
            errorMessage = "搜索地址无效：\(urlPart)"
            return
        }
        guard let rules = source.ruleSearch, !(rules.bookList ?? "").isEmpty else {
            errorMessage = "该书源未配置搜索规则（ruleSearch.bookList）"
            return
        }

        errorMessage = nil
        results = []
        isLoading = true
        Task {
            do {
                let html = try await NetworkService.shared.fetchText(from: finalURL)
                let extracted = try extractSearchResults(html: html, rules: rules, base: finalURL)
                await MainActor.run {
                    results = extracted
                    isLoading = false
                    if extracted.isEmpty {
                        errorMessage = "未搜索到结果（可尝试更换关键词或书源）"
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

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
        guard let source = searchableSources.first(where: { $0.bookSourceUrl == selectedSourceURL }) else {
            addedMessage = "书源不可用"
            return
        }
        guard !book.bookUrl.isEmpty else {
            addedMessage = "该书目没有可用链接，无法加入书架"
            return
        }
        // 去重：同一书源同一 bookUrl 已在书架则跳过
        if bookStore.books.contains(where: { $0.sourceId == source.bookSourceUrl && $0.bookUrl == book.bookUrl }) {
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
            sourceId: source.bookSourceUrl,
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
