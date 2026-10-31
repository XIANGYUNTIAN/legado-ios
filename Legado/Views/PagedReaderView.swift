import SwiftUI
import UIKit

/// 真·左右翻页容器：UIKit UIPageViewController 封装。
///
/// - 一页 = 一个章节（长章内部纵向滚动，正文按需异步抓取）。
/// - 翻页动画：仿真 → .pageCurl（真卷页）；滑动 → .scroll；无 → .scroll 且程序化跳转不带动画。
/// - 数据源按「全章节数组 + 全局下标」直接取页，天然支持前后双向翻页，无需窗口前插/移位。
///
/// 注意：UIPageViewController 的 transitionStyle 只能在 init 时设定，故调用方应以
/// `.id(settings.pageAnimation)` 包裹本组件，动画切换时强制重建。
struct PagedReaderView: UIViewControllerRepresentable {
    @ObservedObject var settings: ReaderSettings
    var chapters: [ReaderChapter]
    /// 当前全局章节下标（与 BookReaderView.currentIndex 双向绑定）
    @Binding var selection: Int
    /// 按需抓取正文（对齐 ensureChapterText 语义：命中缓存直接返回，否则网络抓取）
    var onNeedsText: (Int) async -> String
    /// 翻页完成回调（全局下标）
    var onPageChange: (Int) -> Void
    /// 扫描版 PDF 图片页渲染器（全局下标 → 图片视图）
    var pageImage: (Int) -> AnyView?

    func makeUIViewController(context: Context) -> UIPageViewController {
        let style: UIPageViewController.TransitionStyle =
            settings.pageAnimation == .curl ? .pageCurl : .scroll
        let vc = UIPageViewController(transitionStyle: style,
                                      navigationOrientation: .horizontal,
                                      options: nil)
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.view.backgroundColor = UIColor(settings.effectiveBackground)
        context.coordinator.parent = self
        if let first = context.coordinator.pageVC(for: selection) {
            vc.setViewControllers([first], direction: .forward, animated: false)
        }
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        vc.view.backgroundColor = UIColor(settings.effectiveBackground)
        // 外部跳转（目录 / 工具栏 / 设置切换）→ 与当前显示不一致时重新定位
        let desired = selection
        if context.coordinator.currentIndex != desired,
           let target = context.coordinator.pageVC(for: desired) {
            let dir: UIPageViewController.NavigationDirection =
                desired > context.coordinator.currentIndex ? .forward : .reverse
            context.coordinator.currentIndex = desired
            vc.setViewControllers([target], direction: dir,
                                  animated: settings.pageAnimation != .none)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagedReaderView
        var currentIndex: Int
        private var cache: [Int: UIViewController] = [:]

        init(_ parent: PagedReaderView) {
            self.parent = parent
            self.currentIndex = parent.selection
        }

        /// 构造/复用某全局章节对应的宿主控制器（按全局下标缓存，章节数组增长不失效）
        func pageVC(for globalIndex: Int) -> UIViewController? {
            guard parent.chapters.indices.contains(globalIndex) else { return nil }
            if let cached = cache[globalIndex] { return cached }
            let chapter = parent.chapters[globalIndex]
            let root = PagedChapterView(chapter: chapter,
                                        globalIndex: globalIndex,
                                        settings: parent.settings,
                                        onNeedsText: parent.onNeedsText,
                                        pageImage: parent.pageImage)
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = UIColor(parent.settings.effectiveBackground)
            cache[globalIndex] = host
            return host
        }

        // MARK: - UIPageViewControllerDataSource

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            let idx = index(of: viewController)
            guard idx != NSNotFound, idx > 0 else { return nil }
            return pageVC(for: idx - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            let idx = index(of: viewController)
            guard idx != NSNotFound, idx >= 0, idx + 1 < parent.chapters.count else { return nil }
            return pageVC(for: idx + 1)
        }

        // MARK: - UIPageViewControllerDelegate

        func pageViewController(_ pageViewController: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let current = pageViewController.viewControllers?.first else { return }
            let idx = index(of: current)
            guard idx != NSNotFound else { return }
            currentIndex = idx
            parent.selection = idx
            parent.onPageChange(idx)
        }

        private func index(of vc: UIViewController) -> Int {
            for (idx, cached) in cache where cached === vc { return idx }
            return NSNotFound
        }
    }
}

/// 分页模式下的单个章节页：内部纵向滚动容纳长章，正文按需抓取，扫描 PDF 图片页走提供器。
private struct PagedChapterView: View {
    let chapter: ReaderChapter
    let globalIndex: Int
    @ObservedObject var settings: ReaderSettings
    let onNeedsText: (Int) async -> String
    let pageImage: (Int) -> AnyView?

    @State private var text: String?
    @State private var isLoadingText = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if settings.showChapterHeader {
                    Text(chapter.title)
                        .font(settings.textFont)
                        .tracking(CGFloat(settings.letterSpacing))
                        .foregroundStyle(settings.effectiveForeground)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, settings.lineSpacing * 2)
                }
                if chapter.isImagePage {
                    if let img = pageImage(globalIndex) {
                        img
                    } else {
                        Text("（本页无图像）")
                            .font(settings.textFont)
                            .foregroundStyle(settings.effectiveForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                } else if let t = text, !t.isEmpty {
                    Text(t)
                        .font(settings.textFont)
                        .tracking(CGFloat(settings.letterSpacing))
                        .lineSpacing(settings.lineSpacing)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(settings.effectiveForeground)
                        .textSelection(.enabled)
                } else if isLoadingText {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    Text("（本章无内容）")
                        .font(settings.textFont)
                        .foregroundStyle(settings.effectiveForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 80)
        }
        .background(settings.effectiveBackground)
        .onAppear {
            guard text == nil, !chapter.isImagePage else { return }
            isLoadingText = true
            Task {
                let fetched = await onNeedsText(globalIndex)
                await MainActor.run {
                    text = fetched.isEmpty ? nil : fetched
                    isLoadingText = false
                }
            }
        }
    }
}
