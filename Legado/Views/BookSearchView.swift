import SwiftUI
import Combine

/// 搜索进度中转：让后台线程能把进度文本推到主线程 @State，
/// 规避 @Sendable 闭包直接捕获 @State 的编译/并发问题。
final class SearchProgressSink: ObservableObject {
    @Published var text: String? = nil
}

/// 搜索模式：模糊 = 关键词作为子串命中书名/作者/简介；精确 = 书名全等关键词或书名
/// 以关键词开头（覆盖《诛仙（全本）》《诛仙前传》等合法变体），或作者全等。据此剔除
/// 「开局签到诛仙神剑」这类关键词仅作书名片段的无关书，同时保留真正的热门书命中。
enum SearchMode: String, CaseIterable {
    case fuzzy
    case precise
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
    @StateObject private var progressSink = SearchProgressSink()
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

            if let progress = progressSink.text {
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
            } else if results.isEmpty && sourceErrors.isEmpty && !isSearching && progressSink.text == nil {
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

    /// 启动全源并发搜索：委托 SearchCoordinator 在后台线程执行（避免主线程死锁），
    /// 完成后切回主线程应用结果。
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
        progressSink.text = "正在搜索 \(sources.count) 个书源…"
        let currentMode = mode
        let keywordCopy = trimmedKeyword
        // 搜索超时 15s：仅对「可达但偏慢」的书源生效（连接被拒等错误是亚秒级失败，
        // 不占用超时）；超时不再重试（见 NetworkService.isTransient），避免 3× 等待。
        // 全局预算 600s：720 源实测大量超时/死源会快速消耗预算，导致可达源被饿死而 0 结果；
        // 上调到 600s 让更多源被真实尝试。单源超时 20s：放行偏慢但可达的源。
        let searchTimeout: TimeInterval = 20
        let globalBudget: TimeInterval = 600

        let sink = progressSink
        searchTask = Task.detached(priority: .userInitiated) {
            // onStream：每完成一批就把当前命中/失败推上屏，结果实时可见，
            // 不再等 200+s 全跑完才一次性刷新（此前命中永远"最后一刻"才出现）。
            let outcome = await SearchCoordinator.run(
                keyword: keywordCopy,
                mode: currentMode,
                sources: sources,
                searchTimeout: searchTimeout,
                globalBudget: globalBudget,
                onProgress: { text in DispatchQueue.main.async { sink.text = text } },
                hitTarget: 50,
                onStream: { books, errors in
                    DispatchQueue.main.async {
                        results = books
                        sourceErrors = errors
                    }
                }
            )
            await MainActor.run {
                results = outcome.results
                sourceErrors = outcome.errors
                searchSummary = outcome.summary
                errorMessage = outcome.errorMessage
                isSearching = false
                progressSink.text = nil
            }
        }
    }

    /// 随时停止：取消任务并复位状态
    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        progressSink.text = nil
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
