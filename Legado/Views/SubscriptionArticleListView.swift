import SwiftUI
import Foundation

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
        let dict = source.ruleArticles ?? [:]
        let container = (dict["ruleArticles"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let articles: [RssArticle]
        if !container.isEmpty {
            articles = parseByRules(dict: dict, container: container, html: html, source: source, baseURL: baseURL)
        } else if let rss = RssXmlParser.parse(xml: html, baseURL: baseURL) {
            articles = rss
        } else {
            articles = []
        }

        let nextRule = (dict["ruleNextPage"] ?? source.ruleNextPage).trimmingCharacters(in: .whitespacesAndNewlines)
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
    static func parseByRules(dict: [String: String], container: String, html: String, source: SubscriptionSource, baseURL: URL) -> [RssArticle] {
        let engine = RuleEngine()
        var synthetic = BookSource()
        synthetic.bookSourceUrl = source.sourceUrl
        synthetic.bookSourceName = source.sourceName
        synthetic.header = source.header
        engine.setSource(synthetic)
        engine.setBaseUrl(source.sourceUrl)

        let titleRule = dict["ruleTitle"] ?? source.ruleTitle
        let linkRule = dict["ruleLink"] ?? source.ruleLink
        let pubDateRule = dict["rulePubDate"] ?? source.rulePubDate
        let descRule = dict["ruleDescription"] ?? source.ruleDescription
        let imageRule = dict["ruleImage"] ?? source.ruleImage

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
final class RssXmlParser: NSObject, XMLParserDelegate {
    private var items: [RssArticle] = []
    private var current: RssArticleBuilder?
    private var currentElement = ""
    private var currentText = ""
    private var baseURL: URL?

    private struct RssArticleBuilder {
        var title = ""
        var link = ""
        var pubDate = ""
        var description = ""
        var imageURL: String?
    }

    static func parse(xml: String, baseURL: URL?) -> [RssArticle]? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let parser = RssXmlParser()
        parser.baseURL = baseURL
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { return nil }
        return parser.items.isEmpty ? nil : parser.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        currentElement = elementName.lowercased()
        let en = elementName.lowercased()
        if en == "item" || en == "entry" {
            current = RssArticleBuilder()
            currentText = ""
        } else if en == "link" {
            // Atom 的 link 用 href 属性；RSS 的 link 用文本内容
            if let href = attributeDict["href"], !href.isEmpty {
                current?.link = href
            }
            currentText = ""
        } else if en == "enclosure" {
            if let url = attributeDict["url"], !url.isEmpty {
                current?.imageURL = url
            }
        } else if en == "media:content" || en == "media:thumbnail" || en == "content" {
            // media:content / content 常带 url 属性（封面或视频）
            if let url = attributeDict["url"], !url.isEmpty {
                current?.imageURL = url
            }
        } else if en == "image" {
            currentText = ""
        } else {
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let en = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch en {
        case "item", "entry":
            if let b = current, !b.title.isEmpty {
                let resolvedLink = Self.resolve(b.link, base: baseURL)
                let resolvedImg = b.imageURL.flatMap { Self.resolve($0, base: baseURL) }
                items.append(RssArticle(title: b.title,
                                       link: resolvedLink ?? "",
                                       pubDate: b.pubDate,
                                       description: b.description,
                                       imageURL: resolvedImg))
            }
            current = nil
        case "title":
            if current?.title.isEmpty ?? true { current?.title = text }
        case "link":
            if current?.link.isEmpty ?? true, !text.isEmpty { current?.link = text }
        case "pubdate", "published", "updated", "dc:date":
            if current?.pubDate.isEmpty ?? true { current?.pubDate = text }
        case "description", "summary", "content", "content:encoded":
            if current?.description.isEmpty ?? true { current?.description = text }
        case "image":
            // RSS <image><url>...</url></image>
            if let img = current?.imageURL, img.isEmpty, !text.isEmpty {
                current?.imageURL = text
            }
        default:
            break
        }
        currentText = ""
    }

    private static func resolve(_ rel: String, base: URL?) -> String? {
        let t = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t) { return u.absoluteString }
        if let base, let u = URL(string: t, relativeTo: base)?.absoluteURL { return u.absoluteString }
        return nil
    }
}
