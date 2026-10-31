import Foundation
import UIKit
import CoreText

/// 按屏幕尺寸把章节文本切成多页（页 = 一屏）的引擎。
///
/// 用 Core Text `CTFramesetter` 循环切分：每页生成一个 frame，取可见字符范围 `NSRange`，
/// 直至文本切完。这样「左右翻页」翻的是**屏幕页**，章节内部多页，跨章自然衔接——
/// 而不是 v50/v51 的「一页 = 一章，翻页即翻章」。
///
/// 线程说明：所有方法在 UIKit 主线程调用（UIPageViewController 数据源 / 委托回调均主线程），
/// 故不做并发隔离；缓存按章下标索引，设置或尺寸变化时 `invalidate()` 全清重排。
final class ChapterPaginator {
    /// 每章分页缓存：chapterIndex → 该章 [NSRange]（每页可见字符范围）
    private var cache: [Int: [NSRange]] = [:]
    /// 分页可用尺寸（内容区，已扣除页边距）
    var pageSize: CGSize = .zero
    /// 排版属性（字体/字号/字距/行距/颜色）
    var attributes: [NSAttributedString.Key: Any] = [:]

    /// 清空分页缓存（设置变化 / 尺寸变化时调用，触发重排）
    func invalidate() {
        cache.removeAll()
    }

    /// 某章的分页结果。文本未就绪或尺寸非法时返回空数组（调用方据此做占位/等待）。
    func pages(chapterIndex: Int, text: String?) -> [NSRange] {
        guard let text, !text.isEmpty,
              pageSize.width > 1, pageSize.height > 1 else { return [] }
        if let cached = cache[chapterIndex] { return cached }
        let ranges = Self.paginate(text, pageSize: pageSize, attributes: attributes)
        cache[chapterIndex] = ranges
        return ranges
    }

    /// 核心分页：Core Text framesetter 循环，把整段文本按可用尺寸逐页切分。
    static func paginate(_ text: String, pageSize: CGSize,
                         attributes: [NSAttributedString.Key: Any]) -> [NSRange] {
        let attr = NSAttributedString(string: text, attributes: attributes)
        guard attr.length > 0, pageSize.width > 1, pageSize.height > 1 else { return [] }
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: CGRect(origin: .zero, size: pageSize), transform: nil)
        var ranges: [NSRange] = []
        var start = 0
        let total = attr.length
        // 防死循环：每页至少前进 1 个字符
        while start < total {
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length <= 0 {
                // 一页都放不下（极小尺寸）→ 兜底放一页
                if ranges.isEmpty { ranges.append(NSRange(location: start, length: total - start)) }
                break
            }
            ranges.append(NSRange(location: start, length: visible.length))
            start += visible.length
        }
        if ranges.isEmpty {
            ranges.append(NSRange(location: 0, length: total))
        }
        return ranges
    }

    /// 章内字符 offset → 页下标（offset 所在页；越界钳制）。
    static func pageIndex(for offset: Int, in ranges: [NSRange]) -> Int {
        guard !ranges.isEmpty else { return 0 }
        let target = max(0, offset)
        for i in 0..<ranges.count {
            if target < ranges[i].location + ranges[i].length { return i }
        }
        return ranges.count - 1
    }
}

/// 单页文本渲染视图：Core Text 直接绘制一个字符切片。
/// 内容区与分页 `pageSize` 对齐（用相同的 contentInsets），保证「所见即所分」。
final class CoreTextPageView: UIView {
    /// 本页显示的富文本（已按页 range 切好的子串）
    var attrString: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }
    /// 内容内边距（与 ChapterPaginator 分页 pageSize 的扣除量一致）
    var contentInsets: UIEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 40, right: 20)

    override func draw(_ rect: CGRect) {
        guard let attr = attrString,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        // Core Text 坐标系：翻转 Y，使 y 向下为正（UIKit 惯例）
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        // 内容区（翻转后 y 从底部起算：bottom 边距在 y 小端）
        let contentRect = CGRect(
            x: contentInsets.left,
            y: contentInsets.bottom,
            width: bounds.width - contentInsets.left - contentInsets.right,
            height: bounds.height - contentInsets.top - contentInsets.bottom
        )
        let path = CGPath(rect: contentRect, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, attr.length), path, nil)
        CTFrameDraw(frame, ctx)
    }
}
