import Foundation
import SwiftSoup

// MARK: - CSS 规则错误

enum CssRuleError: LocalizedError {
    case parseError(String)
    case selectError(String)
    case htmlParseError(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "规则解析错误：\(msg)"
        case .selectError(let sel): return "CSS 选择器无效：\(sel)"
        case .htmlParseError(let msg): return "HTML 解析失败：\(msg)"
        }
    }
}

// MARK: - XPath 引擎

/// 最小可用的 XPath 子集求值器，基于 SwiftSoup 的 Element 树。
///
/// 支持的语法（覆盖 legado 书源常见写法）：
/// - 轴：`/` 子轴，`//` 后代轴（含自身），`following-sibling::` / `preceding-sibling::`，
///   `self::` / `parent::` / `descendant::` / `child::`（显式轴名）
/// - 节点测试：元素名（或 `*`）、`text()`、`node()`、`@attr`
/// - 谓词：`[n]`（负索引从末尾计）、`[last()]`、`[position()=n]`、`[@attr]`、
///   `[@attr="v"]`、`[@attr~="v"]`（词包含）、`contains(@attr,"v")`、`starts-with(@attr,"v")`
///
/// 不支持的语法会抛出 `XPathError.unsupported`，由调用方给出友好提示，不会崩溃。
enum XPathError: LocalizedError {
    case parseError(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "XPath 解析错误：\(msg)"
        case .unsupported(let feat): return "XPath 暂不支持该语法：\(feat)（可改用 @css: 选择器）"
        }
    }
}

final class XPathEvaluator {
    static let shared = XPathEvaluator()

    // MARK: 轴 / 节点测试 / 谓词

    private enum Axis {
        case child
        case descendant
        case followingSibling
        case precedingSibling
        case selfAxis
        case parent
    }

    private enum NodeTest {
        case element(String)   // 元素名或 "*"
        case text
        case attribute(String)
    }

    private enum Predicate {
        case position(Int)
        case last
        case positionEquals(Int)
        case attrExists(String)
        case attrEquals(String, String)
        case attrContainsWord(String, String)
        case attrContains(String, String)
        case attrStartsWith(String, String)
    }

    // MARK: 入口

    /// 对给定 HTML 求值 XPath，返回命中的字符串列表（空数组表示无命中，由调用方转 nil）
    func evaluate(_ path: String, rootHTML: String) throws -> [String] {
        let document = try Self.parseHTML(rootHTML)
        let steps = try Self.parse(path)
        guard let lastStep = steps.last else { return [] }
        let elements = try walk(steps: steps, from: document)
        var output: [String] = []
        for element in elements {
            let value = outputValue(element, test: lastStep.test)
            if !value.isEmpty { output.append(value) }
        }
        return output
    }

    /// 对给定 HTML 求值 XPath，返回元素列表（per-element 容器规则用）
    func elements(_ path: String, rootHTML: String) throws -> [Element] {
        let document = try Self.parseHTML(rootHTML)
        let steps = try Self.parse(path)
        return try walk(steps: steps, from: document)
    }

    /// 按步骤走查，返回最终元素集
    private func walk(steps: [Step], from document: Document) throws -> [Element] {
        var current: [Element] = [document]
        for step in steps {
            var collected: [Element] = []
            for node in current {
                collected.append(contentsOf: candidates(node, axis: step.axis))
            }
            // 去重（// 轴可能产生重复节点），保持原文顺序
            var seen = Set<ObjectIdentifier>()
            var unique: [Element] = []
            for e in collected {
                if seen.insert(ObjectIdentifier(e)).inserted { unique.append(e) }
            }
            // 按节点测试 + 谓词过滤（谓词可引用位置）
            var next: [Element] = []
            let total = unique.count
            for (index, element) in unique.enumerated() {
                guard matchesTest(element, step.test) else { continue }
                let position = index + 1
                guard matchesPredicates(element, step.predicates, position: position, last: total) else { continue }
                next.append(element)
            }
            current = next
        }
        return current
    }

    // MARK: 节点测试匹配

    private func matchesTest(_ element: Element, _ test: NodeTest) -> Bool {
        switch test {
        case .element("*"):
            return true
        case .element(let name):
            return element.tagName().lowercased() == name.lowercased()
        case .text:
            return true
        case .attribute:
            return true
        }
    }

    private func matchesPredicates(_ element: Element, _ predicates: [Predicate], position: Int, last: Int) -> Bool {
        for predicate in predicates {
            switch predicate {
            case .position(let n):
                // 负索引从末尾计（legado 书源常见 `[-1]` 取最后一个）
                let target = n >= 0 ? n : last + n + 1
                if position != target { return false }
            case .last:
                if position != last { return false }
            case .positionEquals(let n):
                if position != n { return false }
            case .attrExists(let name):
                if attr(element, name).isEmpty { return false }
            case .attrEquals(let name, let value):
                if attr(element, name) != value { return false }
            case .attrContainsWord(let name, let value):
                let words = attr(element, name).components(separatedBy: .whitespacesAndNewlines)
                if !words.contains(value) { return false }
            case .attrContains(let name, let value):
                if !attr(element, name).contains(value) { return false }
            case .attrStartsWith(let name, let value):
                if !attr(element, name).hasPrefix(value) { return false }
            }
        }
        return true
    }

    private func outputValue(_ element: Element, test: NodeTest) -> String {
        switch test {
        case .element, .text:
            return ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .attribute(let name):
            return attr(element, name)
        }
    }

    /// `Element.attr` 在 SwiftSoup 中会抛异常，这里统一吞掉并返回空字符串
    private func attr(_ element: Element, _ name: String) -> String {
        (try? element.attr(name)) ?? ""
    }

    // MARK: 轴候选

    private func candidates(_ node: Element, axis: Axis) -> [Element] {
        switch axis {
        case .child:
            return Array(node.children())
        case .descendant:
            var result: [Element] = [node]
            var stack: [Element] = Array(node.children())
            while let element = stack.popLast() {
                result.append(element)
                stack.append(contentsOf: Array(element.children()))
            }
            return result
        case .selfAxis:
            return [node]
        case .parent:
            guard let parent = (try? node.parent()) else { return [] }
            return [parent]
        case .followingSibling:
            return siblings(of: node, after: true)
        case .precedingSibling:
            return siblings(of: node, after: false)
        }
    }

    /// 后续 / 前置兄弟元素（经父元素 children 定位，避免依赖可抛 API）
    private func siblings(of node: Element, after: Bool) -> [Element] {
        guard let parent = (try? node.parent()) else { return [] }
        let children = Array(parent.children())
        guard let index = children.firstIndex(where: { $0 === node }) else { return [] }
        if after {
            return index + 1 < children.count ? Array(children[(index + 1)...]) : []
        }
        return index > 0 ? Array(children[..<index]) : []
    }

    // MARK: HTML 解析

    /// HTML 解析统一入口。防护：
    /// - 空文档直接抛错（SwiftSoup 对空串的边界行为不稳定）；
    /// - 超大文档拒绝（>3MB，畸形/超大文档有栈溢出风险，报错优于崩溃）。
    static func parseHTML(_ html: String) throws -> Document {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw XPathError.parseError("内容为空")
        }
        if trimmed.count > 3_000_000 {
            throw XPathError.parseError("文档过大（\(trimmed.count) 字符，上限 300 万）")
        }
        do {
            return try SwiftSoup.parse(trimmed)
        } catch {
            throw XPathError.parseError(error.localizedDescription)
        }
    }

    // MARK: - 解析器

    private struct Step {
        let axis: Axis
        let test: NodeTest
        let predicates: [Predicate]
    }

    /// 词法分析：按 `/` / `//` 切步，每步 = 轴 + 节点测试 + 若干谓词
    private static func parse(_ path: String) throws -> [Step] {
        let s = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw XPathError.parseError("路径为空") }

        var steps: [Step] = []
        var index = 0
        var axis: Axis = .child
        let chars = Array(s)

        while index < chars.count {
            // 轴标记
            if chars[index] == "/" {
                if index + 1 < chars.count, chars[index + 1] == "/" {
                    axis = .descendant
                    index += 2
                } else {
                    axis = .child
                    index += 1
                }
                // 轴后紧跟 "/" 会再走一次循环（合法：/// 不常见，忽略）
                if index < chars.count, chars[index] == "/" { continue }
                continue
            }

            // 读取节点测试（到 '/' 或 '[' 或结束）
            let testStart = index
            while index < chars.count, chars[index] != "/", chars[index] != "[" {
                index += 1
            }
            let testText = String(chars[testStart..<index]).trimmingCharacters(in: .whitespaces)

            // 显式轴名（`following-sibling::dd` 等）：覆盖由 "/" 推导出的轴
            if let separator = testText.range(of: "::") {
                let axisName = String(testText[..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if let explicit = axisByName(axisName) {
                    axis = explicit
                }
            }
            let bareTest = testText.components(separatedBy: "::").last ?? testText
            let test = try parseNodeTest(bareTest)

            // 读取谓词
            var predicates: [Predicate] = []
            while index < chars.count, chars[index] == "[" {
                let end = try matchingBracket(chars, start: index)
                let inner = String(chars[(index + 1)..<end]).trimmingCharacters(in: .whitespaces)
                predicates.append(try parsePredicate(inner))
                index = end + 1
            }

            steps.append(Step(axis: axis, test: test, predicates: predicates))
            axis = .child
        }

        guard !steps.isEmpty else { throw XPathError.parseError("路径为空") }
        return steps
    }

    private static func axisByName(_ name: String) -> Axis? {
        switch name {
        case "child": return .child
        case "descendant", "descendant-or-self": return .descendant
        case "following-sibling": return .followingSibling
        case "preceding-sibling": return .precedingSibling
        case "self": return .selfAxis
        case "parent": return .parent
        default: return nil
        }
    }

    private static func matchingBracket(_ chars: [Character], start: Int) throws -> Int {
        var index = start + 1
        var inQuote = false
        while index < chars.count {
            let c = chars[index]
            if inQuote {
                if c == "\"" { inQuote = false }
            } else {
                if c == "\"" { inQuote = true }
                else if c == "]" { return index }
            }
            index += 1
        }
        throw XPathError.parseError("谓词未闭合")
    }

    private static func parseNodeTest(_ text: String) throws -> NodeTest {
        if text == "*" { return .element("*") }
        if text == "text()" || text == "node()" { return .text }
        if text.hasPrefix("@") {
            let name = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw XPathError.parseError("属性名为空") }
            return .attribute(name)
        }
        guard !text.isEmpty else { throw XPathError.parseError("节点测试为空") }
        // 元素名：只允许字母、数字、连字符、冒号（命名空间）、下划线、点（含点作元素名）
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-:_.")
        if text.rangeOfCharacter(from: allowed.inverted) != nil {
            throw XPathError.parseError("无法识别的节点测试：\(text)")
        }
        return .element(text)
    }

    private static let positionPredicateRegex = try! NSRegularExpression(pattern: #"^position\(\)\s*=\s*(\d+)$"#)
    private static let attrTildeRegex = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_-]+)\s*~=\s*"([^"]*)"$"#)
    private static let attrEqualsRegex = try! NSRegularExpression(pattern: #"^([A-Za-z0-9_-]+)\s*=\s*"([^"]*)"$"#)
    private static let quoteSet = CharacterSet(charactersIn: "\"'")

    private static func parsePredicate(_ inner: String) throws -> Predicate {
        if inner == "last()" { return .last }
        if let m = positionPredicateRegex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)) {
            let num = Int((inner as NSString).substring(with: m.range(at: 1))) ?? 0
            return .positionEquals(num)
        }
        if let num = Int(inner) { return .position(num) }

        // @attr
        if inner.hasPrefix("@") {
            let rest = String(inner.dropFirst()).trimmingCharacters(in: .whitespaces)
            // @attr~="v"
            if let m = attrTildeRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let name = String((rest as NSString).substring(with: m.range(at: 1)))
                let value = String((rest as NSString).substring(with: m.range(at: 2)))
                return .attrContainsWord(name, value)
            }
            // @attr="v"
            if let m = attrEqualsRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let name = String((rest as NSString).substring(with: m.range(at: 1)))
                let value = String((rest as NSString).substring(with: m.range(at: 2)))
                return .attrEquals(name, value)
            }
            // @attr
            return .attrExists(rest)
        }

        // contains(@attr,"v")
        if inner.hasPrefix("contains(") {
            let args = try extractFunctionArgs(inner)
            guard args.count == 2 else { throw XPathError.parseError("contains 参数错误") }
            let attr = args[0].trimmingCharacters(in: .whitespaces)
            guard attr.hasPrefix("@") else { throw XPathError.parseError("contains 第一个参数需为 @attr") }
            let name = String(attr.dropFirst())
            let value = args[1].trimmingCharacters(in: .whitespaces.union(quoteSet))
            return .attrContains(name, value)
        }

        // starts-with(@attr,"v")
        if inner.hasPrefix("starts-with(") {
            let args = try extractFunctionArgs(inner)
            guard args.count == 2 else { throw XPathError.parseError("starts-with 参数错误") }
            let attr = args[0].trimmingCharacters(in: .whitespaces)
            guard attr.hasPrefix("@") else { throw XPathError.parseError("starts-with 第一个参数需为 @attr") }
            let name = String(attr.dropFirst())
            let value = args[1].trimmingCharacters(in: .whitespaces.union(quoteSet))
            return .attrStartsWith(name, value)
        }

        throw XPathError.parseError("不支持的谓词：\(inner)")
    }

    /// 从 `func(@attr,"v")` 中提取逗号分隔的参数（简单实现：按顶层逗号切分，忽略引号内逗号）
    private static func extractFunctionArgs(_ s: String) throws -> [String] {
        guard let open = s.firstIndex(of: "("),
              let close = s.lastIndex(of: ")"), close > open else {
            throw XPathError.parseError("函数调用格式错误")
        }
        let body = String(s[s.index(after: open)..<close])
        var args: [String] = []
        var current = ""
        var inQuote = false
        for c in body {
            if inQuote {
                if c == "\"" { inQuote = false }
                current.append(c)
            } else {
                if c == "\"" { inQuote = true; current.append(c) }
                else if c == "," { args.append(current); current = "" }
                else { current.append(c) }
            }
        }
        args.append(current)
        return args
    }
}

// MARK: - HTML 规则引擎（CSS / XPath 统一入口）

/// 对 legado 的 @css / @xpath / 默认 CSS 规则做统一求值。
/// CSS 规则经 `LegadoCssTranslator` 翻译为 SwiftSoup 选择器链后执行，
/// 覆盖 legado 扩展语法：`tag.a.0`、`class.foo.-1`、`a!0`、`a[-1:0]`、`@children[n]`。
final class HtmlRuleEngine {
    static let shared = HtmlRuleEngine()

    /// 剥离 `@css:` / `@@` 前缀
    static func stripCssPrefix(_ rule: String) -> String {
        var body = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("@css:") {
            body = String(body.dropFirst(5))
        } else if body.hasPrefix("@@") {
            body = String(body.dropFirst(2))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: CSS

    /// 字段规则求值（整页）：选择器链 + 抽取器，返回字符串列表（无命中返回空数组）。
    func evaluateCss(_ body: String, rootHTML: String) throws -> [String] {
        let document = try XPathEvaluator.parseHTML(rootHTML)
        return try Self.evaluateFieldRule(Self.stripCssPrefix(body), root: document)
    }

    /// 容器规则求值（整页）：返回元素列表（bookList / chapterList 用）。
    /// 规则可为 `@css:` / `@@` 前缀或裸 legado 选择器链，支持 && / || / %% 组合子。
    func elements(_ legadoRule: String, rootHTML: String) throws -> [Element] {
        let body = Self.stripCssPrefix(legadoRule)
        let document = try XPathEvaluator.parseHTML(rootHTML)
        return try evaluateElementsChain(body, root: document)
    }

    /// 容器规则求值（元素内）：在指定元素的后代中按规则选元素。
    func elements(_ legadoRule: String, in element: Element) throws -> [Element] {
        let body = Self.stripCssPrefix(legadoRule)
        return try evaluateElementsChain(body, root: element)
    }

    /// 容器规则组合子求值。
    ///
    /// 对齐 `RuleEngine.executeChain` 的 && / || / %% 语义（此前容器规则直接调
    /// `LegadoCssTranslator.translate(forElements:)` 仅按 `@` 切分，组合子被当作非法
    /// 选择器 → 抛错 → 返回 0 元素，是「热门小说恒为 0 命中」的根因）：
    /// - 先按 `&&` 切分，各段「覆盖式」求值（与 legado `getElements` 的 & 段清空覆盖一致）；
    /// - 每段内按 `||` 切分，取首个返回非空元素的备选；
    /// - 备选内若含 `%%`（字段 zip 用，容器极少出现）：元素列表无 zip 语义，取各子段元素并集，避免误判 0 命中。
    ///
    /// 已剥离 `@css:` / `@@` 前缀的 body 传入。单段（无组合子）路径与旧实现完全等价。
    private func evaluateElementsChain(_ rule: String, root: Element) throws -> [Element] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [Element] = []
        var lastError: Error?

        for andPart in RuleSplitter.splitBalanced(trimmed, by: "&&") {
            let andTrim = andPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !andTrim.isEmpty else { continue }

            var partResult: [Element] = []
            var partError: Error?

            for orAlt in RuleSplitter.splitBalanced(andTrim, by: "||") {
                let orTrim = orAlt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !orTrim.isEmpty else { continue }

                let mergeParts = RuleSplitter.splitBalanced(orTrim, by: "%%")
                if mergeParts.count > 1 {
                    // %% 在容器规则中极少出现：元素列表无 zip 语义，取各子段并集。
                    var merged: [Element] = []
                    var mergeError: Error?
                    for mergePart in mergeParts {
                        let mTrim = mergePart.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !mTrim.isEmpty else { continue }
                        do {
                            let sub = try LegadoCssTranslator.translate(mTrim, forElements: true)
                            merged.append(contentsOf: try LegadoCssTranslator.elements(sub, root: root))
                        } catch { mergeError = error }
                    }
                    if !merged.isEmpty {
                        partResult = merged
                        partError = nil
                        break
                    } else if let err = mergeError {
                        partError = err
                    }
                    continue
                }

                do {
                    let sub = try LegadoCssTranslator.translate(orTrim, forElements: true)
                    let els = try LegadoCssTranslator.elements(sub, root: root)
                    if !els.isEmpty {
                        partResult = els
                        partError = nil
                        break
                    }
                } catch {
                    partError = error
                }
            }

            if partResult.isEmpty {
                if let err = partError { lastError = err }
                result = []
            } else {
                result = partResult
                lastError = nil
            }
        }

        if result.isEmpty, let err = lastError {
            throw err
        }
        return result
    }

    /// 字段规则求值（以 root 为上下文）：选择器链 + 抽取器。
    /// root 可以是 Document（整页）或 Element（per-element）。
    static func evaluateFieldRule(_ rule: String, root: Element) throws -> [String] {
        let body = stripCssPrefix(rule)
        let translation = try LegadoCssTranslator.translate(body, forElements: false)
        if translation.isExtractorOnly {
            let value = Self.value(for: root, extractor: translation.extractor)
            return value.isEmpty ? [] : [value]
        }
        let elements = try LegadoCssTranslator.elements(translation, root: root)
        var output: [String] = []
        for element in elements {
            let value = Self.value(for: element, extractor: translation.extractor)
            if !value.isEmpty { output.append(value) }
        }
        return output
    }

    // MARK: XPath

    /// XPath 求值。
    func evaluateXPath(_ path: String, rootHTML: String) throws -> [String] {
        try XPathEvaluator.shared.evaluate(path, rootHTML: rootHTML)
    }

    /// XPath 元素列表求值（per-element 容器规则用）。
    func elementsXPath(_ path: String, rootHTML: String) throws -> [Element] {
        try XPathEvaluator.shared.elements(path, rootHTML: rootHTML)
    }

    // MARK: 取值

    static func value(for element: Element, extractor: HtmlExtractor) -> String {
        switch extractor {
        case .text:
            return (try? element.text()) ?? ""
        case .html:
            return (try? element.outerHtml()) ?? ""
        case .ownText:
            return element.ownText()
        case .allText:
            return (try? element.text()) ?? ""
        case .textNodes:
            var texts: [String] = []
            collectTextNodes(element, into: &texts)
            return texts.joined(separator: "\n")
        case .href:
            return (try? element.attr("href")) ?? ""
        case .src:
            return (try? element.attr("src")) ?? ""
        case .srcset:
            return (try? element.attr("srcset")) ?? ""
        case .dataSrc:
            return (try? element.attr("data-src")) ?? ""
        case .className:
            return (try? element.className()) ?? ""
        case .id:
            return element.id()
        case .tag:
            return element.tagName()
        case .alt:
            return (try? element.attr("alt")) ?? ""
        case .title:
            return (try? element.attr("title")) ?? ""
        case .attr(let name):
            return (try? element.attr(name)) ?? ""
        }
    }

    /// 递归收集所有子孙文本节点（对应 legado @textNodes）
    private static func collectTextNodes(_ element: Element, into output: inout [String]) {
        for node in element.getChildNodes() {
            if let textNode = node as? TextNode {
                let text = textNode.getWholeText()
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    output.append(text)
                }
            } else if let child = node as? Element {
                collectTextNodes(child, into: &output)
            }
        }
    }

    // MARK: 逐元素字段提取

    /// 对单个元素求值规则：CSS（含 legado 扩展语法与 ## 替换）、JSON、正则、JS
    /// 统一走 RuleEngine（以元素为 input、outerHtml 为 content），
    /// 传入的 engine 实例保证变量跨字段共享与 $N 分组上下文。
    static func extractValue(_ rule: String, on element: Element, engine: RuleEngine? = nil) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let fragment = (try? element.outerHtml()) ?? ""
        let targetEngine = engine ?? RuleEngine()
        return ((try? targetEngine.getString(trimmed, content: fragment, input: element)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
