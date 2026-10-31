import SwiftUI
import UIKit

/// 真·左右翻页容器：UIKit UIPageViewController 封装，**页级分页**。
///
/// 相比 v50/v51 的「一页 = 一章」：
/// - 本版用 `ChapterPaginator`（Core Text）把章节按屏幕尺寸切成多页，翻页 = 翻**屏幕页**，
///   章节内部多页，跨章边界自动衔接（上一章末页 → 下一章首页）。
/// - 翻页动画：仿真 → `.pageCurl` 真卷页（单面，背面纸色）；滑动 → `.scroll`；
///   无 → `.scroll` 且程序化跳转不带动画。
/// - 页身份为 (chapterIndex, pageIndex)；正文按需抓取，文本就绪后自动重排定位。
/// - 设置（字号/字距/行距/背景/日夜间）变化时实时重排，并按字符 offset 保持当前页位置
///   （配合外层 live-preview 面板，正文可见且即时联动）。
///
/// 注意：UIPageViewController 的 transitionStyle 只能在 init 时设定，故调用方应以
/// `.id(settings.pageAnimation)` 包裹本组件，动画切换时强制重建。
///
/// 布局尺寸：不要在 make/update 里读 `vc.view.bounds`（未完成布局、尺寸不可靠），
/// 分页尺寸统一由 `PaginatedPageController.viewDidLayoutSubviews` 回调的真实 bounds 驱动，
/// 保证「分页尺寸 == 渲染尺寸」，避免改字体/日夜间/沉浸切换后下半空白或跳回章初始。
struct PagedReaderView: UIViewControllerRepresentable {
    @ObservedObject var settings: ReaderSettings
    var chapters: [ReaderChapter]
    /// 网络章正文缓存（chapterIndex → text）；本地章走 chapters[].text
    var texts: [Int: String]
    /// 当前全局章节下标（与 BookReaderView.currentIndex 双向绑定）
    @Binding var selection: Int
    /// 共享分页器（跨设置变化持久缓存与重排）
    var paginator: ChapterPaginator
    /// 首次进入时的章内字符 offset（恢复退出前页面；nil → 章首页）
    var initialPageOffset: Int?
    /// 按需抓取正文（对齐 ensureChapterText 语义：命中缓存直接返回，否则网络抓取）
    var onNeedsText: (Int) async -> String
    /// 翻页完成回调：(chapterIndex, pageIndex, offset)。运行于主线程（UIKit delegate）。
    var onPageChange: @MainActor (Int, Int, Int) -> Void
    /// 扫描版 PDF 图片页渲染器（全局下标 → 图片视图）
    var pageImage: (Int) -> AnyView?
    /// 排版重排令牌：外层在排版设置变化时自增。外层以 `.id("\(reflowToken)|\(pageAnimation)")`
    /// 包裹本组件——令牌变化即触发**全量重建**（新 makeUIViewController，等价于退出返回的即时版），
    /// 保证改字号/字距/行距/背景/日夜间在当前页立即生效。
    /// 本字段同时作为 updateUIViewController 内 forceRelayout 的兜底比对（重建后首帧不重复重排）。
    var reflowToken: Int = 0
    /// 沉浸模式「单击中央」回调。页面模式下用原生 UITapGestureRecognizer 触发，
    /// 避免被 UIPageViewController 的 pan/卷页手势吞掉（SwiftUI SpatialTapGesture 的失效根因）。
    var onImmersiveTap: () -> Void = {}

    /// 页内容边距（与 ChapterPaginator 分页 pageSize 的扣除量一致）
    static let pageInsets = UIEdgeInsets(top: 12, left: 20, bottom: 40, right: 20)

    // MARK: - 排版派生

    /// 内容区尺寸（扣除页边距）
    func contentSize(of bounds: CGRect) -> CGSize {
        guard bounds.width > 1, bounds.height > 1 else { return .zero }
        let insets = Self.pageInsets
        return CGSize(width: bounds.width - insets.left - insets.right,
                      height: bounds.height - insets.top - insets.bottom)
    }

    /// 排版指纹：任一排版/背景设置变化 → 指纹变化 → 触发重排
    var layoutFingerprint: String {
        "\(settings.fontFamily.rawValue)|\(settings.customFontName)|\(settings.fontSize)|\(settings.letterSpacing)|\(settings.lineSpacing)|\(settings.justified)|\(settings.theme.rawValue)|\(settings.isNight)|\(settings.showChapterHeader)"
    }

    /// 当前排版属性（供 Core Text 分页与页面渲染共用）
    func buildAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolveUIFont(),
            .foregroundColor: UIColor(settings.effectiveForeground),
            .kern: CGFloat(settings.letterSpacing),
        ]
        let para = NSMutableParagraphStyle()
        para.lineSpacing = CGFloat(settings.lineSpacing)
        para.paragraphSpacing = 4
        para.alignment = settings.justified ? .justified : .left
        attrs[.paragraphStyle] = para
        return attrs
    }

    private func resolveUIFont() -> UIFont {
        let size = CGFloat(settings.fontSize)
        if !settings.customFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return UIFont(name: settings.customFontName, size: size) ?? UIFont.systemFont(ofSize: size)
        }
        switch settings.fontFamily {
        case .system: return UIFont.systemFont(ofSize: size)
        case .songti: return UIFont(name: "Songti SC", size: size) ?? UIFont.systemFont(ofSize: size)
        case .heiti:  return UIFont(name: "Heiti SC", size: size) ?? UIFont.systemFont(ofSize: size)
        case .kaiti:  return UIFont(name: "Kaiti SC", size: size) ?? UIFont.systemFont(ofSize: size)
        }
    }

    /// 某章参与分页的全文（标题拼在正文前，章首页自然含标题）。
    /// 正文来源：网络章走 texts 缓存，本地章走 chapters[].text——分页与切片必须取**同一字符串**，
    /// 否则页边界错位 → 内容跳变/重复（「翻页内容不连贯」根因之一）。
    func pageText(_ chapterIndex: Int) -> String {
        guard let ch = chapters[safe: chapterIndex] else { return "" }
        var body: String
        if let t = texts[chapterIndex], !t.isEmpty {
            body = t
        } else if let t = ch.text, !t.isEmpty {
            body = t
        } else {
            body = ""
        }
        guard !body.isEmpty else { return "" }
        if settings.showChapterHeader && !ch.title.isEmpty {
            return ch.title + "\n\n" + body
        }
        return body
    }

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UIPageViewController {
        let style: UIPageViewController.TransitionStyle =
            settings.pageAnimation == .curl ? .pageCurl : .scroll
        // 用 PaginatedPageController：分页尺寸不在此处读 vc.view.bounds（未完成布局、不可靠），
        // 统一由 viewDidLayoutSubviews 回调的真实 bounds 驱动（见 handleBoundsChange）。
        // 此处的 configure 仅作首帧兜底，布局完成后立即被真实尺寸纠正。
        let vc = PaginatedPageController(transitionStyle: style,
                                         navigationOrientation: .horizontal,
                                         options: nil)
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.view.backgroundColor = UIColor(settings.effectiveBackground)
        // 仿真卷页：单面卷曲（背面显示纸色）。
        // 注意：isDoubleSided=true 会令 UIPageViewController 把「相邻页镜像到当前页背面」，
        // 造成内容重复 / 阅读顺序错乱；单页数据源下应恒为 false，保证翻页顺序与内容连贯。
        vc.isDoubleSided = false
        context.coordinator.parent = self
        context.coordinator.attach(pvc: vc)
        context.coordinator.configure(pageSize: contentSize(of: vc.view.bounds))
        // 沉浸「单击中央」：原生 tap 手势，允许与 UIPageViewController 的翻页手势并存识别，
        // 且仅命中中央区域（水平 ±1/6、垂直 ±1/3）时回调——不吞边缘点按（保留翻页点按）。
        let immersiveTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleImmersiveTap(_:)))
        immersiveTap.cancelsTouchesInView = false
        immersiveTap.delegate = context.coordinator
        vc.view.addGestureRecognizer(immersiveTap)
        // 初始定位：章 + 页（由字符 offset 决定页下标）
        let (chapter, page) = context.coordinator.initialTarget(
            selection: selection, offset: initialPageOffset)
        if let first = context.coordinator.pageVC(chapterIndex: chapter, pageIndex: page) {
            vc.setViewControllers([first], direction: .forward, animated: false)
            context.coordinator.currentChapter = chapter
            context.coordinator.currentPage = page
        }
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.onImmersiveTap = onImmersiveTap
        vc.view.backgroundColor = UIColor(settings.effectiveBackground)
        vc.isDoubleSided = false
        context.coordinator.attach(pvc: vc)
        let size = contentSize(of: vc.view.bounds)
        // 排版令牌变化（外层设置变更）→ 强制重排，确保「改字号/字距/行距/背景/日夜间」立即重排生效，
        // 而非仅靠 updateUIViewController 的自然触发（那正是「仅往后翻页才生效」的根因）。
        if reflowToken != context.coordinator.lastReflowToken {
            context.coordinator.lastReflowToken = reflowToken
            context.coordinator.forceRelayout(pageSize: size)
        } else {
            context.coordinator.applyIfNeeded(pageSize: size, fingerprint: layoutFingerprint)
        }

        // 外部跳章（目录 / 工具栏 / 设置切换）→ 与当前显示不一致时重新定位到章首页
        let desired = selection
        if context.coordinator.currentChapter != desired,
           let target = context.coordinator.pageVC(chapterIndex: desired, pageIndex: 0) {
            let dir: UIPageViewController.NavigationDirection =
                desired > context.coordinator.currentChapter ? .forward : .reverse
            context.coordinator.currentChapter = desired
            context.coordinator.currentPage = 0
            vc.setViewControllers([target], direction: dir,
                                  animated: settings.pageAnimation != .none)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PagedReaderView
        var currentChapter: Int
        var currentPage: Int
        private var vcCache: [String: UIViewController] = [:]
        private var lastFingerprint = ""
        private weak var pvc: UIPageViewController?
        /// 排版重排令牌（与 parent.reflowToken 比对，变化即强制重排）。
        /// 注：非 private——外层 PagedReaderView.updateUIViewController 会比对它。
        var lastReflowToken = 0
        /// 沉浸「单击中央」回调（由 updateUIViewController 随父视图刷新）
        var onImmersiveTap: (() -> Void)?

        init(_ parent: PagedReaderView) {
            self.parent = parent
            self.currentChapter = parent.selection
            self.currentPage = 0
            // 以初始令牌为基准：重建（.id 变化）后首帧不触发多余 forceRelayout
            self.lastReflowToken = parent.reflowToken
        }

        func attach(pvc: UIPageViewController) {
            self.pvc = pvc
            // 布局完成 → 真实 bounds 回调 → 重新分页（保证分页尺寸 == 渲染尺寸）。
            // 延后到下一 runloop：viewDidLayoutSubviews 期间 setViewControllers 可能触发再布局，
            // 异步化避免布局中重入；尺寸相同（同一次布局多次回调）时 handleBoundsChange 自去重。
            if let pc = pvc as? PaginatedPageController {
                pc.onBoundsChange = { [weak self] size in
                    DispatchQueue.main.async { self?.handleBoundsChange(size) }
                }
            }
        }

        /// 真实布局尺寸变化（含首次布局完成）→ 重新分页并保持字符 offset。
        /// 这是「分页尺寸 == 渲染尺寸」的权威来源：改字号/字距/行距/背景/日夜间、
        /// 设置面板开合、沉浸 chrome 显隐（改变 safe area）都会走到这里，页面即时自适应，
        /// 不再出现下半空白或跳回章初始。
        private func handleBoundsChange(_ size: CGSize) {
            let content = parent.contentSize(of: CGRect(origin: .zero, size: size))
            guard content.width > 1, content.height > 1 else { return }
            // 尺寸未变（同一次布局多次回调 / 面板动画中间帧）→ 跳过，避免反复重排
            if content == parent.paginator.pageSize { return }
            let off = currentOffset()
            parent.paginator.pageSize = content
            parent.paginator.attributes = parent.buildAttributes()
            parent.paginator.invalidate()
            vcCache.removeAll()
            relayoutCurrentPage(to: off)
        }

        func configure(pageSize: CGSize) {
            parent.paginator.pageSize = pageSize
            parent.paginator.attributes = parent.buildAttributes()
            parent.paginator.invalidate()
            // 以当前排版指纹为基准：重建后 applyIfNeeded 不误判为「排版已变化」而重复重排
            lastFingerprint = parent.layoutFingerprint
        }


        /// 某章页数（图片章恒为 1 页；文本未就绪返回 0）
        private func pageCount(_ chapterIndex: Int) -> Int {
            guard parent.chapters.indices.contains(chapterIndex) else { return 0 }
            let ch = parent.chapters[chapterIndex]
            if ch.isImagePage { return 1 }
            let ranges = parent.paginator.pages(chapterIndex: chapterIndex, text: parent.pageText(chapterIndex))
            return ranges.isEmpty ? 0 : ranges.count
        }

        /// 初始目标页：(chapter, page)。offset 定位到对应页。
        func initialTarget(selection: Int, offset: Int?) -> (Int, Int) {
            let chapter = selection
            guard parent.chapters.indices.contains(chapter) else { return (chapter, 0) }
            guard let offset else { return (chapter, 0) }
            let ranges = parent.paginator.pages(chapterIndex: chapter, text: parent.pageText(chapter))
            if ranges.isEmpty { return (chapter, 0) }
            return (chapter, ChapterPaginator.pageIndex(for: offset, in: ranges))
        }

        // MARK: 页控制器构造 / 复用

        func pageVC(chapterIndex: Int, pageIndex: Int) -> UIViewController? {
            let key = "\(chapterIndex):\(pageIndex)"
            if let cached = vcCache[key] { return cached }
            guard parent.chapters.indices.contains(chapterIndex) else { return nil }
            let chapter = parent.chapters[chapterIndex]
            let bg = UIColor(parent.settings.effectiveBackground)

            // 扫描 / 矢量图片页：整章一页
            if chapter.isImagePage {
                let img = parent.pageImage(chapterIndex) ?? AnyView(
                    Text("（本页为扫描图片，无法渲染）")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                )
                let host = UIHostingController(rootView: img)
                host.view.backgroundColor = bg
                vcCache[key] = host
                return host
            }

            // 文本页：按分页 range 取子串
            let ranges = parent.paginator.pages(chapterIndex: chapterIndex, text: parent.pageText(chapterIndex))
            if ranges.isEmpty {
                // 正文未就绪：占位页（加载提示），并触发正文抓取。
                // 不入 vcCache：文本就绪后 applyIfNeeded 非重排路径经 hasPageVC==false 重建为真实页，
                // 否则占位页会永久卡在「正在加载正文…」。
                Task { _ = await parent.onNeedsText(chapterIndex) }
                let host = UIHostingController(
                    rootView: Text("正在加载正文…")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                )
                host.view.backgroundColor = bg
                return host
            }
            guard ranges.indices.contains(pageIndex) else { return nil }
            let range = ranges[pageIndex]
            let full = parent.pageText(chapterIndex)
            let ns = full as NSString
            let loc = min(max(range.location, 0), ns.length)
            let len = min(max(range.length, 0), ns.length - loc)
            let slice = len > 0 ? ns.substring(with: NSRange(location: loc, length: len)) : ""

            let pageView = CoreTextPageView()
            pageView.contentInsets = PagedReaderView.pageInsets
            pageView.attrString = NSAttributedString(string: slice, attributes: parent.buildAttributes())
            pageView.backgroundColor = bg
            // 关键：bounds 变化时重绘而非缩放，否则面板出现/尺寸收缩时旧文本被拉伸「变形」
            pageView.contentMode = .redraw

            let vc = UIViewController()
            vc.view = pageView
            vcCache[key] = vc
            return vc
        }

        private func hasPageVC(_ chapterIndex: Int, _ pageIndex: Int) -> Bool {
            vcCache["\(chapterIndex):\(pageIndex)"] != nil
        }

        // MARK: 重排（设置 / 尺寸变化，保持字符 offset）

        /// 应用设置变化：指纹变化 → 清缓存重排并回到当前内容位置。
        /// 文本刚到达（占位→真实）也在非重排路径检测刷新。
        ///
        /// 重要：**不再用调用方传入的 pageSize 做尺寸重排**。尺寸变化的重排统一由
        /// `handleBoundsChange`（`viewDidLayoutSubviews` 的真实布局尺寸）驱动——因为
        /// `updateUIViewController` 里读 `vc.view.bounds` 时布局尚未完成，尺寸不可靠
        /// （设置面板打开 / 沉浸 chrome 切换时更小），用它重新分页会得到错误 pageSize
        /// → 页面内容错乱、不保持当前内容（「沉浸开关切换后页面跳变」根因）。
        /// 仅当尚无可靠尺寸（pageSize == .zero）时兜底设置一次，随后被真实尺寸纠正。
        func applyIfNeeded(pageSize: CGSize, fingerprint: String) {
            if parent.paginator.pageSize == .zero,
               pageSize.width > 1, pageSize.height > 1 {
                parent.paginator.pageSize = pageSize
            }
            if fingerprint != lastFingerprint {
                lastFingerprint = fingerprint
                // 记录当前字符偏移（用**旧**分页，invalidate 前），重排后仍定位到同一内容。
                // 尺寸用 paginator.pageSize（真实布局，由 handleBoundsChange 维护）。
                let off = currentOffset()
                parent.paginator.attributes = parent.buildAttributes()
                parent.paginator.invalidate()
                // 关键：清页控制器缓存，否则当前页/已访问页仍返回旧排版内容，
                // 表现为「改字号仅在往后翻页后生效、当前页不变、面板收缩时页面变形」。
                vcCache.removeAll()
                relayoutCurrentPage(to: off)
                return
            }
            // 非重排：检查当前章文本是否刚就绪（占位 → 真实页）。
            // 占位页不入缓存，故文本就绪后 hasPageVC 为 false → 重建为真实页。
            let ranges = parent.paginator.pages(chapterIndex: currentChapter, text: parent.pageText(currentChapter))
            if ranges.isEmpty { return }
            if currentPage >= ranges.count {
                relayoutCurrentPage(to: currentOffset())
            } else if !hasPageVC(currentChapter, currentPage) {
                if let target = pageVC(chapterIndex: currentChapter, pageIndex: currentPage) {
                    pvc?.setViewControllers([target], direction: .forward, animated: false)
                }
            }
        }

        /// 重排当前页：按给定字符 offset 重算分页，定位到含该 offset 的新页
        private func relayoutCurrentPage(to offset: Int) {
            let ranges = parent.paginator.pages(chapterIndex: currentChapter, text: parent.pageText(currentChapter))
            guard !ranges.isEmpty else { return }
            let newPage = ChapterPaginator.pageIndex(for: offset, in: ranges)
            if let target = pageVC(chapterIndex: currentChapter, pageIndex: newPage) {
                currentPage = newPage
                pvc?.setViewControllers([target], direction: .forward, animated: false)
            }
        }

        /// 强制重排（排版令牌变化时由 updateUIViewController 调用）：记录当前字符 offset →
        /// 更新分页参数 → 清分页缓存 + 页控制器缓存 → 按 offset 重新定位。
        /// 保证「改字号/字距/行距/背景/日夜间」在当前页立即生效，而非仅往后翻页才变。
        ///
        /// 尺寸用**可靠 pageSize**（handleBoundsChange 维护的真实布局尺寸）优先；
        /// 传入的 pageSize 仅在尚无可靠尺寸时作首帧兜底（随后被真实尺寸纠正）。
        func forceRelayout(pageSize: CGSize) {
            let off = currentOffset()
            let size = parent.paginator.pageSize.width > 1 ? parent.paginator.pageSize : pageSize
            parent.paginator.pageSize = size
            parent.paginator.attributes = parent.buildAttributes()
            parent.paginator.invalidate()
            vcCache.removeAll()
            relayoutCurrentPage(to: off)
        }

        /// 沉浸「单击中央」：仅在沉浸模式且命中中央区域时回调切换控制层显隐。
        /// 用原生手势而非 SwiftUI SpatialTapGesture——后者会被 UIPageViewController 的
        /// pan/卷页手势吞掉，导致中央切换失效（「沉浸式单击中央切换丢失」根因）。
        @objc func handleImmersiveTap(_ gesture: UITapGestureRecognizer) {
            guard parent.settings.isImmersive, let view = gesture.view else { return }
            let size = view.bounds.size
            let loc = gesture.location(in: view)
            if abs(loc.x - size.width / 2) < size.width / 6 &&
               abs(loc.y - size.height / 2) < size.height / 3 {
                onImmersiveTap?()
            }
        }

        /// 与 UIPageViewController 的翻页手势并存：不吞掉滑动 / 卷页识别。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        private func currentOffset() -> Int {
            let ranges = parent.paginator.pages(chapterIndex: currentChapter, text: parent.pageText(currentChapter))
            guard ranges.indices.contains(currentPage) else { return 0 }
            return ranges[currentPage].location
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let (c, p) = identity(of: viewController) else { return nil }
            if p > 0 { return pageVC(chapterIndex: c, pageIndex: p - 1) }
            // 章首页 → 上一章末页（需上一章已分页，否则返回 nil，待文本就绪）
            if c > 0 {
                let prevCount = pageCount(c - 1)
                if prevCount > 0 { return pageVC(chapterIndex: c - 1, pageIndex: prevCount - 1) }
            }
            return nil
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let (c, p) = identity(of: viewController) else { return nil }
            let count = pageCount(c)
            if p + 1 < count { return pageVC(chapterIndex: c, pageIndex: p + 1) }
            // 章末页 → 下一章首页（需下一章已分页，否则返回 nil）
            if c + 1 < parent.chapters.count {
                if pageCount(c + 1) > 0 { return pageVC(chapterIndex: c + 1, pageIndex: 0) }
            }
            return nil
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let current = pageViewController.viewControllers?.first,
                  let (c, p) = identity(of: current) else { return }
            currentChapter = c
            currentPage = p
            let ranges = parent.paginator.pages(chapterIndex: c, text: parent.pageText(c))
            let offset = ranges.indices.contains(p) ? ranges[p].location : 0
            parent.selection = c
            parent.onPageChange(c, p, offset)
        }

        private func identity(of vc: UIViewController) -> (Int, Int)? {
            for (key, cached) in vcCache where cached === vc {
                let parts = key.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 { return (parts[0], parts[1]) }
            }
            return nil
        }
    }
}

/// 感知**真实布局尺寸**的页控制器。
///
/// 背景：在 makeUIViewController / updateUIViewController 里读 `vc.view.bounds` 并不可靠——
/// 新页控制器的 view 尚未完成布局（常为默认或缩小的尺寸，设置面板打开时更小），
/// 导致 `configure` 用**过小的 pageSize** 分页 → 每页只放得下几行；
/// 而渲染（CoreTextPageView.draw）用的是布局完成后的**真实 bounds**（更高）→
/// 顶部几行 + 下半大片空白（「改字体后页面不自适应，下半空白，退出重进才正常」根因）。
///
/// 本控制器在 `viewDidLayoutSubviews`（布局完成、尺寸真实）后回调真实 bounds，
/// 驱动 Coordinator 重新分页并保持字符 offset——保证「分页尺寸 == 渲染尺寸」恒成立，
/// 改字号/字距/行距/背景/日夜间及沉浸切换（改变 safe area）后页面即时自适应，
/// 不再出现下半空白或跳回章初始。
final class PaginatedPageController: UIPageViewController {
    /// 布局完成后回调真实 bounds（仅尺寸变化时触发，已去重）
    var onBoundsChange: ((CGSize) -> Void)?
    private var lastReported: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let s = view.bounds.size
        guard s.width > 1, s.height > 1, s != lastReported else { return }
        lastReported = s
        onBoundsChange?(s)
    }
}
