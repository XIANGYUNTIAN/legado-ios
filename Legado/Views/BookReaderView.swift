import SwiftUI
import UIKit
#if canImport(PDFKit)
import PDFKit
#endif

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

/// iOS 18 滚动几何快照（显式 Equatable，避免元组在 onScrollGeometryChange
/// 的 Equatable 约束下编译失败）。
private struct ScrollGeometryValue: Equatable {
    let minY: Double
    let maxY: Double
    let contentHeight: Double

    static let zero = ScrollGeometryValue(minY: 0, maxY: 0, contentHeight: 0)
}

/// iOS 18 滚动几何触发器。
///
/// PreferenceKey + GeometryReader 的滚动偏移跟踪在某些 SwiftUI 版本/场景下会失效
/// （坐标空间语义差异导致 minY 始终为 0），这正是「滑到底仍不换章」反复修复仍失败的根。
/// iOS 18 的 onScrollGeometryChange 是官方推荐的一等方案，这里作为主触发；
/// iOS 17 仍由 PreferenceKey 路径兜底（evaluatePreload 会回退到 contentRect）。
private struct ScrollGeometryTriggerModifier: ViewModifier {
    let proxy: ScrollViewProxy
    @Binding var lastScrollGeo: ScrollGeometryValue
    let evaluate: @MainActor (ScrollViewProxy) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                // 跟踪 (visibleRect.minY, visibleRect.maxY, contentSize.height)：
                // - 滚动时 visibleRect 变化 → 触发滑到底/回顶；
                // - 内容增长（追加短章）时 contentSize.height 变化 → 触发连续填充。
                // 用结构体而非 Bool：返回 Bool 时 action 只在翻转时触发一次，
                // 短章填不满一屏时会卡在 true 不再触发。
                .onScrollGeometryChange(for: ScrollGeometryValue.self) { geo in
                    ScrollGeometryValue(
                        minY: geo.visibleRect.minY,
                        maxY: geo.visibleRect.maxY,
                        contentHeight: geo.contentSize.height
                    )
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
    var isVolume: Bool = false  // 是否为卷标题（ruleToc.isVolume）
    var image: UIImage? = nil      // 扫描版 PDF 页渲染图（无文本页用图片展示）
    var isImagePage: Bool = false  // 是否需以图片展示（扫描 / 矢量页，page.string 为空）
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
    @State private var lastScrollGeo: ScrollGeometryValue = .zero

    // MARK: - 翻页（左右翻页模式）

    /// 页级分页器（Core Text 按屏分页）：跨设置变化共享缓存，随设置/尺寸实时重排
    @State private var paginator = ChapterPaginator()
    /// 网络章正文缓存（chapterIndex → text）。分页与页面渲染以此为准；
    /// 本地章正文仍走 chapters[].text。文本到达后写入，驱动 PagedReaderView 重排定位。
    @State private var chapterTexts: [Int: String] = [:]
    /// 沉浸模式下的控制层显隐（单击中央切换）。注意：这是运行时状态，非持久化设置。
    @State private var immersiveChromeVisible = false
    /// 排版重排令牌：任一阅读设置变化时自增，驱动 PagedReaderView 强制重排
    /// （改字号/字距/行距/背景/日夜间 → 当前页立即重新分页，不再「仅往后翻页才生效」）。
    @State private var reflowToken = 0
    /// 首次进入分页模式时的章内字符偏移（恢复退出前页面；nil → 章首页）
    @State private var restorePageOffset: Int? = nil
    /// 最近一次翻页完成时的章内页偏移，用于退出时保存页位置
    @State private var lastPageOffset: Int = 0

    // MARK: - 下载（在线 TXT 导出）

    @State private var showDownload = false
    @State private var showDownloadShare = false
    @State private var downloadURL: URL? = nil
    @State private var downloadProgress: (done: Int, total: Int) = (0, 0)
    @State private var isDownloading = false
    @State private var downloadMessage: String? = nil
    @State private var dlStart: Int = 0
    @State private var dlEnd: Int = 0
    @State private var dlAll: Bool = true

    /// 扫描版 PDF：整本文档句柄（仅 PDF 书籍在加载时打开一次），用于惰性渲染扫描页为图片。
    #if canImport(PDFKit)
    @State private var pdfDocument: PDFDocument? = nil
    #endif
    /// 扫描页渲染结果缓存：key = 章节下标（= PDF 页下标），随已加载窗口裁剪，控制内存。
    @State private var pageImages: [Int: UIImage] = [:]

    /// 连续加载的章节段上限，防止超长阅读会话内存无限增长
    private let maxSegments = 25

    /// 排版相关设置指纹：任一排版/背景设置变化 → 指纹变化 → 触发 PagedReaderView 重建（实时联动）。
    /// 仅纳入影响版面布局的设置，排除翻页模式/动画/沉浸（不重排，避免无谓重建）。
    private var layoutFingerprint: String {
        "\(settings.fontFamily.rawValue)|\(settings.customFontName)|\(settings.fontSize)|\(settings.letterSpacing)|\(settings.lineSpacing)|\(settings.justified)|\(settings.theme.rawValue)|\(settings.isNight)|\(settings.showChapterHeader)"
    }

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
                    // 正文区：按翻页模式渲染。沉浸模式下用 GeometryReader 包裹以获取尺寸，
                    // 通过 SpatialTapGesture 识别「单击中央」切换控制层显隐（沉浸式交互）。
                    GeometryReader { geo in
                        readerContent
                            .simultaneousGesture(
                                SpatialTapGesture().onEnded { value in
                                    // 页面模式（PagedReaderView）的中央切换由原生 UITapGestureRecognizer 处理，
                                    // 因为 SwiftUI 手势会被 UIPageViewController 的 pan/卷页手势吞掉；
                                    // 滚动模式下才由这里的 SpatialTapGesture 处理。
                                    guard settings.isImmersive, settings.pageMode == .scroll else { return }
                                    let size = geo.size
                                    if abs(value.location.x - size.width / 2) < size.width / 6 &&
                                       abs(value.location.y - size.height / 2) < size.height / 3 {
                                        immersiveChromeVisible.toggle()
                                    }
                                }
                            )
                    }
                }
            }
            .background(settings.effectiveBackground)
            .safeAreaInset(edge: .bottom) {
                // 设置面板打开时以底部 inset 承载（正文自动上移，面板不遮挡正文 → live preview 可见）；
                // 否则显示阅读工具栏（沉浸时按 chrome 显隐）。
                if showSettings {
                    ReaderSettingsPanel(settings: settings, onClose: { showSettings = false })
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                } else if chromeVisible {
                    readerToolbar
                }
            }
            .sheet(isPresented: $showChapterList) { chapterListSheet }
            .sheet(isPresented: $showDownload) { downloadSheet }
            .sheet(isPresented: $showDownloadShare) {
                if let url = downloadURL {
                    ShareSheet(items: [url])
                }
            }
            .navigationTitle(currentChapter?.title ?? book.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
            .statusBarHidden(!chromeVisible)
            // 排版设置变化（字号/字距/行距/背景/日夜间/字体等）→ 记录当前页字符 offset →
            // 自增重排令牌。令牌驱动 PagedReaderView 的 .id() **全量重建**（等价于「退出返回」的
            // 全新 makeUIViewController），确保在当前页**立即**生效。
            // 注：用 onChange(排版指纹) 而非 onReceive(objectWillChange) —— 后者在属性**改前**触发，
            // 且对非排版设置（翻页模式/动画/沉浸）也误触发重建，故排除。
            .onChange(of: layoutFingerprint) { _, _ in
                if settings.pageMode == .page {
                    restorePageOffset = lastPageOffset
                }
                reflowToken += 1
            }
            .onAppear {
                // 避免 sheet dismiss 等原因导致重复加载、进度被重置
                if !didLoad {
                    didLoad = true
                    load()
                }
            }
            .onDisappear {
                saveCurrentPagePosition()
            }
            .onChange(of: settings.pageMode) { _, mode in
                if mode == .page {
                    // 进入分页模式：恢复退出前页位置（章内字符偏移），并预取当前章正文避免空白。
                    restorePageOffset = PagePositionStore.shared.offset(bookId: book.id, chapter: currentIndex)
                    // 同步 lastPageOffset：PagedReaderView 重建（排版设置变化）时以此定位当前页
                    lastPageOffset = restorePageOffset ?? 0
                    let idx = currentIndex
                    if chapters.indices.contains(idx), chapters[idx].text == nil, !chapters[idx].isImagePage {
                        Task { _ = await ensureChapterText(idx) }
                    }
                } else {
                    // 切回滚动模式：以当前章节重建滚动窗口，避免 segments 过时
                    switchTo(index: currentIndex)
                }
            }
        }
    }

    // MARK: - 正文渲染（分段连续 + 滚动几何预加载）

    /// 阅读正文容器：按翻页模式在「连续滚动」与「左右翻页」之间切换。
    ///
    /// 注意：不再用 AnyView 擦除两个分支——两分支同为 AnyView 时 SwiftUI 无法区分，
    /// 会保留旧子树（表现为「选了左右翻页仍是滚动」）。改为 @ViewBuilder 直接返回
    /// 具体视图类型，切换即生效。分页分支用 UIPageViewController（真卷页/滑动）。
    @ViewBuilder
    private var readerContent: some View {
        if settings.pageMode == .page {
            PagedReaderView(
                settings: settings,
                chapters: chapters,
                texts: chapterTexts,
                selection: $currentIndex,
                paginator: paginator,
                // 进入分页模式时 makeUIViewController 可能早于 onChange 执行，
                // 故把页 offset 读取内联兜底（restorePageOffset 为 nil 时从存储实时查）
                initialPageOffset: restorePageOffset ?? PagePositionStore.shared.offset(bookId: book.id, chapter: currentIndex),
                onNeedsText: { idx in await ensureChapterText(idx) },
                onPageChange: { chapterIdx, pageIdx, offset in
                    handlePagedPageChange(chapterIdx, pageIdx, offset)
                },
                pageImage: { gi in
                    // 扫描页：直接渲染为图片视图（hosted 分页视图无法感知 pageImages 变化，
                    // 故不走 pageImageView 的异步补渲染，改为同步 renderPageImage）
                    #if canImport(PDFKit)
                    if let img = renderPageImage(for: gi) {
                        return AnyView(Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity))
                    }
                    #endif
                    return AnyView(
                        Text("（本页为扫描图片，无法渲染）")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    )
                },
                // 设置变化 → 强制重排（改字号/字距/行距/背景/日夜间当前页立即重排）
                reflowToken: reflowToken,
                // 沉浸「单击中央」：页面模式下由原生 tap 手势触发
                onImmersiveTap: { immersiveChromeVisible.toggle() }
            )
            // UIPageViewController 的 transitionStyle 仅在 init 时生效：
            // 排版设置变化（reflowToken）或动画切换（pageAnimation）时以 .id 强制重建。
            // 关键：排版设置变化必须走**全量重建**（等价于「退出返回」的全新 makeUIViewController），
            // 而非依赖 updateUIViewController 的重排时序——后者在设置面板打开时并不可靠，
            // 表现为「改字号/字距/行距/背景/日夜间在当前页不实时联动，仅退出返回才变」。
            .id("\(reflowToken)|\(settings.pageAnimation)")
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
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
                                    .font(settings.textFont)
                                    .tracking(CGFloat(settings.letterSpacing))
                                    .foregroundStyle(settings.effectiveForeground)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, settings.lineSpacing * 2)
                            }
                            if segment.isImagePage {
                                pageImageView(chapterIndex: chapterIndex)
                            } else {
                                Text(segment.text?.isEmpty == false ? segment.text! : "（本章无内容）")
                                    .font(settings.textFont)
                                    .tracking(CGFloat(settings.letterSpacing))
                                    .lineSpacing(settings.lineSpacing)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(settings.effectiveForeground)
                                    .textSelection(.enabled)
                            }
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

    // MARK: - 左右翻页模式（UIPageViewController：真卷页 / 滑动 / 无动画）

    /// 翻页完成回调：同步进度、保存页位置（章 + 字符偏移），并预取相邻章节正文，避免翻页空白。
    @MainActor
    private func handlePagedPageChange(_ chapterIdx: Int, _ pageIdx: Int, _ offset: Int) {
        guard chapters.indices.contains(chapterIdx) else { return }
        currentIndex = chapterIdx
        lastPageOffset = offset
        bookStore.updateProgress(bookID: book.id, chapterIndex: chapterIdx)
        // 页位置持久化：下次进入回到退出前页面
        PagePositionStore.shared.save(bookId: book.id, chapter: chapterIdx, offset: offset)
        // 预取相邻两章正文（缓存命中即跳过，仅在缺失时抓取）
        for j in [chapterIdx - 1, chapterIdx + 1] where chapters.indices.contains(j) {
            let ch = chapters[j]
            if ch.text == nil, !ch.isImagePage, chapterTexts[j] == nil {
                Task { _ = await ensureChapterText(j) }
            }
        }
    }

    /// 确保指定全局章节已取到正文（缓存优先，否则抓取），返回正文文本。
    /// 结果统一写入 chapterTexts，供 PagedReaderView 分页与页面渲染取用。
    @MainActor
    private func ensureChapterText(_ globalIndex: Int) async -> String {
        guard chapters.indices.contains(globalIndex) else { return "" }
        let chapter = chapters[globalIndex]
        if let text = chapter.text, !text.isEmpty {
            if chapterTexts[globalIndex] != text { chapterTexts[globalIndex] = text }
            return text
        }
        guard chapter.isImagePage == false else { return "" }
        let text = await fetchContentText(for: globalIndex)
        if !text.isEmpty { chapterTexts[globalIndex] = text }
        return text
    }

    private var currentChapter: ReaderChapter? {
        chapters[safe: currentIndex]
    }

    /// 控制层（导航栏 / 状态栏 / 底部工具栏）是否可见：
    /// 非沉浸恒可见；沉浸时由「单击中央」切换（immersiveChromeVisible）。
    private var chromeVisible: Bool {
        !settings.isImmersive || immersiveChromeVisible
    }

    /// 退出阅读时保存页位置（章 + 当前页字符偏移），下次进入恢复到退出前页面
    @MainActor
    private func saveCurrentPagePosition() {
        PagePositionStore.shared.save(bookId: book.id, chapter: currentIndex, offset: lastPageOffset)
    }

    // MARK: - 工具栏（上一章 / 下一章）

    private var readerToolbar: some View {
        HStack(spacing: 4) {
            Button {
                if settings.pageMode == .page { goToChapter(currentIndex - 1) }
                else { switchTo(index: currentIndex - 1) }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
            }
            .disabled(currentIndex <= 0)
            .foregroundStyle(settings.effectiveForeground)

            Button {
                showChapterList = true
            } label: {
                Image(systemName: "list.bullet")
                Text(currentChapter?.title ?? "目录")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(settings.effectiveForeground)

            Button {
                if settings.pageMode == .page { goToChapter(currentIndex + 1) }
                else { switchTo(index: currentIndex + 1) }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
            }
            .disabled(chapters.isEmpty || currentIndex >= chapters.count - 1)
            .foregroundStyle(settings.effectiveForeground)

            Spacer(minLength: 8)

            Button {
                // 沉浸式开关：进入沉浸默认全屏干净；退出沉浸恢复控制层可见
                settings.isImmersive.toggle()
                settings.save()
                immersiveChromeVisible = false
            } label: {
                Image(systemName: settings.isImmersive ? "rectangle.inset.filled" : "rectangle")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(settings.effectiveForeground)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "a.circle")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(settings.effectiveForeground)

            Button {
                showDownload = true
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(settings.effectiveForeground)
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
                    goToChapter(index)
                    showChapterList = false
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundStyle(currentIndex == index ? settings.effectiveForeground : .primary)
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

    // 阅读设置现由同层级浮层 ReaderSettingsPanel 呈现（见 body 的 ZStack 分支），
    // 可在阅读界面实时预览效果；原 Form sheet 已移除。

    // MARK: - 下载（在线 TXT 导出）

    private var downloadSheet: some View {
        NavigationStack {
            Form {
                Section("下载范围") {
                    Toggle("全本下载", isOn: $dlAll)
                    if !dlAll {
                        Stepper(value: $dlStart, in: 0...(max(dlEnd, 0))) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("起始章：第 \(dlStart + 1) 章")
                                    .font(.subheadline)
                                Text(chapters[safe: dlStart]?.title ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Stepper(value: $dlEnd, in: dlStart...(max(chapters.count - 1, 0))) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("结束章：第 \(dlEnd + 1) 章")
                                    .font(.subheadline)
                                Text(chapters[safe: dlEnd]?.title ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Section("说明") {
                    Text("共 \(chapters.count) 章。本地书籍直接合并缓存文本；在线书籍将逐章抓取正文后合并为 TXT。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isDownloading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("已下载 \(downloadProgress.done) / \(downloadProgress.total)")
                        }
                    }
                }

                Section {
                    Button {
                        let s = dlAll ? 0 : dlStart
                        let e = dlAll ? max(chapters.count - 1, 0) : dlEnd
                        startDownload(start: s, end: e)
                    } label: {
                        Text(isDownloading ? "下载中…" : "开始下载 TXT")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(chapters.isEmpty || isDownloading)
                }
            }
            .navigationTitle("下载 TXT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { showDownload = false }
                }
            }
            .onAppear {
                dlStart = 0
                dlEnd = max(chapters.count - 1, 0)
                dlAll = true
            }
        }
    }

    /// 按章节范围合并导出 TXT（本地书走缓存文本、在线书逐章抓取），完成后调起分享面板
    private func startDownload(start: Int, end: Int) {
        guard chapters.indices.contains(start), chapters.indices.contains(end), start <= end else { return }
        isDownloading = true
        downloadProgress = (0, end - start + 1)
        Task {
            var collected: [ReaderChapter] = []
            for i in start...end {
                let ch = chapters[i]
                let text = await ensureChapterText(i)
                await MainActor.run {
                    collected.append(ReaderChapter(title: ch.title, text: text, url: ch.url, isImagePage: ch.isImagePage))
                    downloadProgress.done += 1
                }
            }
            let text = BookExporter.compose(title: book.displayTitle, author: book.author, chapters: collected)
            let tmp = BookExporter.writeTxtFile(named: book.title, text: text)
            await MainActor.run {
                downloadURL = tmp
                isDownloading = false
                showDownload = false
                showDownloadShare = true
            }
        }
    }

    // MARK: - 章节切换与连续加载

    /// 统一跳章入口：滚动模式走 switchTo；左右翻页模式仅更新 currentIndex，
    /// PagedReaderView 经 selection 绑定自动定位到目标页并预取正文。
    private func goToChapter(_ index: Int) {
        guard chapters.indices.contains(index) else { return }
        if settings.pageMode == .page {
            currentIndex = index
            bookStore.updateProgress(bookID: book.id, chapterIndex: index)
            let ch = chapters[index]
            if ch.text == nil, !ch.isImagePage, chapterTexts[index] == nil {
                Task { _ = await ensureChapterText(index) }
            }
        } else {
            switchTo(index: index)
        }
    }

    /// 显式切章（目录 / 上下一章按钮）：重置为单段并回到顶部
    private func switchTo(index: Int) {
        guard chapters.indices.contains(index) else { return }
        let chapter = chapters[index]
        currentIndex = index
        firstLoadedIndex = index
        lastLoadedIndex = index
        if let text = chapter.text {
            segments = [ReaderChapter(title: chapter.title, text: text, url: chapter.url, isImagePage: chapter.isImagePage)]
            isLoadingMore = false
        } else if chapter.isImagePage {
            // 本地扫描 / 矢量页：图片由正文区按需渲染，不抓取文本
            segments = [ReaderChapter(title: chapter.title, text: nil, url: chapter.url, isImagePage: true)]
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
        if lastScrollGeo != .zero {
            guard lastScrollGeo.contentHeight > 0 else { return }
            // visibleRect 已含 safe area 内缩：maxY 即可视区域底边在内容坐标系中的位置，
            // minY 即顶边；scroll offset = -minY（minY 为负时表示已向下滚动）。
            offset = max(0, -lastScrollGeo.minY)
            nearBottom = lastScrollGeo.maxY >= lastScrollGeo.contentHeight - 200
            nearTop = lastScrollGeo.minY <= 200
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
        if chapter.isImagePage {
            // 扫描 / 矢量页：图片由正文区按需渲染，不抓取文本
            appendSegment(chapter: chapter, text: nil, advanceProgress: advanceProgress)
            isLoadingMore = false
            return
        }
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
        if chapter.isImagePage {
            // 扫描 / 矢量页：图片由正文区按需渲染，不抓取文本
            finishPrepend(chapter: chapter, text: nil, proxy: proxy)
            isLoadingMore = false
            return
        }
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

    private func appendSegment(chapter: ReaderChapter, text: String?, advanceProgress: Bool = true) {
        segments.append(ReaderChapter(title: chapter.title, text: text, url: chapter.url, image: nil, isImagePage: chapter.isImagePage))
        lastLoadedIndex += 1
        trimPageCache()
        guard advanceProgress else { return }
        currentIndex = lastLoadedIndex
        bookStore.updateProgress(bookID: book.id, chapterIndex: lastLoadedIndex)
    }

    private func finishPrepend(chapter: ReaderChapter, text: String?, proxy: ScrollViewProxy) {
        segments.insert(ReaderChapter(title: chapter.title, text: text, url: chapter.url, image: nil, isImagePage: chapter.isImagePage), at: 0)
        firstLoadedIndex -= 1
        currentIndex = firstLoadedIndex
        bookStore.updateProgress(bookID: book.id, chapterIndex: firstLoadedIndex)
        trimPageCache()
        // 前插后内容顶端暂落在视口下方，抑制顶部预加载，直到用户再次向下
        // 滚动超过阈值后由 evaluatePreload 统一解除（覆盖 onScrollGeometryChange
        // 与 PreferenceKey 两条几何路径）。
        suppressTopSentinel = true
        // 视口保持：滚到新章节末尾，使原有阅读位置基本不变
        proxy.scrollTo("segEnd-\(firstLoadedIndex)", anchor: .bottom)
    }

    /// 裁剪扫描页图片缓存：只保留当前已加载窗口 [firstLoadedIndex, lastLoadedIndex]
    /// 内的页，控制内存（避免整本扫描 PDF 全量解码进内存）。
    private func trimPageCache() {
        let lo = firstLoadedIndex
        let hi = lastLoadedIndex
        for key in pageImages.keys where key < lo || key > hi {
            pageImages.removeValue(forKey: key)
        }
    }

    // MARK: - 扫描页渲染

    /// 惰性渲染某一 PDF 页为 UIImage（带尺寸上限，@2x/@3x 屏自动高清）。
    /// 仅在正文的图片页进入视口时调用，渲染结果进入 pageImages 缓存。
    #if canImport(PDFKit)
    private func renderPageImage(for index: Int) -> UIImage? {
        guard let doc = pdfDocument, let page = doc.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let maxDim: CGFloat = 1400
        let scale = min(1.0, maxDim / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.white.setFill()
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx)
        }
    }
    #endif

    /// 确保指定章节（扫描页）的图片已渲染并进入缓存；缺失才渲染。
    private func ensurePageImage(index: Int) {
        guard pageImages[index] == nil else { return }
        #if canImport(PDFKit)
        if let img = renderPageImage(for: index) {
            pageImages[index] = img
        }
        #endif
    }

    /// 扫描 / 矢量页的图片视图：优先显示已渲染缓存；未渲染时按需渲染或给出降级提示。
    @ViewBuilder
    private func pageImageView(chapterIndex: Int) -> some View {
        if let img = pageImages[chapterIndex] {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        } else if pdfDocument != nil {
            ProgressView("渲染扫描页…")
                .frame(maxWidth: .infinity, minHeight: 200)
                .onAppear { ensurePageImage(index: chapterIndex) }
        } else {
            Text("（本页为扫描图片，无法渲染）")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        }
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
                    // 恢复退出前页位置（章内字符偏移）；无记录则从章首页开始
                    restorePageOffset = PagePositionStore.shared.offset(bookId: book.id, chapter: savedIndex)
                    // 同步 lastPageOffset：PagedReaderView 重建（排版设置变化）时以此定位当前页
                    lastPageOffset = restorePageOffset ?? 0
                    #if canImport(PDFKit)
                    if book.format == .pdf, let url = bookStore.fileURL(for: book) {
                        pdfDocument = PDFDocument(url: url)
                    }
                    #endif
                    if let restored, let text = restored.text {
                        segments = [ReaderChapter(title: restored.title, text: text, url: restored.url)]
                        isLoadingMore = false
                    } else if let restored, restored.isImagePage {
                        // 扫描 / 矢量页：图片由正文区按需渲染，不抓取文本
                        segments = [ReaderChapter(title: restored.title, text: nil, url: restored.url, isImagePage: true)]
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
                        // 同步写入 chapterTexts，供分页模式复用（避免切分页时重复抓取）
                        if !text.isEmpty { chapterTexts[savedIndex] = text }
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

    /// 本地书籍章节提取：按格式分发给 LocalBookReader（txt / epub / pdf / docx / mobi / azw3）。
    private func fetchLocalChapters(at url: URL) async throws -> [ReaderChapter] {
        try await LocalBookReader.chapters(format: book.format, title: book.displayTitle, at: url)
    }

    // MARK: - 规则阅读器

    /// 规则阅读器（对应 legado 的 ruleToc / ruleContent 链路）
    ///
    /// 用书源 ruleToc 抓取目录（纯函数，不修改 @State）。
    /// bookUrl 可能是相对路径（如 /book/12345.html），需拼接书源基准 URL。
    private func fetchRuleChapters() async throws -> [ReaderChapter] {
        guard let source = sourceStore.sources.first(where: { $0.bookSourceUrl == book.sourceId }) else {
            throw RuleError.unsupportedMode("书源不存在或已删除（sourceId=\(book.sourceId ?? "nil")）")
        }
        guard let rules = source.ruleToc, !rules.isEmpty else {
            throw RuleError.unsupportedMode("书源「\(source.bookSourceName)」缺少目录规则（ruleToc 为空），无法阅读")
        }
        guard let bookUrlStr = book.bookUrl else {
            throw RuleError.unsupportedMode("书籍缺少 bookUrl")
        }
        let bookURL = resolveURL(bookUrlStr, base: source.bookSourceURL)
            ?? URLSanitizer.sanitize(bookUrlStr)
        guard let bookURL else {
            throw RuleError.unsupportedMode("书籍 URL 无效：\(bookUrlStr)")
        }
        // 阅读链路同样合并书源 header（UA / Referer / Cookie），与搜索路径一致
        var headers = sourceHeaders(source)
        // 章节目录页常校验 Referer（缺则用书源根兜底），否则返回 404 / 空页
        if headers["Referer"] == nil && headers["referer"] == nil {
            headers["Referer"] = bookURL.absoluteString
        }
        let html = try await NetworkService.shared.fetchText(from: bookURL, headers: headers)
        let extracted = try extractToc(html: html, rules: rules, base: bookURL, sourceBase: source.bookSourceURL, source: source)
        if extracted.isEmpty { throw RuleError.emptyResult }
        return extracted
    }

    /// 书源 header 字段 → 请求头字典（ legado header 字段，缺它会被站点 401/403 拒绝）
    private func sourceHeaders(_ source: BookSource) -> [String: String] {
        guard let raw = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8) else {
            return [:]
        }
        let obj: [String: Any]?
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = result
        } else {
            let converted = raw.replacingOccurrences(of: "'", with: "\"")
            obj = try? JSONSerialization.jsonObject(
                with: converted.data(using: .utf8) ?? Data()
            ) as? [String: Any]
        }
        guard let obj else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in obj {
            result[key] = value is String ? value as! String : String(describing: value)
        }
        return result
    }

    /// 抓取指定章节正文（网络章节），返回文本字符串
    private func fetchContentText(for index: Int) async -> String {
        guard chapters.indices.contains(index) else { return "" }
        let chapter = chapters[index]
        if let text = chapter.text, !text.isEmpty { return text }
        guard let url = chapter.url else {
            return chapter.text ?? ""
        }
        // 章节 URL 可能是相对路径（如 /chapter/123.html），需拼接基准 URL。
        // 解析基准（对齐 legado）：书籍详情页 URL 优先，书源根兜底。
        guard let source = sourceStore.sources.first(where: { $0.bookSourceUrl == book.sourceId }) else {
            return "书源不存在或已删除"
        }
        let bookURL = resolveURL(book.bookUrl ?? "", base: source.bookSourceURL)
        let u = resolveURL(url, base: bookURL)
            ?? resolveURL(url, base: source.bookSourceURL)
            ?? URLSanitizer.sanitize(url)
        guard let u else {
            return chapter.text ?? ""
        }
        let engine = RuleEngine()
        engine.setSource(source)
        engine.setBook(book)
        engine.setBaseUrl(source.bookSourceUrl)
        engine.setChapter(title: chapter.title, nextUrl: chapters[safe: index + 1]?.url)
        let contentRule = source.ruleContent?.content ?? ""
        var headers = sourceHeaders(source)
        // 正文页防盗链普遍校验 Referer（缺则按书籍详情页兜底），否则 HTTP 404
        if headers["Referer"] == nil && headers["referer"] == nil, let ref = bookURL?.absoluteString {
            headers["Referer"] = ref
        }

        // 404 时的候选基准（依次重试）：当前 URL → 书源根 → 书籍详情页
        let retryBases: [URL?] = [source.bookSourceURL, bookURL]
        var retried: [URL] = []

        do {
            return try await fetchAndExtract(
                url: u, engine: engine, contentRule: contentRule,
                headers: headers, index: index, title: chapter.title
            )
        } catch NetworkError.badStatus(404) {
            // 章节 URL 可能被解析到了错误的基准。404 时换基准重新解析重试。
            for base in retryBases {
                if let candidate = resolveURL(url, base: base),
                   candidate != u, !retried.contains(candidate) {
                    retried.append(candidate)
                    do {
                        return try await fetchAndExtract(
                            url: candidate, engine: engine, contentRule: contentRule,
                            headers: headers, index: index, title: chapter.title
                        )
                    } catch {
                        continue
                    }
                }
            }
            return "加载失败：HTTP 404（\(u.absoluteString)）"
        } catch {
            return "加载失败：\(error.localizedDescription)（\(u.absoluteString)）"
        }
    }

    /// 抓取章节页并提取正文，缓存到章节
    private func fetchAndExtract(url: URL,
                                 engine: RuleEngine,
                                 contentRule: String,
                                 headers: [String: String],
                                 index: Int,
                                 title: String) async throws -> String {
        let html = try await NetworkService.shared.fetchText(from: url, headers: headers)
        let raw = (try? engine.getString(contentRule, content: html)) ?? ""
        // 内容清洗：部分书源（如 dbxsd）ruleContent 抽取到的是原始 HTML（含 <div> 开标签 /
        // <script> 防爬脚本 / <p> 标签），须对齐 legado 标准「内容清洗」——去 script/style、
        // 块标签转换行、去残余标签、解码实体，否则正文混入标签。
        let text = Self.cleanChapterContent(raw)
        let finalText = text.isEmpty ? "（本章无内容）" : text
        await MainActor.run {
            if chapters.indices.contains(index) {
                chapters[index].text = finalText
            }
        }
        return finalText
    }

    // MARK: - 内容清洗

    /// 章节正文 HTML 清洗（对齐 legado BookContent.cleanContent）：
    /// 1) 去除 <script>/<style> 块（含跨行）；2) 块级标签 / <br> 转换为换行；
    /// 3) 去除残余标签；4) 解码常见 HTML 实体；5) 折叠多余空行。
    /// 对纯文本（@text 抽取）幂等，对 HTML 抽取（@html / outerHTML）可修复标签污染。
    private static func cleanChapterContent(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // 1. 去 script / style 块（含跨行，忽略大小写）
        s = s.replacingOccurrences(of: #"(?is)<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
        // 2. 块级闭合标签 / <br> → 换行
        s = s.replacingOccurrences(of: #"(?i)</(p|div|h[1-6]|li|tr|blockquote|br)>|<br\s*/?>"#, with: "\n", options: .regularExpression)
        // 2b. 块级开标签（带属性）→ 换行
        s = s.replacingOccurrences(of: #"(?i)<(p|div|h[1-6]|li|tr|blockquote)[^>]*>"#, with: "\n", options: .regularExpression)
        // 3. 去除残余标签
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        // 4. 解码实体
        s = decodeHtmlEntities(s)
        // 5. 折叠多余空行并去首尾空白
        s = s.replacingOccurrences(of: #"\n[ \t]*\n[ \t]*\n+"#, with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    /// 解码常见 HTML 实体（命名 + 十进制/十六进制数字实体）。
    private static func decodeHtmlEntities(_ s: String) -> String {
        var r = s
        let map: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&hellip;": "…", "&ldquo;": "“", "&rdquo;": "”",
            "&lsquo;": "‘", "&rsquo;": "’", "&mdash;": "—", "&ndash;": "–",
            "&middot;": "·", "&bull;": "•", "&copy;": "©", "&reg;": "®"
        ]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) {
            let ns = r as NSString
            let matches = regex.matches(in: r, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let ent = ns.substring(with: m.range)
                let codeStr = String(ent.dropFirst(2).dropLast()).lowercased()
                var code: UInt32 = 0
                if codeStr.hasPrefix("x") {
                    code = UInt32(String(codeStr.dropFirst()), radix: 16) ?? 0
                } else {
                    code = UInt32(codeStr) ?? 0
                }
                if let scalar = UnicodeScalar(code) {
                    r = (r as NSString).replacingCharacters(in: m.range, with: String(scalar))
                }
            }
        }
        return r
    }

    // MARK: - 目录提取

    /// 从目录页 HTML 按规则提取章节列表（对应 legado TocAnalyzer 的 per-element 语义）：
    /// chapterList 求值产元素列表（CSS / XPath / JSON / 正则 / JS），
    /// chapterName / chapterUrl 逐元素求值（$N 分组、{{$.field}} 按元素回填）。
    /// 引擎实例贯穿目录抓取，@put/@get 变量在 chapterList → 字段间共享。
    private func extractToc(html: String, rules: SourceRuleSet, base: URL, sourceBase: URL? = nil, source: BookSource? = nil) throws -> [ReaderChapter] {
        let listRule = rules.chapterList ?? ""
        let nameRule = rules.chapterName ?? ""
        let urlRule = rules.chapterUrl ?? ""

        let engine = RuleEngine()
        if let source {
            engine.setSource(source)
        }
        // baseUrl 用目录页（书籍详情页）URL——起点 chapterUrl 的 JS 从 baseUrl 提取书籍 ID
        engine.setBaseUrl(base.absoluteString)
        engine.setBook(book)
        engine.setChapter(title: nil, nextUrl: nil)

        var ruleError: String?
        let items = BookListAnalyzer.items(rule: listRule, html: html, engine: engine, ruleError: &ruleError)
        guard !items.isEmpty else {
            if let ruleError {
                throw RuleError.ruleFailed(ruleError)
            }
            return []
        }

        var result: [ReaderChapter] = []
        for item in items {
            let name = BookListAnalyzer.field(nameRule, item: item, engine: engine)
            guard !name.isEmpty else { continue }
            let urlRel = BookListAnalyzer.field(urlRule, item: item, engine: engine)
            // 章节 URL 解析基准（对齐 legado）：**目录页（书籍详情页）URL 优先**，
            // 书源根兜底。纯相对文件名（如 `456.html`）只有相对目录页才正确；
            // 带前导 `/` 的绝对路径对两者等价。
            let resolved = resolveURL(urlRel, base: base)
                ?? resolveURL(urlRel, base: sourceBase)
                ?? URLSanitizer.sanitize(urlRel)
            let isVolumeText = BookListAnalyzer.field(rules.isVolume, item: item, engine: engine)
            result.append(ReaderChapter(
                title: name,
                text: nil,
                url: resolved?.absoluteString,
                isVolume: isVolumeText == "true" || isVolumeText == "1"
            ))
        }
        return result
    }

    private func resolveURL(_ relative: String, base: URL?) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        guard let base else { return nil }
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
