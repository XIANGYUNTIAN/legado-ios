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

    /// 某章参与分页的全文（标题拼在正文前，章首页自然含标题）
    func fullText(for chapter: ReaderChapter) -> String {
        guard let t = chapter.text, !t.isEmpty else { return "" }
        if settings.showChapterHeader && !chapter.title.isEmpty {
            return chapter.title + "\n\n" + t
        }
        return t
    }

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UIPageViewController {
        let style: UIPageViewController.TransitionStyle =
            settings.pageAnimation == .curl ? .pageCurl : .scroll
        let vc = UIPageViewController(transitionStyle: style,
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
        context.coordinator.configure(pageSize: contentSize(of: vc.view.bounds))
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
        vc.view.backgroundColor = UIColor(settings.effectiveBackground)
        vc.isDoubleSided = false
        context.coordinator.attach(pvc: vc)
        let size = contentSize(of: vc.view.bounds)
        context.coordinator.applyIfNeeded(pageSize: size, fingerprint: layoutFingerprint)

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

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagedReaderView
        var currentChapter: Int
        var currentPage: Int
        private var vcCache: [String: UIViewController] = [:]
        private var lastFingerprint = ""
        private weak var pvc: UIPageViewController?

        init(_ parent: PagedReaderView) {
            self.parent = parent
            self.currentChapter = parent.selection
            self.currentPage = 0
        }

        func attach(pvc: UIPageViewController) { self.pvc = pvc }

        func configure(pageSize: CGSize) {
            parent.paginator.pageSize = pageSize
            parent.paginator.attributes = parent.buildAttributes()
            parent.paginator.invalidate()
        }

        /// 当前章正文（网络章优先走 texts 缓存，本地章走 chapters[].text）
        private func currentText(_ chapterIndex: Int) -> String? {
            if let t = parent.texts[chapterIndex], !t.isEmpty { return t }
            guard let ch = parent.chapters[safe: chapterIndex] else { return nil }
            return ch.text
        }

        /// 某章页数（图片章恒为 1 页；文本未就绪返回 0）
        private func pageCount(_ chapterIndex: Int) -> Int {
            guard parent.chapters.indices.contains(chapterIndex) else { return 0 }
            let ch = parent.chapters[chapterIndex]
            if ch.isImagePage { return 1 }
            let ranges = parent.paginator.pages(chapterIndex: chapterIndex, text: currentText(chapterIndex))
            return ranges.isEmpty ? 0 : ranges.count
        }

        /// 初始目标页：(chapter, page)。offset 定位到对应页。
        func initialTarget(selection: Int, offset: Int?) -> (Int, Int) {
            let chapter = selection
            guard parent.chapters.indices.contains(chapter) else { return (chapter, 0) }
            guard let offset else { return (chapter, 0) }
            let ranges = parent.paginator.pages(chapterIndex: chapter, text: currentText(chapter))
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
            let ranges = parent.paginator.pages(chapterIndex: chapterIndex, text: currentText(chapterIndex))
            if ranges.isEmpty {
                // 正文未就绪：占位页（加载提示），并触发正文抓取；文本到达后由 applyIfNeeded 重定位。
                Task { _ = await parent.onNeedsText(chapterIndex) }
                let host = UIHostingController(
                    rootView: Text("正在加载正文…")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                )
                host.view.backgroundColor = bg
                vcCache[key] = host
                return host
            }
            guard ranges.indices.contains(pageIndex) else { return nil }
            let range = ranges[pageIndex]
            let full = parent.fullText(for: chapter)
            let ns = full as NSString
            let loc = min(max(range.location, 0), ns.length)
            let len = min(max(range.length, 0), ns.length - loc)
            let slice = len > 0 ? ns.substring(with: NSRange(location: loc, length: len)) : ""

            let pageView = CoreTextPageView()
            pageView.contentInsets = PagedReaderView.pageInsets
            pageView.attrString = NSAttributedString(string: slice, attributes: parent.buildAttributes())
            pageView.backgroundColor = bg

            let vc = UIViewController()
            vc.view = pageView
            vcCache[key] = vc
            return vc
        }

        private func hasPageVC(_ chapterIndex: Int, _ pageIndex: Int) -> Bool {
            vcCache["\(chapterIndex):\(pageIndex)"] != nil
        }

        // MARK: 重排（设置 / 尺寸变化，保持字符 offset）

        /// 应用设置与尺寸变化：指纹或尺寸变化 → 清缓存重排并回到当前内容位置。
        /// 文本刚到达（占位→真实）也在非重排路径检测刷新。
        func applyIfNeeded(pageSize: CGSize, fingerprint: String) {
            var needsRelayout = false
            if pageSize != parent.paginator.pageSize {
                parent.paginator.pageSize = pageSize
                needsRelayout = true
            }
            if fingerprint != lastFingerprint {
                lastFingerprint = fingerprint
                parent.paginator.attributes = parent.buildAttributes()
                needsRelayout = true
            }
            if needsRelayout {
                parent.paginator.invalidate()
                relayoutCurrentPage()
                return
            }
            // 非重排：检查当前章文本是否刚就绪（占位 → 真实页）
            let ranges = parent.paginator.pages(chapterIndex: currentChapter, text: currentText(currentChapter))
            if ranges.isEmpty { return }
            if currentPage >= ranges.count {
                relayoutCurrentPage()
            } else if !hasPageVC(currentChapter, currentPage) {
                if let target = pageVC(chapterIndex: currentChapter, pageIndex: currentPage) {
                    pvc?.setViewControllers([target], direction: .forward, animated: false)
                }
            }
        }

        /// 重排当前页：记录当前字符 offset，重算分页后定位到含该 offset 的新页
        private func relayoutCurrentPage() {
            let off = currentOffset()
            let ranges = parent.paginator.pages(chapterIndex: currentChapter, text: currentText(currentChapter))
            guard !ranges.isEmpty else { return }
            let newPage = ChapterPaginator.pageIndex(for: off, in: ranges)
            if let target = pageVC(chapterIndex: currentChapter, pageIndex: newPage) {
                currentPage = newPage
                pvc?.setViewControllers([target], direction: .forward, animated: false)
            }
        }

        private func currentOffset() -> Int {
            let ranges = parent.paginator.pages(chapterIndex: currentChapter, text: currentText(currentChapter))
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
            let ranges = parent.paginator.pages(chapterIndex: c, text: currentText(c))
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
