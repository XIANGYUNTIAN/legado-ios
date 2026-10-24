import SwiftUI
import SwiftSoup

// MARK: - 章节模型

/// 内容整体在滚动坐标系中的矩形（minY=滚动偏移负值，height=内容高），供预加载判定
struct ScrollContentKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// 视口高度（ScrollView 自身 frame），供底部预加载阈值计算
struct ScrollViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// iOS 18 滚动几何触发器。
///
/// PreferenceKey + GeometryReader 的滚动偏移跟踪在某些 SwiftUI 版本/场景下会失效
/// （坐标空间语义差异导致 minY 始终为 0），这正是「滑到底仍不换章」反复修复仍失败的根。
/// iOS 18 的 onScrollGeometryChange 是官方推荐的一等方案，这里作为主触发；
/// iOS 17 仍由 PreferenceKey 路径兜底（evaluatePreload 会回退到 contentRect）。
private struct ScrollGeometryTriggerModifier: ViewModifier {
    let proxy: ScrollViewProxy
    @Binding var lastScrollGeo: (Double, Double, Double)
    let evaluate: @MainActor (ScrollViewProxy) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                // 跟踪 (visibleRect.minY, visibleRect.maxY, contentSize.height)：
                // - 滚动时 visibleRect 变化 → 触发滑到底/回顶；
                // - 内容增长（追加短章）时 contentSize.height 变化 → 触发连续填充。
                // 三元组比 Bool 更稳：返回 Bool 时 action 只在翻转时触发一次，
                // 短章填不满一屏时会卡在 true 不再触发。
                .onScrollGeometryChange(for: (Double, Double, Double).self) { geo in
                    (geo.visibleRect.minY, geo.visibleRect.maxY, geo.contentSize.height)
                } action: { _, newValue in
                    lastScrollGeo = newValue
                    evaluate(proxy)
                }
        } else {
            content
        }
    }
}

struct ReaderChapter: Identifiable {
    let id = UUID()
    let title: String
    var text: String?      // 本地章节正文（网络章节为 nil，按需抓取）
    var url: String?       // 网络章节 URL
}

/// 数组安全下标：切章 / 异步回调里索引可能越界，避免崩溃
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - 阅读器主视图

/// 三种阅读模式统一入口：
/// - 本地 TXT：直接读文件、按章节标题切分
/// - 本地 EPUB：经 EPUBReader 抽取章节正文
/// - 规则阅读：用书源 ruleToc / ruleContent 抓取目录与正文（CSS / XPath）
///
/// 连续阅读：正文按「已加载章节段」渲染，滚动到底部自动衔接下一章、
/// 滚动到顶部自动衔接上一章（插入后保持视口），无需手动点章节按钮。
struct BookReaderView: View {
    let book: Book

    @EnvironmentObject private var sourceStore: BookSourceStore
    @EnvironmentObject private var bookStore: BookStore
    @EnvironmentObject private var settings: ReaderSettings

    @State private var chapters: [ReaderChapter] = []
    /// 已连续加载的章节段（首尾由 firstLoadedIndex / lastLoadedIndex 定位）
    @State private var segments: [ReaderChapter] = []
    @State private var firstLoadedIndex = 0
    @State private var lastLoadedIndex = 0
    @State private var currentIndex = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var showChapterList = false
    @State private var showSettings = false
    @State private var didLoad = false
    /// 显式切章时 +1，触发滚动到顶部（章节追加/前插不触发，避免打断阅读）
    @State private var scrollToTopTrigger = 0
    /// 哨兵武装：切章后短暂关闭，防止刚切到新章就自动衔接邻章
    @State private var sentinelsArmed = false
    /// 顶部预加载门控：曾向下滚动超过该阈值（pt）才允许回顶时预加载上一章，
    /// 排除初始态与刚切章时的误触发
    @State private var furthestTopOffset: CGFloat = 0
    /// 前插后抑制顶部预加载，直到用户再次向下滚动超过阈值（防前插过渡帧误触发）
    @State private var suppressTopSentinel = false
    /// 视口高度（由 ScrollView 背景几何测量，供底部预加载阈值使用）
    @State private var viewportHeight: CGFloat = 0
    /// 最近一次测得的内容整体矩形（minY 反映滚动偏移、height 即内容高）。
    /// 单独存下来是为了：哨兵「武装」晚于首帧布局时，仍能基于已有几何补做一次判定，
    /// 否则短章（内容不足一屏）在武装前就已完成布局，之后再无偏好变化可触发，永远不衔接下一章。
    @State private var contentRect: CGRect = .zero
    /// iOS 18 onScrollGeometryChange 测得的 (visibleRect.minY, visibleRect.maxY, contentSize.height)。
    /// 三元组在「滚动」与「内容增长」时都会变化，因此既能触发滑到底、也能触发短章连续填充。
    /// 为 (0,0,0) 时表示当前未启用（iOS 17 回退到 contentRect/viewportHeight）。
    @State private var lastScrollGeo: (Double, Double, Double) = (0, 0, 0)

    /// 连续加载的章节段上限，防止超长阅读会话内存无限增长
    private let maxSegments = 25

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
            .toolbar(.hidden, for: .tabBar)
            .onAppear {
                // 避免 sheet dismiss 等原因导致重复加载、进度被重置
                if !didLoad {
                    didLoad = true
                    load()
                }
            }
        }
    }

    // MARK: - 正文渲染（分段连续 + 滚动几何预加载）

    private var readerContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 1)
                        .id("topAnchor")

                    ForEach(Array(segments.enumerated()), id: \.element.id) { offset, segment in
                        let chapterIndex = firstLoadedIndex + offset
                        VStack(alignment: .leading, spacing: 0) {
                            if settings.showChapterHeader {
                                Text(segment.title)
                                    .font(.system(size: settings.fontSize, design: settings.fontFamily.design))
                                    .foregroundStyle(settings.theme.foreground)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, settings.lineSpacing * 2)
                            }
                            Text(segment.text?.isEmpty == false ? segment.text! : "（本章无内容）")
                                .font(.system(size: settings.fontSize, design: settings.fontFamily.design))
                                .lineSpacing(settings.lineSpacing)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(settings.theme.foreground)
                                .textSelection(.enabled)
                            // 本章末尾锚点：上一章前插后用于保持视口
                            Color.clear
                                .frame(height: 1)
                                .id("segEnd-\(chapterIndex)")
                        }
                        .id("segTop-\(chapterIndex)")
                    }

                    // 底部哨兵：仅作为内容末端标记与滚动余量。
                    // 注意：VStack 非惰性容器，onAppear 在首帧即触发（此时哨兵尚未武装、且只会触发一次），
                    // 因此不再依赖 onAppear 触发加载，统一由 evaluatePreload 的几何判定驱动。
                    Color.clear
                        .frame(height: 1)
                        .id("bottomSentinel")

                    if isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .padding(.horizontal, 20)
                // 测量内容整体在滚动坐标系中的矩形：minY 反映滚动偏移、height 即内容高。
                // 用 PreferenceKey 反馈（iOS 13+ 通用方案），规避 onScrollGeometryChange 的 iOS 18 限制，
                // 在内容动态增长（前后插章）时依然逐帧稳定，彻底解决“无缝换章”反复失效的问题。
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollContentKey.self,
                            value: geo.frame(in: .named("readerScroll"))
                        )
                    }
                )
            }
            .coordinateSpace(name: "readerScroll")
            // 测量视口高度（ScrollView 自身 frame），供底部预加载阈值计算
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollViewportKey.self, value: geo.size.height)
                }
            )
            .onPreferenceChange(ScrollViewportKey.self) { h in
                guard h > 0 else { return }
                viewportHeight = h
                // 视口高度常晚于内容首帧到达（首帧为 0）：补做一次判定，
                // 否则首屏就落在底部时无人触发。
                evaluatePreload(proxy: proxy)
            }
            .onPreferenceChange(ScrollContentKey.self) { rect in
                guard rect.height > 0 else { return }
                contentRect = rect
                // furthestTopOffset / suppressTopSentinel 的维护统一在 evaluatePreload
                // 内完成（同时覆盖 iOS 18 onScrollGeometryChange 与 iOS 17 PreferenceKey），
                // 此处仅传递几何数据。
                evaluatePreload(proxy: proxy)
            }
            // 哨兵武装完成的瞬间补做一次判定：
            // 短章/内容不足一屏时，武装前布局已结束、之后不再有偏好变化，
            // 必须在此主动衔接，否则表现为「滑到底也不换章」。
            .onChange(of: sentinelsArmed) { _, armed in
                if armed { evaluatePreload(proxy: proxy) }
            }
            .onChange(of: scrollToTopTrigger) { _, _ in
                withAnimation { proxy.scrollTo("topAnchor", anchor: .top) }
            }
            // iOS 18 主触发：onScrollGeometryChange（滚动与内容增长都会触发）。
            // iOS 17 由上方 onPreferenceChange 兜底。
            .modifier(ScrollGeometryTriggerModifier(
                proxy: proxy,
                lastScrollGeo: $lastScrollGeo,
                evaluate: { [self] proxy in self.evaluatePreload(proxy: proxy) }
            ))
        }
    }

    private var currentChapter: ReaderChapter? {
        chapters[safe: currentIndex]
    }

    // MARK: - 工具栏（上一章 / 下一章）

    private var readerToolbar: some View {
        HStack(spacing: 4) {
            Button {
                switchTo(index: currentIndex - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
            }
            .disabled(currentIndex <= 0)
            .foregroundStyle(settings.theme.foreground)

            Button {
                showChapterList = true
            } label: {
                Image(systemName: "list.bullet")
                Text(currentChapter?.title ?? "目录")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(settings.theme.foreground)

            Button {
                switchTo(index: currentIndex + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
            }
            .disabled(chapters.isEmpty || currentIndex >= chapters.count - 1)
            .foregroundStyle(settings.theme.foreground)

            Spacer(minLength: 8)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "a.circle")
                    .frame(width: 44, height: 44)
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
                    Slider(value: $settings.fontSize, in: 12...28, step: 1)
                        .tint(.accentColor)
                }

                Section("行距：\(Int(settings.lineSpacing))pt") {
                    Slider(value: $settings.lineSpacing, in: 0...24, step: 1)
                        .tint(.accentColor)
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

    // MARK: - 章节切换与连续加载

    /// 显式切章（目录 / 上下一章按钮）：重置为单段并回到顶部
    private func switchTo(index: Int) {
        guard chapters.indices.contains(index) else { return }
        let chapter = chapters[index]
        currentIndex = index
        firstLoadedIndex = index
        lastLoadedIndex = index
        if let text = chapter.text {
            segments = [ReaderChapter(title: chapter.title, text: text, url: chapter.url)]
            isLoadingMore = false
        } else {
            // 网络章节：先清空旧正文，按需抓取
            segments = []
            isLoadingMore = true
            Task {
                let text = await fetchContentText(for: index)
                await MainActor.run {
                    // 期间用户可能已切到其他章，丢弃过期结果
                    if currentIndex == index, lastLoadedIndex == index {
                        segments = [ReaderChapter(title: chapter.title, text: text, url: chapter.url)]
                    }
                    isLoadingMore = false
                }
            }
        }
        scrollToTopTrigger += 1
        // 显式切章后重置顶部哨兵的滚动历史与抑制，避免刚切章就误衔接邻章
        furthestTopOffset = 0
        suppressTopSentinel = false
        rearmSentinels()
        bookStore.updateProgress(bookID: book.id, chapterIndex: index)
    }

    /// 统一的预加载判定（唯一触发入口）。
    /// - 底部：距内容末端 200pt 内即衔接下一章；内容不足一屏（短章）时同样成立，
    ///   因此连续几个短章会被依次追加直至填满视口（追加后内容变高→再次判定）。
    /// - 顶部：需曾向下滚动 >200pt、未被前插抑制、且确实存在上一章。
    /// 之所以不再用「哨兵 onAppear」，是因为 VStack 会在首帧为所有子视图调用 onAppear，
    /// 那一刻哨兵尚未武装、且之后不再重复调用 —— 正是「滑到底仍不换章」的成因。
    /// 优先使用 iOS 18 的 onScrollGeometryChange 几何（滚动与内容增长都会触发），
    /// 回退到 iOS 17 的 PreferenceKey 几何。
    private func evaluatePreload(proxy: ScrollViewProxy) {
        guard sentinelsArmed, !isLoadingMore else { return }
        let nearBottom: Bool
        let nearTop: Bool
        // 滚动偏移量（距内容顶端的距离），两种几何路径各自换算后统一维护到
        // furthestTopOffset，使「曾向下滚动过」的判定不依赖任一特定触发源。
        let offset: CGFloat
        if lastScrollGeo != (0, 0, 0) {
            let (minY, maxY, contentH) = lastScrollGeo
            guard contentH > 0 else { return }
            // visibleRect 已含 safe area 内缩：maxY 即可视区域底边在内容坐标系中的位置，
            // minY 即顶边；scroll offset = -minY（minY 为负时表示已向下滚动）。
            offset = max(0, -minY)
            nearBottom = maxY >= contentH - 200
            nearTop = minY <= 200
        } else {
            guard contentRect.height > 0, viewportHeight > 0 else { return }
            offset = max(0, -contentRect.minY)
            nearBottom = offset + viewportHeight >= contentRect.height - 200
            nearTop = offset <= 200
        }
        // 向下滚动超过阈值后解除前插抑制，允许后续回顶预加载；
        // 此处统一维护，避免仅依赖 onPreferenceChange（iOS 18 上可能不可靠）。
        furthestTopOffset = max(furthestTopOffset, offset)
        if offset > 200 { suppressTopSentinel = false }
        if nearBottom, lastLoadedIndex + 1 < chapters.count, segments.count < maxSegments {
            // 首屏自动填充（用户尚未滚动过）只补正文、不推进书签，
            // 否则刚打开一个短章就会把进度悄悄改到后面几章。
            loadNextSegment(advanceProgress: furthestTopOffset > 1)
            return
        }
        if nearTop, firstLoadedIndex > 0,
           !suppressTopSentinel, furthestTopOffset > 200 {
            suppressTopSentinel = true
            loadPrevSegment(proxy: proxy)
        }
    }

    /// 滚动到底部：衔接下一章
    /// - Parameter advanceProgress: 是否把阅读进度推进到新章节（首屏填充时为 false）
    private func loadNextSegment(advanceProgress: Bool = true) {
        guard sentinelsArmed, !isLoadingMore else { return }
        let next = lastLoadedIndex + 1
        guard chapters.indices.contains(next), segments.count < maxSegments else { return }
        isLoadingMore = true
        let chapter = chapters[next]
        if let text = chapter.text {
            appendSegment(chapter: chapter, text: text, advanceProgress: advanceProgress)
            isLoadingMore = false
        } else {
            Task {
                let text = await fetchContentText(for: next)
                await MainActor.run {
                    // 期间用户可能已切章（segments 被重置），按首尾索引校验
                    if lastLoadedIndex == next - 1 {
                        appendSegment(chapter: chapter, text: text, advanceProgress: advanceProgress)
                    }
                    isLoadingMore = false
                }
            }
        }
    }

    /// 滚动到顶部：衔接上一章，插入后保持视口
    private func loadPrevSegment(proxy: ScrollViewProxy) {
        guard sentinelsArmed, !isLoadingMore else { return }
        let prev = firstLoadedIndex - 1
        guard chapters.indices.contains(prev), segments.count < maxSegments else { return }
        isLoadingMore = true
        let chapter = chapters[prev]
        if let text = chapter.text {
            finishPrepend(chapter: chapter, text: text, proxy: proxy)
            isLoadingMore = false
        } else {
            Task {
                let text = await fetchContentText(for: prev)
                await MainActor.run {
                    if firstLoadedIndex == prev + 1 {
                        finishPrepend(chapter: chapter, text: text, proxy: proxy)
                    }
                    isLoadingMore = false
                }
            }
        }
    }

    private func appendSegment(chapter: ReaderChapter, text: String, advanceProgress: Bool = true) {
        segments.append(ReaderChapter(title: chapter.title, text: text, url: chapter.url))
        lastLoadedIndex += 1
        guard advanceProgress else { return }
        currentIndex = lastLoadedIndex
        bookStore.updateProgress(bookID: book.id, chapterIndex: lastLoadedIndex)
    }

    private func finishPrepend(chapter: ReaderChapter, text: String, proxy: ScrollViewProxy) {
        segments.insert(ReaderChapter(title: chapter.title, text: text, url: chapter.url), at: 0)
        firstLoadedIndex -= 1
        currentIndex = firstLoadedIndex
        bookStore.updateProgress(bookID: book.id, chapterIndex: firstLoadedIndex)
        // 前插后内容顶端暂落在视口下方，抑制顶部预加载，直到用户再次向下
        // 滚动超过阈值后由 evaluatePreload 统一解除（覆盖 onScrollGeometryChange
        // 与 PreferenceKey 两条几何路径）。
        suppressTopSentinel = true
        // 视口保持：滚到新章节末尾，使原有阅读位置基本不变
        proxy.scrollTo("segEnd-\(firstLoadedIndex)", anchor: .bottom)
    }

    /// 切章后短暂解除哨兵武装，避免刚切到新章就自动衔接邻章。
    /// 武装完成时会由 onChange(of: sentinelsArmed) 补做一次几何判定，
    /// 因此这里可以把等待时间压到 250ms —— 既不误触发，又不会让用户滑到底后空等。
    private func rearmSentinels() {
        sentinelsArmed = false
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run { sentinelsArmed = true }
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
                // 恢复上次阅读进度（越界时回退到首章）
                let savedIndex = min(max(book.lastChapterIndex, 0), max(result.count - 1, 0))
                let restored = result[safe: savedIndex]
                await MainActor.run {
                    chapters = result
                    currentIndex = savedIndex
                    firstLoadedIndex = savedIndex
                    lastLoadedIndex = savedIndex
                    if let restored, let text = restored.text {
                        segments = [ReaderChapter(title: restored.title, text: text, url: restored.url)]
                        isLoadingMore = false
                    } else {
                        segments = []
                        isLoadingMore = true
                    }
                    isLoading = false
                    scrollToTopTrigger += 1
                    furthestTopOffset = 0
                    suppressTopSentinel = false
                    rearmSentinels()
                }
                // 网络章节需单独抓取正文
                if book.supportsRuleReading, restored?.text == nil {
                    let text = await fetchContentText(for: savedIndex)
                    await MainActor.run {
                        if currentIndex == savedIndex, lastLoadedIndex == savedIndex {
                            segments = [ReaderChapter(title: restored?.title ?? "", text: text, url: restored?.url)]
                        }
                        isLoadingMore = false
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

    // MARK: - 本地阅读器

    /// 本地书籍章节提取（纯函数，不修改 @State）
    private func fetchLocalChapters(at url: URL) async throws -> [ReaderChapter] {
        if book.format == .epub {
            let eps = try EPUBReader.shared.chapters(from: url)
            return eps.enumerated().map { _, chapter in
                ReaderChapter(title: chapter.title, text: chapter.text, url: nil)
            }
        }
        let data = try Data(contentsOf: url)
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: gb))
        return splitIntoChapters(text)
    }

    /// 按中文章节标题切分。
    /// 标题需位于行首（允许前导空格/制表符），覆盖：第X章/回/节/卷/集/部/篇、
    /// 序章/序言/楔子/番外、Chapter N 等常见格式；匹配不到时按固定字数兜底分段，
    /// 保证超长单章也能连续翻页。
    private func splitIntoChapters(_ rawText: String?) -> [ReaderChapter] {
        guard let rawText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [ReaderChapter(title: book.displayTitle, text: "", url: nil)]
        }
        // 归一化：去 BOM、CRLF / CR → LF
        var text = rawText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")

        let pattern = #"(?m)^[ \t]*(?:第[0-9０-９零一二三四五六七八九十百千万两]+\s*[章回节卷集部篇][^\n]*|序[章幕言折][^\n]*|楔子[^\n]*|番外[篇卷]?[0-9零一二三四五六七八九十百千万]*[^\n]*|Chapter\s*[0-9]+[^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return fallbackSegments(text)
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count > 1 else {
            // 无章节结构：超长文本按固定字数兜底分段，保证可翻页
            return fallbackSegments(text)
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
            guard end > start else { continue }
            let body = ns.substring(with: NSRange(location: start, length: end - start))
            let title = ns.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ReaderChapter(title: title.isEmpty ? "第\(i + 1)章" : title, text: body, url: nil))
        }
        return result
    }

    /// 无章节标记时的兜底：按 ~8000 字分段（尽量在换行处断开），标题为「第 N 段」
    private func fallbackSegments(_ text: String) -> [ReaderChapter] {
        let threshold = 8000
        guard text.count > threshold else {
            return [ReaderChapter(title: book.displayTitle, text: text, url: nil)]
        }
        var result: [ReaderChapter] = []
        var start = text.startIndex
        var seg = 1
        while start < text.endIndex {
            let hardEnd = text.index(start, offsetBy: threshold, limitedBy: text.endIndex) ?? text.endIndex
            var cut = hardEnd
            if cut < text.endIndex, let nl = text[start..<hardEnd].lastIndex(of: "\n") {
                cut = text.index(after: nl)
            }
            let body = String(text[start..<cut])
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(ReaderChapter(title: "第 \(seg) 段", text: body, url: nil))
                seg += 1
            }
            start = cut
        }
        return result.isEmpty ? [ReaderChapter(title: book.displayTitle, text: text, url: nil)] : result
    }

    // MARK: - 规则阅读器

    /// 用书源 ruleToc 抓取目录（纯函数，不修改 @State）
    private func fetchRuleChapters() async throws -> [ReaderChapter] {
        guard let source = sourceStore.sources.first(where: { $0.bookSourceUrl == book.sourceId }),
              let rules = source.ruleToc, !rules.isEmpty else {
            throw RuleError.unsupportedMode("书源缺少目录规则")
        }
        guard let bookUrlStr = book.bookUrl, let bookURL = URLSanitizer.sanitize(bookUrlStr) else {
            throw RuleError.unsupportedMode("书籍 URL 无效")
        }
        let html = try await NetworkService.shared.fetchText(from: bookURL)
        let extracted = try extractToc(html: html, rules: rules, base: bookURL)
        if extracted.isEmpty { throw RuleError.emptyResult }
        return extracted
    }

    /// 抓取指定章节正文（网络章节），返回文本字符串
    private func fetchContentText(for index: Int) async -> String {
        guard chapters.indices.contains(index) else { return "" }
        let chapter = chapters[index]
        if let text = chapter.text, !text.isEmpty { return text }
        guard let url = chapter.url, let u = URLSanitizer.sanitize(url) else {
            return chapter.text ?? ""
        }
        do {
            guard let source = sourceStore.sources.first(where: { $0.bookSourceUrl == book.sourceId }) else {
                return "书源不存在或已删除"
            }
            let html = try await NetworkService.shared.fetchText(from: u)
            let engine = RuleEngine()
            let contentRule = source.ruleContent?.content ?? ""
            let text = (try? engine.getString(contentRule, content: html)) ?? ""
            let finalText = text.isEmpty ? "（本章无内容）" : text
            // 缓存到章节，便于离线回看
            await MainActor.run {
                if chapters.indices.contains(index) {
                    chapters[index].text = finalText
                }
            }
            return finalText
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
        if let url = URLSanitizer.sanitize(relative) { return url }
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
