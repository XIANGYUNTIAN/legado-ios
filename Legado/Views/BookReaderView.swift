import SwiftUI
import SwiftSoup

// MARK: - 章节模型

struct ReaderChapter: Identifiable {
    let id = UUID()
    let title: String
    var text: String?      // 本地章节正文（网络章节为 nil，按需抓取）
    var url: String?       // 网络章节 URL
}

// MARK: - 阅读器主视图

/// 三种阅读模式统一入口：
/// - 本地 TXT：直接读文件、按章节标题切分
/// - 本地 EPUB：经 EPUBReader 抽取章节正文
/// - 规则阅读：用书源 ruleToc / ruleContent 抓取目录与正文（CSS / XPath）
struct BookReaderView: View {
    let book: Book

    @EnvironmentObject private var sourceStore: BookSourceStore
    @EnvironmentObject private var bookStore: BookStore
    @EnvironmentObject private var settings: ReaderSettings

    @State private var chapters: [ReaderChapter] = []
    @State private var currentIndex = 0
    @State private var displayText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showChapterList = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("读取失败", systemImage: "exclamation.triangle")
                    } description: {
                        Text(error)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    readerContent
                }
            }
            .background(settings.theme.background)
            .safeAreaInset(edge: .bottom) { readerToolbar }
            .sheet(isPresented: $showChapterList) { chapterListSheet }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .navigationTitle(currentChapter?.title ?? book.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(visibility: .hidden, for: .tabBar)
            .onAppear { load() }
        }
    }

    // MARK: - 正文渲染

    private var readerContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if settings.showChapterHeader, let chapter = currentChapter {
                        Text(chapter.title)
                            .font(settings.fontFamily.font)
                            .fontSize(settings.fontSize)
                            .foregroundStyle(settings.theme.foreground)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, settings.lineSpacing * 2)
                    }
                    Text(displayText)
                        .font(settings.fontFamily.font)
                        .fontSize(settings.fontSize)
                        .lineSpacing(settings.lineSpacing)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(settings.theme.foreground)
                        .textSelection(.enabled)
                        .id("content")
                }
                .padding(.horizontal, 20)
            }
            .onChange(of: currentIndex) { _, _ in
                withAnimation { proxy.scrollTo("content", anchor: .top) }
            }
            .onChange(of: displayText) { _, _ in
                withAnimation { proxy.scrollTo("content", anchor: .top) }
            }
        }
    }

    private var currentChapter: ReaderChapter? {
        chapters.indices.contains(currentIndex) ? chapters[currentIndex] : nil
    }

    // MARK: - 工具栏

    private var readerToolbar: some View {
        HStack {
            Button {
                showChapterList = true
            } label: {
                Image(systemName: "list.bullet")
                Text(currentChapter?.title ?? "目录")
            }
            .foregroundStyle(settings.theme.foreground)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "a.circle")
            }
            .foregroundStyle(settings.theme.foreground)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    // MARK: - 章节目录

    private var chapterListSheet: some View {
        NavigationStack {
            List(chapters.indices, id: \.self) { index in
                let chapter = chapters[index]
                Button {
                    switchTo(index: index)
                    showChapterList = false
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundStyle(currentIndex == index ? settings.theme.foreground : .primary)
                        Spacer()
                        if currentIndex == index {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("目录（\(chapters.count)章）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showChapterList = false }
                }
            }
        }
    }

    // MARK: - 阅读设置

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                        Button {
                            settings.apply(theme)
                        } label: {
                            HStack {
                                Text(theme.rawValue)
                                Spacer()
                                if settings.theme == theme {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("字体") {
                    ForEach(ReaderSettings.FontFamily.allCases, id: \.self) { font in
                        Button {
                            settings.fontFamily = font
                            settings.save()
                        } label: {
                            HStack {
                                Text(font.rawValue)
                                Spacer()
                                if settings.fontFamily == font {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("字号：\(Int(settings.fontSize))pt") {
                    Slider(value: $settings.fontSize, in: 12, in: 28, step: 1)
                        .tint(.tint)
                }

                Section("行距：\(Int(settings.lineSpacing))pt") {
                    Slider(value: $settings.lineSpacing, in: 0, in: 24, step: 1)
                        .tint(.tint)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showSettings = false }
                }
            }
        }
    }

    // MARK: - 章节切换

    private func switchTo(index: Int) {
        currentIndex = index
        if let text = chapters[index].text {
            displayText = text
            return
        }
        // 网络章节：按需抓取正文
        Task {
            let text = await fetchContentText(for: index)
            await MainActor.run { displayText = text }
        }
    }

    // MARK: - 加载入口

    private func load() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result: [ReaderChapter]
                if book.supportsRuleReading {
                    result = try await fetchRuleChapters()
                } else if let url = bookStore.fileURL(for: book) {
                    result = try await fetchLocalChapters(at: url)
                } else {
                    throw RuleError.emptyResult
                }
                await MainActor.run {
                    chapters = result
                    currentIndex = 0
                    displayText = result.first?.text ?? ""
                    isLoading = false
                }
                // 网络章节需单独抓取正文
                if book.supportsRuleReading, let first = result.first, first.text == nil {
                    let text = await fetchContentText(for: 0)
                    await MainActor.run { displayText = text }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    // MARK: - 本地阅读器

    /// 本地书籍章节提取（纯函数，不修改 @State）
    private func fetchLocalChapters(at url: URL) async throws -> [ReaderChapter] {
        if book.format == .epub {
            let eps = try EPUBReader.shared.chapters(from: url)
            return eps.map { ReaderChapter(title: $0.title, text: $0.text, url: nil) }
        }
        let data = try Data(contentsOf: url)
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: gb))
        let chapters = splitIntoChapters(text)
        return chapters.isEmpty ? [ReaderChapter(title: book.displayTitle, text: "", url: nil)] : chapters
    }

    /// 按中文章节标题切分（第…章 / 第…回 / 序言 等）
    private func splitIntoChapters(_ text: String?) -> [ReaderChapter] {
        guard let text, !text.isEmpty else {
            return [ReaderChapter(title: book.displayTitle, text: "", url: nil)]
        }
        let pattern = #"[\n\r]*第[0-9一二三四五六七八九十百千万两]+[章回节卷][^\n\r]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [ReaderChapter(title: book.displayTitle, text: text, url: nil)]
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count > 1 else {
            return [ReaderChapter(title: book.displayTitle, text: text, url: nil)]
        }
        var result: [ReaderChapter] = []
        // 开头正文（第一章之前的内容）
        let firstRange = matches[0].range
        if firstRange.location > 0 {
            let prefix = ns.substring(with: NSRange(location: 0, length: firstRange.location))
            if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(ReaderChapter(title: "序言", text: prefix, url: nil))
            }
        }
        for (i, match) in matches.enumerated() {
            let start = match.range.location
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let title = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ReaderChapter(title: title.isEmpty ? "第\(i + 1)章" : title, text: body, url: nil))
        }
        return result
    }

    // MARK: - 规则阅读器

    /// 用书源 ruleToc 抓取目录（纯函数，不修改 @State）
    private func fetchRuleChapters() async throws -> [ReaderChapter] {
        guard let source = sourceStore.sources.first(where: { $0.bookSourceUrl == book.sourceId }),
              let rules = source.ruleToc, !rules.isEmpty else {
            throw RuleError.unsupportedMode("书源缺少目录规则")
        }
        guard let bookURL = URL(string: book.bookUrl) else {
            throw RuleError.unsupportedMode("书籍 URL 无效")
        }
        let html = try await NetworkService.shared.fetchText(from: bookURL)
        let extracted = try extractToc(html: html, rules: rules, base: bookURL)
        if extracted.isEmpty { throw RuleError.emptyResult }
        return extracted
    }

    /// 抓取指定章节正文（网络章节），返回文本字符串
    private func fetchContentText(for index: Int) async -> String {
        let chapter = chapters[index]
        if let text = chapter.text, !text.isEmpty { return text }
        guard let url = chapter.url, let u = URL(string: url) else { return chapter.text ?? "" }
        do {
            guard let source = sourceStore.sources.first(where: { $0.bookSourceUrl == book.sourceId }) else {
                return "书源不存在"
            }
            let html = try await NetworkService.shared.fetchText(from: u)
            let engine = RuleEngine()
            let contentRule = source.ruleContent?.content ?? ""
            let text = try engine.getString(contentRule, content: html)
            // 缓存到章节，便于离线回看
            await MainActor.run { chapters[index].text = text }
            return text
        } catch {
            return "加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 目录提取

    /// 从目录页 HTML 按规则提取章节列表。
    /// 优先 legado 的 per-element 模式：chapterList 选择容器，chapterName / chapterUrl 逐元素求值；
    /// 不支持时回退到整页规则 + 按索引压缩。
    private func extractToc(html: String, rules: SourceRuleSet, base: URL) throws -> [ReaderChapter] {
        let listRule = rules.chapterList ?? ""
        let nameRule = rules.chapterName ?? ""
        let urlRule = rules.chapterUrl ?? ""

        // per-element 模式（仅 CSS 选择器可直接取元素节点）
        if listRule.hasPrefix("@css:") || listRule.hasPrefix("@@") {
            let selector = stripCssPrefix(listRule)
            let document = try SwiftSoup.parse(html)
            let elements = try document.select(selector)
            var result: [ReaderChapter] = []
            for element in elements {
                let name = extractValue(nameRule, on: element)
                let urlRel = extractValue(urlRule, on: element)
                guard !name.isEmpty else { continue }
                let resolved = resolveURL(urlRel, base: base)
                result.append(ReaderChapter(title: name, text: nil, url: resolved?.absoluteString))
            }
            if !result.isEmpty { return result }
        }

        // 回退：整页规则 + 按索引压缩
        let nameEngine = RuleEngine()
        let urlEngine = RuleEngine()
        let names = (try? nameEngine.getStringList(nameRule, content: html)) ?? []
        let urls = (try? urlEngine.getStringList(urlRule, content: html)) ?? []
        let count = min(names.count, urls.count)
        guard count > 0 else { return [] }
        var result: [ReaderChapter] = []
        for i in 0..<count {
            let resolved = resolveURL(urls[i], base: base)
            result.append(ReaderChapter(title: names[i], text: nil, url: resolved?.absoluteString))
        }
        return result
    }

    private func stripCssPrefix(_ rule: String) -> String {
        var body = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("@css:") {
            body = String(body.dropFirst(5))
        } else if body.hasPrefix("@@") {
            body = String(body.dropFirst(2))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 对单个元素求值规则（委托给 HtmlRuleEngine，支持裸抽取器与完整规则）
    private func extractValue(_ rule: String, on element: Element) -> String {
        HtmlRuleEngine.extractValue(rule, on: element)
    }

    private func resolveURL(_ relative: String, base: URL) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URL(string: relative), url.scheme != nil {
            return url
        }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }
}

// MARK: - 预览

struct BookReaderView_Previews: PreviewProvider {
    static var previews: some View {
        BookReaderView(book: Book(
            id: "1",
            title: "示例书",
            author: "作者",
            format: .txt,
            fileRelativePath: nil,
            remoteURL: nil,
            addedAt: Date()
        ))
            .environmentObject(BookSourceStore())
            .environmentObject(BookStore())
            .environmentObject(ReaderSettings.shared)
    }
}