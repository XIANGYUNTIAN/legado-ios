import Foundation
import SwiftSoup

// MARK: - 抽取器（对应 legado Element 取值方式）

/// legado 规则尾部的抽取器关键字。
/// `attr(String)` 承载任意属性名（如 `a[data-bid]@data-bid`、`@onclick`）——
/// legado 对未知关键字按属性名处理，这里显式建模。
enum HtmlExtractor {
    case text
    case html
    case ownText
    case allText
    case textNodes
    case href
    case src
    case srcset
    case dataSrc
    case className
    case id
    case tag
    case alt
    case title
    case attr(String)

    /// 关键字 → 抽取器。与 legado help/JsEncodeUtils 的常用取值对齐。
    static let table: [String: HtmlExtractor] = [
        "text": .text,
        "html": .html,
        "owntext": .ownText,
        "own_text": .ownText,
        "alltext": .allText,
        "all_text": .allText,
        "textnodes": .textNodes,
        "text_nodes": .textNodes,
        "href": .href,
        "src": .src,
        "srcset": .srcset,
        "data-src": .dataSrc,
        "datasrc": .dataSrc,
        "data_src": .dataSrc,
        "class": .className,
        "classname": .className,
        "id": .id,
        "tag": .tag,
        "tagname": .tag,
        "alt": .alt,
        "title": .title,
    ]

    /// 已知关键字判断（不含任意属性名路径）
    static func keyword(_ word: String) -> HtmlExtractor? {
        table[word.lowercased()]
    }
}

// MARK: - 翻译错误

enum CssTranslateError: LocalizedError {
    case emptyRule
    case invalidSegment(String)
    case selectError(String)

    var errorDescription: String? {
        switch self {
        case .emptyRule:
            return "CSS 规则串为空"
        case .invalidSegment(let segment):
            return "无法解析的 CSS 规则段：\(segment)"
        case .selectError(let selector):
            return "CSS 选择器无效：\(selector)"
        }
    }
}

// MARK: - 翻译结果

/// legado CSS 规则 → SwiftSoup 可执行选择器链 + 段级后处理 + 抽取器。
///
/// legado 规则段按 `@` 切分，每段是一个选择器（可带索引/排除/范围后缀），
/// 最后一段可能是抽取器关键字或属性名。段与段之间是「在上一步结果内选择」的链式语义。
struct CssTranslation {
    struct Segment {
        /// SwiftSoup 选择器；空串表示无选择器（仅后处理，如 `children[0]` 或前导空段）
        var selector: String = ""
        /// 段级后处理（按顺序应用）
        var ops: [PostOp] = []
    }

    enum PostOp {
        /// 取第 n 个（负索引从末尾计）
        case take(Int)
        /// 排除第 n 个（负索引从末尾计）
        case exclude(Int)
        /// `[a:b]` 范围切片；a > b 时按倒序（覆盖 legado `[-1:0]` 倒序取法）
        case range(Int, Int)
        /// `children[n]`：取当前元素集的子元素第 n 个
        case children(Int)
    }

    var segments: [Segment] = []
    var extractor: HtmlExtractor = .text
    /// 是否显式指定了抽取器（决定无选择器时能否直接对当前元素取值）
    var hasExplicitExtractor = false
    /// 是否只有抽取器、没有任何选择器（如 `@text` / `text` / `@onclick`）
    var isExtractorOnly: Bool {
        segments.allSatisfy { $0.selector.isEmpty && $0.ops.isEmpty } && hasExplicitExtractor
    }
}

// MARK: - 翻译器

enum LegadoCssTranslator {

    // MARK: 段内后缀识别

    /// `.N` / `.-N` 索引后缀
    private static let indexSuffix = try? NSRegularExpression(
        pattern: "^(.*)\\.(-?\\d+)$", options: []
    )
    /// `!N` / `!-N` 排除后缀
    private static let excludeSuffix = try? NSRegularExpression(
        pattern: "^(.*)!(-?\\d+)$", options: []
    )
    /// `[a:b]` 范围后缀（a、b 可为负；与 CSS 属性选择器 `[attr]` 按「含冒号」区分）
    private static let rangeSuffix = try? NSRegularExpression(
        pattern: "^(.*)\\[(-?\\d+):(-?\\d+)\\]$", options: []
    )
    /// `children[N]`
    private static let childrenSuffix = try? NSRegularExpression(
        pattern: "^children\\[(-?\\d+)\\]$", options: []
    )

    // MARK: 入口

    /// 翻译 legado CSS 规则体（已剥掉 `@css:` / `@@` 前缀）。
    /// - Parameter forElements: 容器规则（bookList / chapterList）——纯选择器链，无抽取器语义。
    static func translate(_ body: String, forElements: Bool = false) throws -> CssTranslation {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw CssTranslateError.emptyRule }

        var result = CssTranslation()
        let parts = trimmed.components(separatedBy: "@")

        for (index, rawPart) in parts.enumerated() {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { continue }   // 前导空段（如 `@text` 切分后首段为空）

            let isLast = index == parts.count - 1

            // 容器规则：所有段都是选择器
            if forElements {
                result.segments.append(try parseSelectorSegment(part))
                continue
            }

            // 字段规则：最后一段可能是抽取器 / 属性名
            if isLast, let extractor = parseExtractorSegment(part) {
                result.extractor = extractor
                result.hasExplicitExtractor = true
                continue
            }
            result.segments.append(try parseSelectorSegment(part))
        }

        if result.segments.isEmpty && !result.hasExplicitExtractor {
            throw CssTranslateError.emptyRule
        }
        return result
    }

    /// 判断规则是否「看起来不是 CSS」（JSON / 正则 / JS / 模板），翻译前分流用。
    static func looksLikeNonCss(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("@css:") || lower.hasPrefix("@@") { return false }
        if lower.hasPrefix("@xpath:") { return true }
        if lower.hasPrefix("@json:") { return true }
        if lower.hasPrefix("@js:") || lower.hasPrefix("<js>") { return true }
        if lower.hasPrefix("@get:") || lower.hasPrefix("@put:") { return true }
        if t.hasPrefix(":") { return true }   // legado allInOne 正则（`:regex`）
        if t.hasPrefix("$.") || t.hasPrefix("$[") { return true }
        if t.hasPrefix("/") || t.hasPrefix("//") { return true }
        if t.contains("{{") { return true }
        return false
    }

    // MARK: 段解析

    /// 最后一段解析为抽取器：已知关键字 → 关键字抽取器；纯属性名形态（字母数字连字符）→ 属性抽取器。
    private static func parseExtractorSegment(_ part: String) -> HtmlExtractor? {
        if let keyword = HtmlExtractor.keyword(part) { return keyword }
        // 属性名形态：仅 [A-Za-z0-9_-]，且不含选择器特征字符（避免把 `.foo`、`#x`、`tag.a` 当属性）
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if part.rangeOfCharacter(from: allowed.inverted) == nil, !part.isEmpty {
            return .attr(part)
        }
        return nil
    }

    /// 选择器段解析：剥离 `children[N]` / `[a:b]` / `!N` / `.N` 后缀，翻译 `tag./class./id.` 前缀。
    private static func parseSelectorSegment(_ part: String) throws -> CssTranslation.Segment {
        var segment = CssTranslation.Segment()
        var base = part

        // children[N]：整段即 children 后缀，无选择器
        if let m = childrenSuffix?.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
           let n = Int((base as NSString).substring(with: m.range(at: 1))) {
            segment.ops.append(.children(n))
            return segment
        }

        // [a:b] 范围
        if let m = rangeSuffix?.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            let ns = base as NSString
            let a = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let b = Int(ns.substring(with: m.range(at: 3))) ?? 0
            segment.ops.append(.range(a, b))
            base = ns.substring(with: m.range(at: 1))
        }

        // !N 排除
        if let m = excludeSuffix?.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            let ns = base as NSString
            if let n = Int(ns.substring(with: m.range(at: 2))) {
                segment.ops.append(.exclude(n))
                base = ns.substring(with: m.range(at: 1))
            }
        }

        // .N 索引
        if let m = indexSuffix?.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            let ns = base as NSString
            let head = ns.substring(with: m.range(at: 1))
            // 头为空（规则以 ".N" 开头）时不当索引，避免误伤 `.foo` 之类
            if !head.isEmpty, let n = Int(ns.substring(with: m.range(at: 2))) {
                segment.ops.append(.take(n))
                base = head
            }
        }

        // 后缀剥离后可能残留尾点（legado 写法 `tag.p.!-1` 剥离 `!-1` 后剩 `tag.p.`），清理解法
        while base.hasSuffix(".") {
            base = String(base.dropLast())
        }

        segment.selector = translateSelector(base)
        return segment
    }

    /// legado 记法 → 标准 CSS：
    /// - `tag.a` → `a`；`class.foo` → `.foo`；`id.bar` → `#bar`
    /// - 其余（`.foo`、`#x`、`a[data-bid]`、`.a li b`）原样透传
    private static func translateSelector(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("tag.") {
            s = String(s.dropFirst(4))
        } else if s.hasPrefix("class.") {
            s = "." + String(s.dropFirst(6))
        } else if s.hasPrefix("id.") {
            s = "#" + String(s.dropFirst(3))
        }
        return s
    }

    // MARK: 求值

    /// 按翻译结果在根元素内逐段选择，返回最终元素集。
    /// 根可以是 Document（整页）或 Element（per-element）。
    static func elements(_ translation: CssTranslation, root: Element) throws -> [Element] {
        var current: [Element] = [root]
        for segment in translation.segments {
            var next: [Element] = []
            if segment.selector.isEmpty {
                next = current
            } else {
                for element in current {
                    // SwiftSoup select 抛异常时返回空（与现有调用点一致）
                    guard let selected = try? element.select(segment.selector) else { continue }
                    next.append(contentsOf: Array(selected))
                }
            }
            // 去重保序（跨段选择可能重复命中同一节点）
            var seen = Set<ObjectIdentifier>()
            var unique: [Element] = []
            for element in next where seen.insert(ObjectIdentifier(element)).inserted {
                unique.append(element)
            }
            current = unique
            for op in segment.ops {
                current = apply(op, to: current)
            }
            if current.isEmpty { return [] }
        }
        return current
    }

    /// 段级后处理
    static func apply(_ op: CssTranslation.PostOp, to elements: [Element]) -> [Element] {
        switch op {
        case .take(let n):
            guard !elements.isEmpty else { return [] }
            let index = n >= 0 ? n : elements.count + n
            return elements.indices.contains(index) ? [elements[index]] : []
        case .exclude(let n):
            guard !elements.isEmpty else { return [] }
            let index = n >= 0 ? n : elements.count + n
            guard elements.indices.contains(index) else { return elements }
            var result = elements
            result.remove(at: index)
            return result
        case .range(let a, let b):
            guard !elements.isEmpty else { return [] }
            let start = a >= 0 ? a : elements.count + a
            let end = b >= 0 ? b : elements.count + b
            guard start >= 0, start < elements.count, end >= 0, end < elements.count else { return [] }
            if start <= end {
                return Array(elements[start...end])
            }
            // a > b：倒序（legado `[-1:0]` 取法）
            return Array(elements[end...start].reversed())
        case .children(let n):
            guard !elements.isEmpty else { return [] }
            var result: [Element] = []
            for element in elements {
                let children = Array(element.children())
                guard !children.isEmpty else { continue }
                let index = n >= 0 ? n : children.count + n
                if children.indices.contains(index) {
                    result.append(children[index])
                }
            }
            return result
        }
    }
}
