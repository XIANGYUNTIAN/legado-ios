import SwiftUI
import Foundation
import SwiftSoup
import WebKit

/// 订阅源文章列表（对应 legado 订阅源的阅读入口）。
///
/// 修复「导入的订阅源打不开」：此前订阅源行点击只做启用/禁用切换，没有阅读页面。
/// 本视图负责：抓取 sourceUrl → 解析文章列表（优先用订阅源自定义规则 ruleArticles 等，
/// 无规则则按 RSS / Atom 原生 XML 解析）→ 列表展示 → 点击文章在 WebView 打开。
///
/// 解析策略与 legado RssSourceAnalyzer 对齐：
/// - 自定义规则存在时，把 ruleArticles 对象里的 ruleArticles（容器）/ ruleTitle / ruleLink /
///   rulePubDate / ruleDescription / ruleImage 映射进 BookListAnalyzer 逐元素求值
///   （HTML / JSON / XPath / 正则通用）；
/// - 无自定义规则时（绝大多数标准 RSS / Atom 订阅源），走原生 XMLParser 抽取 item/entry。
struct SubscriptionArticleListView: View {
    let source: SubscriptionSource

    @State private var articles: [RssArticle] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var nextPageURL: URL?
    @State private var isLoadingMore = false

    var body: some View {
        if source.singleUrl {
            singleUrlView
        } else {
            Group {
                if isLoading {
                    ProgressView("正在加载订阅…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "exclamation.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if articles.isEmpty {
                    ContentUnavailableView {
                        Label("暂无文章", systemImage: "newspaper")
                    } description: {
                        Text("订阅源「\(source.sourceName)」未解析到文章，可能站点结构已变或需要特定请求头。")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    articleList
                }
            }
            .navigationTitle(source.sourceName.isEmpty ? "订阅" : source.sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if articles.isEmpty { Task { await loadFirst() } } }
        }
    }

/// singleUrl 模式：源 URL 本身就是一个可浏览页面（如地址发布页/导航页），
   /// 对齐 legado Android 行为：直接在 WebView 中打开，不走 RSS/Atom 列表解析。
   private var singleUrlView: some View {
       SingleUrlWebView(url: source.sourceUrl, title: source.sourceName)
   }

   private var articleList: some View {
        List {
            ForEach(articles) { article in
                Button {
                    open(article)
                } label: {
                    HStack(spacing: 12) {
                        if let img = article.imageURL, !img.isEmpty {
                            AsyncImage(url: URLSanitizer.sanitize(img)) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .clipped()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(article.title)
                                .font(.headline)
                                .lineLimit(2)
                            if !article.pubDate.isEmpty {
                                Text(article.pubDate)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !article.description.isEmpty {
                                Text(article.description.stripTags())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            if let next = nextPageURL {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView()
                    } else {
                        Button("加载更多") { Task { await loadMore(from: next) } }
                    }
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 加载

    private func loadFirst() async {
        await fetchPage(URLSanitizer.sanitize(source.sourceUrl) ?? URL(string: source.sourceUrl))
    }

    private func loadMore(from url: URL) async {
        guard !isLoadingMore else { return }
        await MainActor.run { isLoadingMore = true }
        await fetchPage(url, append: true)
        await MainActor.run { isLoadingMore = false }
    }

    private func fetchPage(_ url: URL?, append: Bool = false) async {
        guard let url else {
            if !append { await MainActor.run { errorMessage = "订阅源地址无效：\(source.sourceUrl)"; isLoading = false } }
            return
        }
        var headers = Self.decodeHeader(source.header)
        if headers["User-Agent"] == nil {
            headers["User-Agent"] = NetworkService.iPhoneUA
        }
        do {
            let html = try await NetworkService.shared.fetchText(from: url, headers: headers)
            let (pageArticles, next) = Self.parsePage(html: html, source: source, baseURL: url)
            await MainActor.run {
                if append {
                    articles.append(contentsOf: pageArticles)
                } else {
                    articles = pageArticles
                    isLoading = false
                }
                nextPageURL = next
            }
        } catch {
            await MainActor.run {
                if !append {
                    errorMessage = "订阅加载失败：\(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func open(_ article: RssArticle) {
        guard let url = URLSanitizer.sanitize(article.link) else { return }
        WebViewPresenter.shared.present(url: url.absoluteString, title: article.title)
    }

    // MARK: - 解析

    /// 解析一页，返回（文章列表，下一页 URL）。下一页仅当 ruleNextPage 命中时计算。
    static func parsePage(html: String, source: SubscriptionSource, baseURL: URL) -> ([RssArticle], URL?) {
        let container = source.ruleArticles.trimmingCharacters(in: .whitespacesAndNewlines)
        let articles: [RssArticle]
        if !container.isEmpty {
            articles = parseByRules(container: container, html: html, source: source, baseURL: baseURL)
        } else if let rss = RssXmlParser.parse(xml: html, baseURL: baseURL) {
            articles = rss
        } else {
            articles = []
        }

        let nextRule = source.ruleNextPage.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: URL?
        if !nextRule.isEmpty {
            let engine = RuleEngine()
            if let resolved = (try? engine.getString(nextRule, content: html))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !resolved.isEmpty,
               let u = URLSanitizer.sanitize(resolved)
                  ?? URL(string: resolved, relativeTo: baseURL)?.absoluteURL {
                next = u
            }
        }
        return (articles, next)
    }

    /// 自定义规则解析（复用书源规则引擎 BookListAnalyzer，与书源 bookList 同语义）
    static func parseByRules(container: String, html: String, source: SubscriptionSource, baseURL: URL) -> [RssArticle] {
        let engine = RuleEngine()
        var synthetic = BookSource()
        synthetic.bookSourceUrl = source.sourceUrl
        synthetic.bookSourceName = source.sourceName
        synthetic.header = source.header
        engine.setSource(synthetic)
        engine.setBaseUrl(source.sourceUrl)

        // 对齐 legado：字段规则为 RssSource 顶层字符串，不再从规则对象字典读取
        let titleRule = source.ruleTitle
        let linkRule = source.ruleLink
        let pubDateRule = source.rulePubDate
        let descRule = source.ruleDescription
        let imageRule = source.ruleImage

        var ruleError: String?
        let items = BookListAnalyzer.items(rule: container, html: html, engine: engine, ruleError: &ruleError)
        var result: [RssArticle] = []
        for item in items {
            let title = BookListAnalyzer.field(titleRule, item: item, engine: engine)
            guard !title.isEmpty else { continue }
            let link = Self.resolveURL(BookListAnalyzer.field(linkRule, item: item, engine: engine), base: baseURL)
            let pubDate = BookListAnalyzer.field(pubDateRule, item: item, engine: engine)
            let desc = BookListAnalyzer.field(descRule, item: item, engine: engine)
            let img = Self.resolveURL(BookListAnalyzer.field(imageRule, item: item, engine: engine), base: baseURL)
            result.append(RssArticle(title: title,
                                    link: link ?? "",
                                    pubDate: pubDate,
                                    description: desc,
                                    imageURL: img))
        }
        return result
    }

    static func resolveURL(_ rel: String, base: URL?) -> String? {
        let t = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URLSanitizer.sanitize(t) { return u.absoluteString }
        if let base, let u = URL(string: t, relativeTo: base)?.absoluteURL { return u.absoluteString }
        return nil
    }

    static func decodeHeader(_ raw: String?) -> [String: String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (k, v) in obj { result[k] = v is String ? v as! String : String(describing: v) }
        return result
    }
}

// MARK: - singleUrl 专用 WebView

/// singleUrl 源的独立 WebView：源 URL 本身是可浏览页面（地址发布页/导航页），
/// 对齐 legado Android ReadRssActivity(singleUrl=true) 行为。
///
/// 与 WebViewContainer（用于 startBrowserAwait 的 JS 桥场景）不同：
/// - 本视图专为「用户自主浏览」设计，实现完整 decidePolicyFor 允许所有导航
/// - 顶部工具栏含后退/前进/刷新/完成，不依赖 JS 桥
/// - 不使用 ZStack 遮挡 ProgressView（避免触摸被拦截）
struct SingleUrlWebView: View {
    let url: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = SingleUrlWebViewCoordinator()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: WebView
                SingleUrlWebViewContainer(
                    url: url,
                    coordinator: $coordinator
                )
            }
            .navigationTitle(title.isEmpty ? "网页" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            coordinator.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!coordinator.canGoBack)

                        Button {
                            coordinator.goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!coordinator.canGoForward)

                        Button {
                            coordinator.reload()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                }
            }
        }
    }
}

/// SingleUrlWebView 的 Coordinator：持有 WKWebView 引用，处理导航状态和工具栏操作。
/// 使用 @StateObject 风格的 ObservableObject，通过 Binding 传递给 WebViewContainer。
final class SingleUrlWebViewCoordinator: ObservableObject {
    @Published var isLoading = true
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: String?

    private weak var wk: WKWebView?

    func setWK(_ wk: WKWebView) {
        self.wk = wk
    }

    func goBack() {
        guard let wk, wk.canGoBack else { return }
        wk.goBack()
    }

    func goForward() {
        guard let wk, wk.canGoForward else { return }
        wk.goForward()
    }

    func reload() {
        guard let wk else { return }
        wk.reload()
    }
}

/// SingleUrlWebView 的 WKWebViewRepresentable
/// - 实现 decidePolicyFor 允许所有导航，确保页面内 <a> 链接点击后在 WebView 内部跳转
private struct SingleUrlWebViewContainer: UIViewRepresentable {
    let url: String
    @Binding var coordinator: SingleUrlWebViewCoordinator

    func makeCoordinator() -> SingleUrlWebViewCoordinator {
        coordinator
    }

    func make(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaPlaybackRequiresUserAction = false
        let wk = WKWebView(frame: .zero, configuration: config)
        wk.navigationDelegate = context.coordinator
        wk.allowsBackForwardNavigationGestures = true
        coordinator.setWK(wk)
        if let u = URL(string: url) {
            wk.load(URLRequest(url: u))
        }
        return wk
    }

    func updateouiView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Coordinator 作为 WKNavigationDelegate

extension SingleUrlWebViewCoordinator: WKNavigationDelegate {
    func wkWebView(_ wk: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                   decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 允许所有导航（包括页面内链接点击），确保用户能自由点击链接
        decisionHandler(.allow)
    }

    func wkWebView(_ wk: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func wkWebView(_ wk: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = wk.canGoBack
        canGoForward = wk.canGoForward
        currentURL = wk.url?.absoluteString
    }

    func wkWebView(_ wk: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func wkWebView(_ wk: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                   withError error: Error) {
        isLoading = false
    }
}

/// 订阅源文章模型
struct RssArticle: Identifiable {
    let id = UUID()
    let title: String
    let link: String
    let pubDate: String
    let description: String
    let imageURL: String?
}

// MARK: - 文本清洗（描述摘要）

extension String {
    /// 去除 HTML 标签并压缩空白，用于文章描述摘要
    func stripTags() -> String {
        var s = self
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - RSS / Atom 原生解析

/// 标准 RSS 2.0（<item>）与 Atom（<entry>）订阅源解析。
/// 对应 legado 对无自定义规则的订阅源的处理：直接按 XML 结构抽取文章。
final class RssXmlParser {
    private var items: [RssArticle] = []
    private var baseURL: URL?

    private struct RssArticleBuilder {
        var title = ""
        var link = ""
        var pubDate = ""
        var description = ""
        var imageURL: String?
    }

    /// 用 SwiftSoup 解析 RSS/Atom（与 legado Jsoup 对齐：同时兼容 XML 与 HTML）。
    /// 旧实现依赖 XMLParserDelegate，严格 XML 解析器遇到 HTML 源即静默失败返回空。
    static func parse(xml: String, baseURL: URL?) -> [RssArticle]? {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            let doc = try SwiftSoup.parse(trimmed)
            // RSS <item> 与 Atom <entry> 合并
            let items = try doc.select("item").array()
            let entries = try doc.select("entry").array()
            let elements = items + entries
            guard !elements.isEmpty else { return nil }

            var result: [RssArticle] = []
            for element in elements {
                let title = ((try? element.select("title").text())?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                guard !title.isEmpty else { continue }

                var link = ((try? element.select("link").text())?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                if link.isEmpty {
                    link = ((try? element.select("link").attr("href"))?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                }

                let pubDate = ((try? element.select("pubDate, published, updated, dc:date").text())?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

                var description = ((try? element.select("description, summary, content, content:encoded").text())?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                if description.isEmpty {
                    description = ((try? element.select("content").attr("url"))?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                }

                var imageURL: String?
                // enclosure url
                if let u = try? element.select("enclosure").attr("url"), !u.isEmpty {
                    imageURL = u
                }
                // media:content / media:thumbnail url
                if imageURL == nil,
                   let u = try? element.select("media\\:content, media\\:thumbnail").attr("url"), !u.isEmpty {
                    imageURL = u
                }
                // content url attr
                if imageURL == nil,
                   let u = try? element.select("content").attr("url"), !u.isEmpty {
                    imageURL = u
                }
                // image > url text
                if imageURL == nil,
                   let u = try? element.select("image url").text(), !u.isEmpty {
                    imageURL = u
                }

                let resolvedLink = Self.resolve(link, base: baseURL)
                let resolvedImg = imageURL.flatMap { Self.resolve($0, base: baseURL) }

                result.append(RssArticle(
                    title: title,
                    link: resolvedLink ?? "",
                    pubDate: pubDate,
                    description: description,
                    imageURL: resolvedImg
                ))
            }
            return result.isEmpty ? nil : result
        } catch {
            return nil
        }
    }

    private static func resolve(_ rel: String, base: URL?) -> String? {
        let t = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t) { return u.absoluteString }
        if let base, let u = URL(string: t, relativeTo: base)?.absoluteURL { return u.absoluteString }
        return nil
    }
