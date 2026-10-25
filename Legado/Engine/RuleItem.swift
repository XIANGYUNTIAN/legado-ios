import Foundation
import SwiftSoup

/// 规则求值的「元素」抽象（对应 legado 的 per-element 语义）：
/// CSS / XPath → 元素节点；正则 → 匹配分组；JSON → 数组成员 / 字典值。
///
/// legado 的 bookList / chapterList 语义：先对容器规则求值得到元素列表，
/// 再以每个元素为上下文逐字段求值（`$N` 分组、`{{$.field}}` 模板按元素回填）。
enum RuleItem {
    case element(Element)
    case regex([String])   // [full, g1, g2, ...]
    case json(Any)         // 字典 / 数组 / 值
}

/// bookList / chapterList 的 per-element 求值（对应 legado BookListAnalyzer / TocAnalyzer）
enum BookListAnalyzer {

    /// 对容器规则求值，产出元素列表。
    /// - Parameters:
    ///   - rule: 容器规则（bookList / chapterList），可为 CSS（默认 / @css: / @@）、
    ///           JSONPath、XPath、正则（`:regex` allInOne）、JS
    ///   - html: 页面内容
    ///   - engine: 共享引擎实例（变量跨字段共享、`$N` 分组按元素维护）
    static func items(rule: String, html: String, engine: RuleEngine) -> [RuleItem] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()

        // ① JS：求值结果按值类型转换（起点 bookList 的 <js> 返回元素 outerHtml 数组）
        if lower.hasPrefix("@js:") || lower.hasPrefix("<js>") {
            if let value = try? engine.evaluate(trimmed, content: html) {
                let items = itemsFromValue(value)
                if !items.isEmpty { return items }
            }
            // JS 未返回元素（legado 起点书源的 bookList <js> 依赖 java.getElement 副作用）：
            // 取桥内最近一次 getElement 命中
            let cached = engine.lastGetElements()
            if !cached.isEmpty { return cached.map { .element($0) } }
            return []
        }

        // ② CSS（默认模式 / @css: / @@）：元素列表
        if !LegadoCssTranslator.looksLikeNonCss(trimmed) {
            guard let elements = try? HtmlRuleEngine.shared.elements(trimmed, rootHTML: html) else {
                return []
            }
            return elements.map { .element($0) }
        }

        // ③ JSON：结构化值 → 数组成员逐项
        if lower.hasPrefix("@json:") || trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[") {
            guard let value = try? engine.evaluate(trimmed, content: html) else { return [] }
            return itemsFromValue(value)
        }

        // ④ XPath：元素列表
        if trimmed.hasPrefix("/") || lower.hasPrefix("@xpath:") {
            let path = lower.hasPrefix("@xpath:") ? String(trimmed.dropFirst(7)) : trimmed
            guard let elements = try? HtmlRuleEngine.shared.elementsXPath(path, rootHTML: html) else {
                return []
            }
            return elements.map { .element($0) }
        }

        // ⑤ 正则（`:regex` allInOne 或含正则特征）：匹配分组逐项
        var pattern = trimmed
        if pattern.hasPrefix(":") {
            pattern = String(pattern.dropFirst(1))
        }
        return engine.evaluateRegexMatches(pattern, content: html).map { .regex($0) }
    }

    /// 对单个元素求值字段规则。
    /// - Parameter rule: 字段规则（name / author / bookUrl / chapterName ...）
    /// - Returns: 字段值（空串表示未命中）
    static func field(_ rule: String?, item: RuleItem, engine: RuleEngine) -> String {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        switch item {
        case .element(let element):
            return HtmlRuleEngine.extractValue(rule, on: element, engine: engine)
        case .regex(let groups):
            engine.setRegexGroups(groups)
            // 裸抽取器（text / html / ownText ...）直接作用于匹配全文
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            if !LegadoCssTranslator.looksLikeNonCss(trimmed),
               let extractor = HtmlExtractor.keyword(trimmed) {
                switch extractor {
                case .text, .allText, .html, .ownText, .textNodes:
                    return groups.first ?? ""
                default:
                    break
                }
            }
            return (try? engine.getString(rule, content: groups.first ?? "")) ?? ""
        case .json(let value):
            let content = jsonText(value)
            return (try? engine.getString(rule, content: content, input: value)) ?? ""
        }
    }

    /// JSON 值的文本形式（规则以 content 为求值根时使用）
    static func jsonText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    /// 求值结果 → 元素列表。数组字符串中含 HTML 片段时解析为元素
    /// （legado 的 java.getElement 返回 Elements，iOS 桥返回 outerHtml 数组）。
    private static func itemsFromValue(_ value: Any?) -> [RuleItem] {
        guard let value else { return [] }
        if let array = value as? [Any] {
            return array.flatMap { itemsFromValue($0) }
        }
        if let dictionary = value as? [String: Any] {
            return [.json(dictionary)]
        }
        if let strings = value as? [String] {
            return strings.flatMap { itemsFromValue($0) }
        }
        if let text = value as? String, !text.isEmpty {
            if text.contains("<"), let element = elementFromHTMLFragment(text) {
                return [.element(element)]
            }
            return [.json(text)]
        }
        return []
    }

    /// HTML 片段 → 根元素（取 body 第一个子元素）
    static func elementFromHTMLFragment(_ html: String) -> Element? {
        guard let document = try? SwiftSoup.parse(html),
              let body = document.body() else {
            return nil
        }
        return Array(body.children()).first
    }
}
