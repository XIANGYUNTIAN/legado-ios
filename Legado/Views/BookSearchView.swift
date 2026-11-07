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

/// 结果范围：全部 / 只看视频漫画 / 只看书籍。公子反馈「按名称搜视频总搜不到」，
/// 给一个显式筛选，避免视频结果被几百条小说命中淹没。
enum SearchResultKind: String, CaseIterable {
    case all = "全部"
    case media = "视频"
    case book = "书籍"
}

/// 视频类搜索结果的直达播放目标：优先解析成剧集进原生播放器，失败才回退站点浏览器。
struct SearchPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// 无搜索规则、但有可浏览站点的书源：规则搜索遍历不到它们，给一个
/// 「进站查找」出口，覆盖「网页里能搜到能播、搜索页却没有」的影视站点源。
struct SiteShortcut: Identifiable {
    let id: String
    let name: String
    let url: URL
    /// 带关键词的站内搜索结果页；点直达直接落在结果上，不必再手动输一次。
    let searchURL: URL?
}

/// 一个 sheet item 承载两种去向，避免两个 .sheet 同时争抢 presented 状态。
enum SearchPlaybackRoute: Identifiable {
    case episodes(VodEpisodeList)
    case browser(SearchPlayback)
    /// v49：只有一集时直接进原生播放器，不再多一次选集点击
    case direct(BrowserMedia)

    var id: String {
        switch self {
        case .episodes(let l): return "episodes-" + l.id.uuidString
        case .browser(let p): return "browser-" + p.id.uuidString
        case .direct(let m): return "direct-" + m.id.uuidString
        }
    }
}

/// 书源搜索：遍历全部可搜索书源，按 ruleSearch 规则检索书籍，可加入书架；
/// 视频类书源的结果另给「▶ 直接播放」入口（对齐 legado 搜索结果点开即播）。
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
    @State private var resultKind: SearchResultKind = .all
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
    /// 视频结果直达播放（剧集 / 网页兜底二选一）
    @State private var playback: SearchPlaybackRoute?
    /// 正在做直链解析的目标，用来显示进度并防止重复点击
    @State private var resolvingTarget: URL?
    /// 影视站点通用站内搜索（不依赖书源规则），与规则搜索并行
    @State private var siteSearching = false
    @State private var siteResults: [ExploredBook] = []
    @State private var siteTask: Task<Void, Never>?
    /// v49：站内结果对应的剧集直链（纯值 Sendable，主线程再还原成 VodEpisode）
    @State private var sitePlaylists: [String: [SiteEpisode]] = [:]
    /// 逐站站内搜索诊断：哪个站命中几条、哪个站连搜索页都没拿到
    @State private var siteDiagnostics: [String] = []

    /// 可搜索的书源：配置了含 {{key}} 的 searchUrl 且具备 ruleSearch.bookList
    private var searchableSources: [BookSource] {
        sourceStore.sources.filter { $0.supportsSearch && $0.enabled }
    }

    private var searchKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 没有 searchUrl / ruleSearch.bookList 的书源根本不进搜索队列。
    /// 站点类影视源（书源详情能进站、站内能搜能播）正属于这一类。
    private var siteShortcuts: [SiteShortcut] {
        guard !searchKeyword.isEmpty else { return [] }
        var out: [SiteShortcut] = []
        for s in sourceStore.sources where s.enabled && !s.supportsSearch {
            guard let u = s.siteURLs.first else { continue }
            let name = s.bookSourceName.isEmpty ? (u.host ?? u.absoluteString) : s.bookSourceName
            let target = SiteSearchService.target(source: s)
            out.append(SiteShortcut(id: s.bookSourceUrl + "|" + name, name: name, url: u,
                                    searchURL: SiteSearchService.preferredSearchURL(
                                        target: target, keyword: searchKeyword)))
        }
        // 有搜索规则的影视站点源也留一个进站出口：规则失效 / 站点改版时
        // 规则搜索会返回 0 命中，但站内仍能搜到并播放（公子实测的场景）。
        for s in sourceStore.sources where s.enabled && s.supportsSearch
            && (s.isVideoLike || BookSource.looksLikeMediaName(s.bookSourceName)) {
            guard let u = s.siteURLs.first else { continue }
            let name = s.bookSourceName.isEmpty ? (u.host ?? u.absoluteString) : s.bookSourceName
            let key = s.bookSourceUrl + "|" + name
            if out.contains(where: { $0.id == key }) { continue }
            let target = SiteSearchService.target(source: s)
            out.append(SiteShortcut(id: key, name: name, url: u,
                                    searchURL: SiteSearchService.preferredSearchURL(
                                        target: target, keyword: searchKeyword)))
        }
        guard !out.isEmpty else { return [] }
        let k = searchKeyword.lowercased()
        return Array(out.sorted { a, b -> Bool in
            let am = BookSource.looksLikeMediaName(a.name) ? 1 : 0
            let bm = BookSource.looksLikeMediaName(b.name) ? 1 : 0
            if am != bm { return am > bm }
            let ak = a.name.lowercased().contains(k) ? 1 : 0
            let bk = b.name.lowercased().contains(k) ? 1 : 0
            if ak != bk { return ak > bk }
            return a.name < b.name
        }.prefix(12))
    }

    /// 参与通用站内搜索的影视站点。
    /// v46 缺陷：按书源名称排序取前 10，720 源里排在末尾但真正能用的影视站
    /// 从未被查；且「站点直达」列出的站与被查的站不是同一批。现在以用户可见的
    /// 站点直达列表为优先，再补其他影视源，上限 24。
    private var siteTargets: [SiteTarget] {
        let list = sourceStore.sources.filter { s in
            guard s.enabled, !s.siteURLs.isEmpty else { return false }
            if s.isVideoLike || s.isComicLike { return true }
            if BookSource.looksLikeMediaName(s.bookSourceName)
                || BookSource.looksLikeMediaName(s.bookSourceComment) { return true }
            // v50：诊断截图里 24 站有一半是纯小说站（全本小说 / 八一中文网 /
            // 得间小说 / 多看阅读…）。旧条件 !supportsSearch 把它们全放进来，
            // 白占一半配额且不可能搜出视频。无搜索规则的源再用分组强信号过一遍。
            guard !s.supportsSearch else { return false }
            let g = (s.bookSourceGroup ?? "").lowercased()
            return ["影视", "视频", "电影", "剧集", "采集", "资源", "动漫"]
                .contains { g.contains($0) }
        }
        let visible = Set(siteShortcuts.compactMap { item -> String? in
            guard let first = item.id.split(separator: "|", maxSplits: 1).first else {
                return nil
            }
            return String(first)
        })
        let sorted = list.sorted { a, b in
            let av = visible.contains(a.bookSourceUrl) ? 1 : 0
            let bv = visible.contains(b.bookSourceUrl) ? 1 : 0
            if av != bv { return av > bv }
            let am = BookSource.looksLikeMediaName(a.bookSourceName) ? 1 : 0
            let bm = BookSource.looksLikeMediaName(b.bookSourceName) ? 1 : 0
            if am != bm { return am > bm }
            return a.bookSourceName < b.bookSourceName
        }
        return Array(sorted.prefix(16).map { SiteSearchService.target(source: $0) })
    }

    /// 站点直达区只在搜索结束后出现，避免搜索中列表抖动。
    private var hasSiteSection: Bool {
        // v50：站内结果出来后主结果区让给可播剧集行，网页入口只在 0 命中时备用。
        !isSearching && progressSink.text == nil && !siteShortcuts.isEmpty
            && siteResults.isEmpty
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
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onDisappear { searchTask?.cancel() }
            .sheet(item: $playback) { route in
                Group {
                    switch route {
                    case .episodes(let list):
                        VodEpisodeSheet(list: list)
                    case .browser(let target):
                        SourceBrowserView(title: target.title, initialURL: target.url)
                    case .direct(let media):
                        BrowserPlayerSheet(media: media)
                    }
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
                HStack {
                    Text("结果范围")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("结果范围", selection: $resultKind) {
                        ForEach(SearchResultKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
                Text("精确模式遍历全部书源；视频结果点 ▶ 直达播放，未命中可试「备用网页入口」 · build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if siteSearching {
                    Text("正在影视站点内搜索同名剧集…")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                if !siteResults.isEmpty {
                    Text("站内命中 \(siteResults.count) 条 · 点 ▶ 直接播放")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                if !siteDiagnostics.isEmpty {
                    DisclosureGroup("站内逐站诊断 · \(siteDiagnostics.count) 个站点") {
                        ForEach(siteDiagnostics, id: \.self) { line in
                            Text(line)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }

                // 关键词 + 搜索 / 停止
                HStack(spacing: 8) {
                    TextField("书名 / 视频名 / 作者", text: $keyword)
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

            if let error = errorMessage, !hasSiteSection, siteResults.isEmpty {
                ContentUnavailableView {
                    Label("搜索结束", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(error)
                }
            } else if results.isEmpty && siteResults.isEmpty && sourceErrors.isEmpty && searchSummary.isEmpty
                        && !isSearching && progressSink.text == nil {
                ContentUnavailableView {
                    Label("输入关键词开始搜索", systemImage: "text.magnifyingglass")
                } description: {
                    Text("将遍历全部可搜索书源，按书名 / 视频名 / 作者匹配")
                }
            } else if displayedResults.isEmpty && !hasSiteSection
                        && !isSearching && progressSink.text == nil {
                ContentUnavailableView {
                    Label("当前范围没有结果", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("本轮共搜到 \(allResults.count) 条，切到「全部」查看")
                }
            } else {
                List {
                    if resultKind == .media && !allResults.isEmpty
                        && !allResults.contains(where: { isMediaResult($0) }) {
                        Section {
                            Text("本轮未识别出视频结果，已显示全部 \(allResults.count) 条")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(displayedResults) { book in
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
                            if let target = playbackTarget(for: book) {
                                Button {
                                    Task { await resolvePlayback(target: target,
                                                                 name: book.name,
                                                                 key: book.bookUrl) }
                                } label: {
                                    if resolvingTarget == target {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "play.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(resolvingTarget != nil)
                            }
                            if !book.intro.hasPrefix("站内搜索") {
                                Button {
                                    addToShelf(book)
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if hasSiteSection && displayedResults.isEmpty {
                        Section {
                            Text("本轮规则搜索共 \(allResults.count) 条，当前范围没有匹配项。以下书源没有搜索规则，需进站查找：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if hasSiteSection {
                        Section("备用网页入口 · 站内手动点选") {
                            ForEach(siteShortcuts) { shortcut in
                                Button {
                                    playback = .browser(SearchPlayback(
                                        url: shortcut.searchURL ?? shortcut.url,
                                        title: shortcut.name))
                                } label: {
                                    HStack {
                                        Image(systemName: "safari")
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(shortcut.name)
                                                .font(.subheadline)
                                            Text("打开站内搜索页，手动点选影片播放")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
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

    // MARK: - 结果范围筛选

    /// 搜索结果本身不带类型字段。v45 前只靠「来源书源 isVideoLike」这一个启发式，
    /// 判错一次就全链路失效：结果被「视频」范围筛掉、精确模式剔掉、▶ 也不给。
    /// 改为「书源 + 结果文本 + 链接路径」三通道，任一命中即按媒体处理。
    /// 规则结果与站内结果合并（按详情链接去重）。两路写入不同 @State，
    /// 规则搜索的流式刷新不会把先到的站内结果冲掉。
    private var allResults: [ExploredBook] {
        var seen = Set(results.map { $0.bookUrl.lowercased() })
        var out = results
        for b in siteResults {
            let k = b.bookUrl.lowercased()
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append(b)
        }
        return out
    }

    private var displayedResults: [ExploredBook] {
        var base: [ExploredBook] = []
        switch resultKind {
        case .all: base = allResults
        case .media:
            let matched = allResults.filter { isMediaResult($0) }
            // v49：视频范围不再出现「当前范围没有匹配项」的空白页
            base = matched.isEmpty ? allResults : matched
        case .book: base = allResults.filter { !isMediaResult($0) }
        }
        let k = searchKeyword.lowercased()
        guard !k.isEmpty else { return base }
        // 全源并发的完成顺序不等于相关度；把精确命中提到最前面，免得要找的剧
        // 被几十条小说命中压在列表底部。
        return base.sorted { relevance($0, k) > relevance($1, k) }
    }

    private func relevance(_ book: ExploredBook, _ k: String) -> Int {
        let n = book.name.lowercased()
        if n == k { return 4 }
        if n.hasPrefix(k) { return 3 }
        if n.contains(k) { return 2 }
        if book.author.lowercased().contains(k) { return 1 }
        return 0
    }

    private func isMediaResult(_ book: ExploredBook) -> Bool {
        // 通用站内搜索产出的结果本来就来自影视站点，不再走名称 / 路径启发式。
        if book.intro.hasPrefix("站内搜索") { return true }
        if sourceLooksLikeMedia(book) { return true }
        let text = "\(book.name) \(book.intro) \(book.lastChapter) \(book.sourceName)".lowercased()
        let patterns = ["第[0-9]+集", "共[0-9]+集", "全[0-9]+集", "更新至", "连载中",
                        "1080p", "720p", "2160p", "4k", "蓝光", "正片", "剧场版",
                        "预告片", "国语版", "未删减", "第[0-9]+季", "ep[0-9]+", "ova"]
        for p in patterns {
            if text.range(of: p, options: .regularExpression) != nil { return true }
        }
        let link = book.bookUrl.lowercased()
        let pathHints = ["/series/", "/vod/", "/video/", "/play/", "/movie/",
                         "/drama/", "/watch/", "/bangumi/", "m3u8", ".mp4",
                         "vod_play_url", "provide/vod"]
        return pathHints.contains { link.contains($0) }
    }

    private func sourceLooksLikeMedia(_ book: ExploredBook) -> Bool {
        guard !book.sourceId.isEmpty else { return false }
        return sourceStore.sources.contains {
            BookSource.normalizedURL($0.bookSourceUrl) == BookSource.normalizedURL(book.sourceId)
                && ($0.isVideoLike || $0.isComicLike)
        }
    }

    // MARK: - 多源搜索逻辑

    /// 启动全源并发搜索：委托 SearchCoordinator 在后台线程执行（避免主线程死锁），
    /// 完成后切回主线程应用结果。
    private func runSearch() {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return }
        let allSources = searchableSources
        // 视频 / 图片源优先入队：命中达标停止入队时不会被整批跳过
        let sources = allSources.filter { $0.isVideoLike || $0.isComicLike }
            + allSources.filter { !($0.isVideoLike || $0.isComicLike) }
        guard !sources.isEmpty else {
            errorMessage = "没有可搜索的书源"
            return
        }

        searchTask?.cancel()
        siteTask?.cancel()
        // 「书籍」范围不跑站内搜索；其余范围与规则搜索并行发起。
        let runSite = resultKind != .book
        let siteTargetsCopy = runSite ? siteTargets : []
        siteSearching = runSite
        results = []
        siteResults = []
        siteDiagnostics = []
        sitePlaylists = [:]
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
                onStream: { books, errors in
                    DispatchQueue.main.async {
                        results = books
                        sourceErrors = errors
                    }
                },
                hitTarget: 50
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
        // 精确模式全源遍历可能要几分钟，站内搜索必须并行跑，几秒内就能出视频结果。
        // 结果单独写 siteResults，by design 不与规则搜索的 results 互相覆盖。
        if runSite, !siteTargetsCopy.isEmpty {
            siteTask = Task.detached(priority: .userInitiated) {
                let report = await SiteSearchService.searchReport(targets: siteTargetsCopy,
                                                                   keyword: keywordCopy)
                await MainActor.run {
                    siteSearching = false
                    siteDiagnostics = report.lines
                    var seen = Set<String>()
                    var added: [ExploredBook] = []
                    var playlists: [String: [SiteEpisode]] = [:]
                    for h in report.hits {
                        let key = h.url.lowercased()
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        // 纯值结构可安全跨 actor；VodEpisode 在主线程还原
                        if !h.episodes.isEmpty { playlists[h.url] = h.episodes }
                        added.append(ExploredBook(
                            name: h.name,
                            author: "",
                            intro: "站内搜索 · 影视",
                            bookUrl: h.url,
                            coverUrl: "",
                            lastChapter: "",
                            sourceId: h.sourceId,
                            sourceName: h.sourceName
                        ))
                    }
                    guard !added.isEmpty else { return }
                    sitePlaylists = playlists
                    siteResults = added
                    errorMessage = nil
                }
            }
        } else {
            siteSearching = false
        }
    }

    /// 随时停止：取消任务 + 取消在途网络与已入队 Operation，实现「点停止马上停」
    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        // 立即终止搜索会话：cancelAllOperations 让未开始的源不再执行，
        // cancelActiveRequests 让在途网络请求立即抛错收尾，无需等 20s 超时。
        SearchCoordinator.stopCurrent()
        siteTask?.cancel()
        siteTask = nil
        isSearching = false
        siteSearching = false
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

    // MARK: - 视频结果直达播放

    /// 采集类书源（bookSourceUrl 是「资源采集19」这类名称）同样给 ▶：
    /// 它们的 bookUrl 是 `/api.php/provide/vod/?ac=detail&ids=…`，返回的 JSON 里
    /// `vod_play_url` 已经写好 m3u8 列表，解析后能直接播，不必再进网页。
    private func playbackTarget(for book: ExploredBook) -> URL? {
        // v45：只要结果被判为媒体就给 ▶，不再要求来源书源 isVideoLike。
        // 站点名不含影视词的源此前连「点开进网页播放」这条路都没有。
        guard isMediaResult(book), !book.bookUrl.isEmpty else { return nil }
        // v48：搜索页、列表接口、空参数解析接口不是播放目标，不给 ▶。
        let low = book.bookUrl.lowercased()
        let pageOnly = ["vodsearch", "/search", "?wd=", "&wd=", "keyword=", "?url=&"]
        if pageOnly.contains(where: { low.contains($0) }) { return nil }
        // v49：站内结果已是真实播放直链，不再要求匹配到书源
        if book.intro.hasPrefix("站内搜索") {
            return URLSanitizer.sanitize(book.bookUrl)
        }
        let matchedSource: BookSource? = videoSource(for: book) ?? sourceStore.sources.first(where: {
            BookSource.normalizedURL($0.bookSourceUrl) == BookSource.normalizedURL(book.sourceId)
        })
        guard let source = matchedSource else { return nil }
        if let absolute = URLSanitizer.sanitize(book.bookUrl) { return absolute }
        for base in source.siteURLs {
            if let u = URL(string: book.bookUrl, relativeTo: base)?.absoluteURL { return u }
        }
        guard let base = source.bookSourceURL else { return nil }
        return URL(string: book.bookUrl, relativeTo: base)?.absoluteURL
    }

    /// 点 ▶ 三级兜底：HTTP/JSON 直链 → 隐藏 WebView 嗅探 → 详情页网页。
    /// v48：不再把「站内搜索页」当成兜底目标，用户点结果不该再落回搜索页。
    @MainActor
    private func resolvePlayback(target: URL, name: String, key: String) async {
        guard resolvingTarget == nil else { return }
        resolvingTarget = target
        defer { resolvingTarget = nil }
        let headers = ["Referer": target.absoluteString]

        // ⓪ v49：站内搜索已把 vod_play_url 拆成剧集直链，点 ▶ 直接进播放器，
        // 不再二次抓网页 / 跑 WebView 嗅探。key 用结果行原始 bookUrl，
        // 避免 URL 规范化后与字典键对不上。
        if let stored = sitePlaylists[key] ?? sitePlaylists[target.absoluteString],
           !stored.isEmpty {
            let eps: [VodEpisode] = stored.compactMap { item in
                guard let u = URLSanitizer.sanitize(item.url) else { return nil }
                return VodEpisode(name: item.name, url: u)
            }
            if !eps.isEmpty {
                // 防盗链用直链所在站点根，别把 m3u8 自身当 Referer
                var playHeaders = headers
                if let scheme = target.scheme, let host = target.host {
                    playHeaders["Referer"] = scheme + "://" + host + "/"
                }
                if eps.count == 1 {
                    playback = .direct(BrowserMedia(url: eps[0].url, headers: playHeaders))
                } else {
                    playback = .episodes(VodEpisodeList(title: name, episodes: eps,
                                                        headers: playHeaders,
                                                        referer: target.absoluteString))
                }
                return
            }
        }

        // ① 采集接口 JSON / 页面明文直链
        if let text = try? await NetworkService.shared.fetchText(
            from: target, headers: headers, timeout: 12
        ) {
            let list = VodPlaylistParser.episodes(from: text, base: target)
            if !list.isEmpty {
                playback = .episodes(VodEpisodeList(title: name,
                                                    episodes: list,
                                                    headers: headers,
                                                    referer: target.absoluteString))
                return
            }
        }

        // ② JS 渲染详情页：从真实发起的媒体请求里拿直链
        let probed = await PlaybackProbe.mediaURLs(from: target,
                                                   referer: target.absoluteString)
        if !probed.isEmpty {
            var episodes: [VodEpisode] = []
            for (idx, u) in probed.enumerated() {
                let label = probed.count == 1 ? "播放" : "第\(idx + 1)集"
                episodes.append(VodEpisode(name: label, url: u))
            }
            playback = .episodes(VodEpisodeList(title: name,
                                                episodes: episodes,
                                                headers: headers,
                                                referer: target.absoluteString))
            return
        }

        // ③ 仍拿不到直链：落到详情页本身（不是搜索页），网页里点播放即可
        playback = .browser(SearchPlayback(url: target, title: name))
    }

    private func videoSource(for book: ExploredBook) -> BookSource? {
        guard !book.sourceId.isEmpty,
              let source = sourceStore.sources.first(where: {
                  BookSource.normalizedURL($0.bookSourceUrl) == BookSource.normalizedURL(book.sourceId)
              }), source.isVideoLike else { return nil }
        return source
    }

    // MARK: - 工具

    private func resolveURL(_ relative: String, base: URL?) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        guard let base else { return nil }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}
