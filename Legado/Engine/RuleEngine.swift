import Foundation
import SwiftSoup
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// legado AnalyzeRule 的 iOS 复刻核心
///
/// 与 Android 原版的对应关系（语义对齐，2026-10-25 按 legado 源码重校准）：
/// - splitSourceRule(_:)          → splitSourceRule（`<js>…</js>` / `@js:…` 任意位置切分）
/// - RuleSplitter.splitBalanced   → RuleAnalyzer.splitRule（&& / || / %% 平衡组切分）
/// - detectMode(_:)               → SourceRule.init（默认 CSS；`@get:`/`{{}}`/`$N` 强制改判 Regex）
/// - substituteTemplate           → makeUpRule（@get / {{}} / $n 回填，先于求值）
/// - applyRule 的 ## 切分          → makeUpRule 尾部切分（rule##replaceRegex##replacement）
/// - applyCssOrXPath              → AnalyzeByJSoup / AnalyzeByXPath（默认 CSS，legado 扩展语法经翻译层）
/// - JsonPath.evaluate            → AnalyzeByJSonPath（JSONPath 子集，含 `..` 递归下降）
/// - applyRegex                   → AnalyzeByRegex（分组提取）
/// - evalJS                       → AnalyzeRule.evalJS（JavaScriptCore + java.* / source / book / cookie 桥）
/// - put(_:_:)                    → AnalyzeRule.put / get
final class RuleEngine {

    // MARK: - 内部状态

    /// 规则变量（@put / @get / java.put / java.get），同一实例跨字段共享
    private var variables: [String: String] = [:]
    /// 最近一次正则求值的分组（$N 回填来源，per-element 时按元素更新）
    private var lastRegexGroups: [String] = []
    /// java.setContent 设置的当前内容（优先级高于调用方传入的 content）
    var jsContent: String?
    /// 最近一次求值使用的 content（java.getElement 用）
    private var lastContent: String = ""

    private let jsBridge = JsJavaBridge()

    #if canImport(JavaScriptCore)
    private var jsContext: JSContext?
    #endif

    init() {
        #if canImport(JavaScriptCore)
        let context = JSContext()
        context?.exceptionHandler = { _, exception in
            if let message = exception?.toString() {
                print("[RuleEngine] JS 异常: \(message)")
            }
        }
        jsBridge.engine = self
        jsBridge.jsContext = context
        context?.setObject(jsBridge, forKeyedSubscript: "java" as NSString)
        jsContext = context
        #endif
    }

    // MARK: - 上下文绑定（搜索 / 目录 / 正文场景注入）

    func setSource(_ source: BookSource?) { jsBridge.source = source }
    func setBook(_ book: Book?) { jsBridge.book = book }
    func setBaseUrl(_ url: String?) { jsBridge.baseUrl = url ?? "" }
    func setChapter(title: String?, nextUrl: String?) {
        jsBridge.chapterTitle = title ?? ""
        jsBridge.nextChapterUrl = nextUrl ?? ""
    }

    // MARK: - 公开 API

    /// 对应 AnalyzeRule.getString
    func getString(_ rule: String, content: String, input: Any? = nil) throws -> String {
        let value = try run(rule, content: content, input: input)
        return try makeUp(stringValue(value), content: content)
    }

    /// 求值规则并返回原始值（String / [String] / 字典 / 数组），供 per-element 分析使用
    func evaluate(_ rule: String, content: String, input: Any? = nil) throws -> Any? {
        try run(rule, content: content, input: input)
    }

    /// 正则规则求值，返回每次匹配的完整分组列表（per-element 用）
    func evaluateRegexMatches(_ pattern: String, content: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = content as NSString
        var result: [[String]] = []
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
            }
            result.append(groups)
        }
        return result
    }

    /// 设置正则分组上下文（per-element 求值时 $N 回填用）
    func setRegexGroups(_ groups: [String]) {
        lastRegexGroups = groups
    }

    /// searchUrl 的 JS 求值（对应 legado AnalyzeUrl.analyzeJs）：
    /// 按 JS_PATTERN 切分，JS 段在绑定 key / page / baseUrl / java / source / result 下求值，
    /// 非 JS 段原样保留，拼接为最终 URL 串。
    func evaluateSearchUrl(_ rule: String, keyword: String, page: Int = 1) throws -> String {
        // result 初始绑定：剥离 JS 标记后的规则串——legado 部分书源（如 69书吧）
        // 写成 `<js>URL,{options};result;</js>`，靠 result 初始值取出 URL
        var stripped = rule
            .replacingOccurrences(of: "<js>", with: "")
            .replacingOccurrences(of: "</js>", with: "")
        if stripped.lowercased().hasPrefix("@js:") {
            stripped = String(stripped.dropFirst(4))
        }
        var output = ""
        for segment in splitSourceRule(rule) {
            switch segment.mode {
            case .js:
                let value = try evalSearchUrlJS(
                    segment.text, keyword: keyword, page: page, initialResult: stripped
                )
                output += stringValue(value)
            default:
                output += segment.text
            }
        }
        return output
    }

    /// 对应 AnalyzeRule.getStringList
    func getStringList(_ rule: String, content: String, input: Any? = nil) throws -> [String] {
        let text = try getString(rule, content: content, input: input)
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// 对应 AnalyzeRule.put
    func put(_ key: String, _ value: String) {
        variables[key] = value
    }

    /// 对应 AnalyzeRule.get
    func get(_ key: String) -> String {
        variables[key] ?? ""
    }

    /// 最近一次求值的内容（java.getElement / 调试用）
    func currentContent() -> String { jsContent ?? lastContent }

    /// java.getElement 最近一次命中的元素（bookList 的 <js> 依赖其副作用时兜底）
    func lastGetElements() -> [Element] {
        jsBridge.lastGetElementResultForJS
    }

    // MARK: - 主流程

    private func run(_ rule: String, content: String, input: Any?) throws -> Any {
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input ?? content
        }
        lastContent = content
        var result: Any? = input
        for segment in splitSourceRule(rule) {
            switch segment.mode {
            case .js:
                // JS 段先做模板回填（legado makeUpRule 对每个 SourceRule 统一执行，
                // $N / @get / {{}} 在 JS 代码中同样生效——起点 chapterUrl 的 `$3` 依赖此行为），
                // 再执行 JS
                let filled = try substituteTemplate(
                    segment.text, input: result, content: content, substituteGroups: true
                )
                result = try evalJS(filled, result: result, content: content)
            default:
                result = try executeChain(segment.text, input: result, content: content)
            }
        }
        guard let result = result else {
            throw RuleError.emptyResult
        }
        return result
    }

    /// 整串切分：`<js>...</js>` 与 `@js:...`（对应 splitSourceRule，任意位置切分）
    private func splitSourceRule(_ rule: String) -> [RuleSegment] {
        // @js: 段改为非贪婪，止于 `,{`（选项后缀）或字符串末尾，避免把 `,{method,body}` 选项吞进 JS 段。
        let pattern = "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*?)(?=,\\{|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [RuleSegment(mode: .plain, text: rule)]
        }
        let nsRule = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: nsRule.length))
        if matches.isEmpty {
            return [RuleSegment(mode: .plain, text: rule)]
        }
        var segments: [RuleSegment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let text = nsRule.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(RuleSegment(mode: .plain, text: text))
                }
            }
            let jsText: String
            if match.range(at: 1).length > 0 {
                jsText = nsRule.substring(with: match.range(at: 1))
            } else {
                jsText = nsRule.substring(with: match.range(at: 2))
            }
            segments.append(RuleSegment(mode: .js, text: jsText))
            cursor = match.range.location + match.range.length
        }
        if cursor < nsRule.length {
            let text = nsRule.substring(
                with: NSRange(location: cursor, length: nsRule.length - cursor)
            )
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(RuleSegment(mode: .plain, text: text))
            }
        }
        return segments
    }

    /// && 链执行（对应 getString 的 splitRule("&&") 主循环）
    private func executeChain(_ text: String, input: Any?, content: String) throws -> Any? {
        var result = input
        for part in RuleSplitter.splitBalanced(text, by: "&&") {
            var partResult: Any?
            for alternative in RuleSplitter.splitBalanced(part, by: "||") {
                let mergeParts = RuleSplitter.splitBalanced(alternative, by: "%%")
                if mergeParts.count > 1 {
                    var lists: [[String]] = []
                    for mergePart in mergeParts {
                        lists.append(stringList(try applyRule(mergePart, input: result, content: content)))
                    }
                    partResult = zipMerge(lists)
                } else {
                    partResult = try applyRule(alternative, input: result, content: content)
                }
                if !isEmptyValue(partResult) {
                    break
                }
            }
            result = partResult
        }
        return result
    }

    /// 单条规则求值（对应 SourceRule + getString 主循环）
    /// 流程：@put 剥离 → 模式识别（原始串）→ ## 切分 + makeUpRule 回填 → 模式求值 → ## 替换
    ///
    /// 与 legado 的关键对应：
    /// - `$N` 回填只作用于 ## 之前的规则段（legado splitRegex 只处理 ruleStrArray[0]）；
    /// - Regex 模式返回回填后的字面量（legado getString 的 `else -> sourceRule.rule`），
    ///   真正的正则提取只发生在容器规则（bookList / chapterList，见 BookListAnalyzer）；
    /// - `##` 替换的 `$1` 走 NSRegularExpression 模板语义（引用 ## 模式自身分组）。
    private func applyRule(_ rule: String, input: Any?, content: String) throws -> Any? {
        var rule = rule
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input ?? content
        }

        // ① @put:{"k":"v"} —— 先剥离并求值存入变量
        let putRules = RuleSplitter.extractPutRules(&rule)
        for putRule in putRules {
            let value = try applyRule(putRule.value, input: input, content: content)
            put(putRule.key, stringValue(value))
        }

        // ② 模式识别（对应 SourceRule.init：先前缀，后 evalMatcher / $N 覆盖）
        let mode = detectMode(rule)

        // ③ ## 切分 + makeUpRule 回填（rule##replaceRegex##replacement[##first]）
        let parts = rule.components(separatedBy: "##")
        let baseRule = try substituteTemplate(
            parts[0], input: input, content: content, substituteGroups: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let replaceRegex: String? = parts.count > 1
            ? try substituteTemplate(parts[1], input: input, content: content, substituteGroups: false)
            : nil
        let replacement: String = parts.count > 2
            ? try substituteTemplate(parts[2], input: input, content: content, substituteGroups: false)
            : ""
        let replaceFirst = parts.count > 3

        if baseRule.isEmpty {
            // 纯替换规则（## 开头）：对 input / content 应用替换
            if let replaceRegex, !replaceRegex.isEmpty {
                return try applyReplacement(
                    input as? String ?? content,
                    pattern: replaceRegex, replacement: replacement,
                    firstOnly: replaceFirst, input: input, content: content
                )
            }
            return input ?? content
        }

        // ④ 按模式求值
        var result: Any?
        switch mode {
        case .js:
            result = try evalJS(baseRule, result: input, content: content)
        case .json:
            result = try applyJson(baseRule, input: input, content: content)
        case .css:
            result = try applyCssOrXPath(baseRule, input: input, content: content)
        case .xpath:
            result = try applyCssOrXPath(baseRule, input: input, content: content)
        case .regex:
            // 对应 legado getString 的 else -> sourceRule.rule：回填后字面量
            result = baseRule
        case .webJs:
            throw RuleError.unsupportedMode("WebJs（后台 WebView）")
        case .plain:
            result = baseRule
        }

        // ⑤ ## 替换（legado replaceRegex）
        if let replaceRegex, !replaceRegex.isEmpty {
            result = try applyReplacement(
                result, pattern: replaceRegex, replacement: replacement,
                firstOnly: replaceFirst, input: input, content: content
            )
        }
        return result
    }

    /// 模式识别（对应 SourceRule.init 的规则串特征判断）
    ///
    /// legado 语义（AnalyzeRule.kt SourceRule.init）：
    /// 1. 前缀初判：@CSS:/@@ → CSS；@XPath: → XPath；@Json: → JSON；$. / $[ → JSON；/ → XPath；
    /// 2. evalMatcher 覆盖：含 @get:{ 或 {{}} 且模式非 Js/Regex、且 {{ 前段不含 ## → **强制 Regex**；
    /// 3. $N 分组引用 → Regex；
    /// 4. 其余：纯字面量 → 字面量；否则 → **CSS（默认模式）**。
    private func detectMode(_ rule: String) -> RuleMode {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // ① 前缀初判
        var mode: RuleMode
        if lower.hasPrefix("@css:") || trimmed.hasPrefix("@@") {
            mode = .css
        } else if lower.hasPrefix("@xpath:") {
            mode = .xpath
        } else if lower.hasPrefix("@json:") {
            mode = .json
        } else if lower.hasPrefix("@js:") || trimmed.hasPrefix("<js>") {
            mode = .js
        } else if trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[") {
            mode = .json
        } else if trimmed.hasPrefix("/") {
            mode = .xpath
        } else if trimmed.hasPrefix(":") {
            // legado allInOne 正则（TocRule 等容器场景；容器规则由 BookListAnalyzer 剥离前缀匹配）
            mode = .regex
        } else {
            mode = .plain
        }

        // ② evalMatcher 覆盖：@get: / {{}} 强制 Regex（优先级高于 $./ / 前缀判定）
        if mode != .js && mode != .regex {
            if let templateStart = firstTemplateStart(trimmed) {
                let prefix = String(trimmed[..<templateStart])
                if templateStart == trimmed.startIndex || !prefix.contains("##") {
                    mode = .regex
                }
            }
        }

        // ③ $N 分组引用 → Regex
        if mode != .js && mode != .regex && containsGroupReference(trimmed) {
            mode = .regex
        }

        // ④ 纯字面量 vs 默认 CSS
        if mode == .plain {
            mode = isPlainLiteral(trimmed) ? .plain : .css
        }
        return mode
    }

    /// 首个 `@get:{` 或 `{{` 的位置
    private func firstTemplateStart(_ rule: String) -> String.Index? {
        var start: String.Index?
        if let range = rule.range(of: "@get:\\{") {
            start = range.lowerBound
        }
        if let range = rule.range(of: "{{"), start == nil || range.lowerBound < start! {
            start = range.lowerBound
        }
        return start
    }

    /// 是否含 `$1`..`$99` 分组引用
    private func containsGroupReference(_ rule: String) -> Bool {
        rule.range(of: "\\$\\d{1,2}", options: .regularExpression) != nil
    }

    /// 纯字面量判断：不含 CSS 语法字符时可作为模板字符串直出
    private func isPlainLiteral(_ rule: String) -> Bool {
        let syntaxCharacters = CharacterSet(charactersIn: ".#@[]>:")
        return rule.rangeOfCharacter(from: syntaxCharacters) == nil
    }

    // MARK: - CSS / XPath 模式（默认 CSS，legado 扩展语法经 LegadoCssTranslator 翻译）

    private func applyCssOrXPath(_ rule: String, input: Any?, content: String) throws -> Any? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("@xpath:") {
            let body = String(trimmed.dropFirst(7))
            return try applyXPath(body, input: input, content: content)
        }
        // 裸 XPath（/ 或 // 开头）——legado 无需前缀标识
        if trimmed.hasPrefix("/") {
            return try applyXPath(trimmed, input: input, content: content)
        }
        // @css: / @@ / 默认 CSS 统一走翻译层
        let body = HtmlRuleEngine.stripCssPrefix(trimmed)
        return try applyCss(body, input: input, content: content)
    }

    private func applyCss(_ body: String, input: Any?, content: String) throws -> Any? {
        // per-element：input 为 Element 时在元素内选择（不含自身，对应 legado Jsoup 语义）
        if let element = input as? Element {
            let results = try HtmlRuleEngine.evaluateFieldRule(body, root: element)
            return results.isEmpty ? nil : results
        }
        let html = cssRoot(input, content: content)
        let results = try HtmlRuleEngine.shared.evaluateCss(body, rootHTML: html)
        return results.isEmpty ? nil : results
    }

    private func applyXPath(_ path: String, input: Any?, content: String) throws -> Any? {
        let html = cssRoot(input, content: content)
        let results = try HtmlRuleEngine.shared.evaluateXPath(path, rootHTML: html)
        return results.isEmpty ? nil : results
    }

    /// CSS / XPath 的求值根：优先使用上一步产出的 HTML 片段 / Element（支持 @html 链式），
    /// 否则使用页面原文 content。
    private func cssRoot(_ input: Any?, content: String) -> String {
        if let element = input as? Element {
            return (try? element.outerHtml()) ?? content
        }
        if let text = input as? String, !text.isEmpty, text.contains("<") {
            return text
        }
        return content
    }

    // MARK: - JSON 模式

    private func applyJson(_ rule: String, input: Any?, content: String) throws -> Any? {
        var path = rule
        if path.lowercased().hasPrefix("@json:") {
            path = String(path.dropFirst(6))
        }
        return JsonPath.evaluate(path, root: jsonRoot(input, content: content))
    }

    private func jsonRoot(_ input: Any?, content: String) -> Any {
        if let dictionary = input as? [String: Any] { return dictionary }
        if let array = input as? [Any] { return array }
        if let text = input as? String {
            if let parsed = parseJSON(text) { return parsed }
            return text
        }
        if let parsed = parseJSON(content) { return parsed }
        return content
    }

    private func parseJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - ## 替换（legado replaceRegex）

    /// `##` 替换：对求值结果应用 replaceRegex（replacement 的 `$1` 引用 ## 模式自身分组）
    private func applyReplacement(_ result: Any?,
                                  pattern: String,
                                  replacement: String,
                                  firstOnly: Bool,
                                  input: Any?,
                                  content: String) throws -> Any? {
        // replacement 只做 @get / {{}} 回填；$N 留给 NSRegularExpression 模板
        // （legado splitRegex 只处理 ## 前的规则段，replacement 的 $1 是正则分组引用）
        let filledReplacement = try substituteTemplate(
            replacement, input: input, content: content, substituteGroups: false
        )
        let groupCount = capturingGroupCount(pattern)
        let template = safeReplacementTemplate(filledReplacement, groupCount: groupCount)

        func replace(_ text: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            if firstOnly, let match = regex.firstMatch(in: text, range: range) {
                return regex.stringByReplacingMatches(
                    in: text, options: [], range: match.range, withTemplate: template
                )
            }
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
        }

        switch result {
        case let text as String:
            return replace(text)
        case let list as [Any]:
            return list.map { replace(stringValue($0)) }
        default:
            return result
        }
    }

    /// 统计正则 pattern 的捕获组数量（用于 $N 引用安全转义）
    private func capturingGroupCount(_ pattern: String) -> Int {
        var count = 0
        var inClass = false
        var escaped = false
        for character in pattern {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if inClass {
                if character == "]" { inClass = false }
                continue
            }
            if character == "[" { inClass = true; continue }
            if character == "(" {
                // 跳过 (?: (?= (?! 等非捕获组
                count += 1
            }
        }
        return max(count - 1, 0)
    }

    /// 转义替换模板中非法的 $ 引用，避免 NSRegularExpression 抛 ObjC 异常
    private func safeReplacementTemplate(_ template: String, groupCount: Int) -> String {
        var output = ""
        let characters = Array(template)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "$" {
                var cursor = index + 1
                var digits = ""
                while cursor < characters.count, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                if let group = Int(digits), group >= 0, group <= groupCount {
                    output += "$\(digits)"
                    index = cursor
                    continue
                }
                output += "$$"
                index += 1
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    // MARK: - JS 模式

    /// 对应 AnalyzeRule.evalJS：绑定 java / source / book / cookie / result / baseUrl / src 等
    private func evalJS(_ js: String, result: Any?, content: String) throws -> Any? {
        #if canImport(JavaScriptCore)
        guard let context = jsContext else {
            throw RuleError.unsupportedMode("js")
        }
        // legado 语义：result 缺省时回退为当前内容（bookList 的 <js> 依赖此行为）
        var resultValue: Any? = result
        if let element = resultValue as? Element {
            resultValue = (try? element.outerHtml()) ?? ""
        }
        if resultValue == nil {
            resultValue = jsContent ?? content
        }
        setupJSContext(context, content: jsContent ?? content, result: resultValue)
        return try evaluateJSInContext(context, js: js)
        #else
        throw RuleError.unsupportedMode("js")
        #endif
    }

    /// searchUrl 的 JS 求值（AnalyzeUrl 场景）：额外绑定 key / page，
    /// result 初值为剥离 JS 标记后的规则串（`<js>URL;result;</js>` 书源依赖）。
    ///
    /// 关键语义：legado 的 searchUrl JS 通常以「末尾赋值 `result=url;`」而非 `return`
    /// 来产出最终 URL。若用 `(function(){ … })()` 包裹，函数体不会隐式返回末尾赋值，
    /// 导致 result 永远为空 → 全源报「链接格式不正确」。因此此处**不包函数体**，
    /// 直接在全局作用域求值，并优先读回 `result` 绑定（与 legado 一致）。
    private func evalSearchUrlJS(_ js: String, keyword: String, page: Int, initialResult: String) throws -> Any? {
        #if canImport(JavaScriptCore)
        guard let context = jsContext else {
            throw RuleError.unsupportedMode("js")
        }
        context.setObject(keyword, forKeyedSubscript: "key" as NSString)
        context.setObject(NSNumber(value: page), forKeyedSubscript: "page" as NSString)
        context.setObject(keyword, forKeyedSubscript: "searchKey" as NSString)
        setupJSContext(context, content: "", result: initialResult)
        let value = context.evaluateScript(js)
        if let exception = context.exception {
            context.exception = nil
            throw RuleError.jsError(exception.toString())
        }
        // 优先返回 `result` 绑定（legado AnalyzeUrl 语义）；否则退回脚本完成值
        if let resultBinding = context.objectForKeyedSubscript("result"),
           !resultBinding.isUndefined, !resultBinding.isNull,
           let text = resultBinding.toString(), !text.isEmpty {
            return text
        }
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString() ?? ""
        #else
        throw RuleError.unsupportedMode("js")
        #endif
    }

    /// 公共 JS 上下文绑定（对应 legado evalJS 的 bindings）
    #if canImport(JavaScriptCore)
    /// legado 书源 searchUrl / bookList 里大量调用的全局函数与对象，需在求值前注入：
    /// - getsurl()  → 书源基准 URL（八叉书库等 searchUrl 用）
    /// - gethd()    → 书源 header 对象（同上）
    /// - webView()  → 已桥接到 java.webView（素书卷过冷却）
    /// - Packages  → Java 包 shim（58小说网用 Packages.java.net.URLDecoder）
    private static let contextHelpers = """
    function getsurl(){ try{ return source.bookSourceUrl; }catch(e){ return ''; } }
    function gethd(){ try{ var h=source.header; if(!h) return {}; return JSON.parse(h); }catch(e){ return {}; } }
    function webView(a,b,c){ try{ return java.webView(b, c); }catch(e){ return ''; } }
    var Packages = { java: { net: { URLDecoder: { decode: function(s){ try{ return decodeURIComponent(s); }catch(e){ return s; } } } } } };
    """

    /// 是否已注入全局辅助函数与 jsLib（每个 JSContext 只注入一次）
    private var didInjectHelpers = false

    private func setupJSContext(_ context: JSContext, content: String, result: Any?) {
        context.setObject(content, forKeyedSubscript: "src" as NSString)
        context.setObject(jsBridge.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(jsBridge.chapterTitle, forKeyedSubscript: "chapter" as NSString)
        context.setObject(jsBridge.chapterTitle, forKeyedSubscript: "title" as NSString)
        context.setObject(jsBridge.nextChapterUrl, forKeyedSubscript: "nextChapterUrl" as NSString)
        if let sourceProxy = jsBridge.sourceProxyForJS {
            context.setObject(sourceProxy, forKeyedSubscript: "source" as NSString)
        }
        if let bookProxy = jsBridge.bookProxyForJS {
            context.setObject(bookProxy, forKeyedSubscript: "book" as NSString)
        }
        context.setObject(jsBridge.cookieProxyForJS, forKeyedSubscript: "cookie" as NSString)

        // 注入全局辅助函数 + 书源 jsLib（首次求值才注入，避免重复）
        if !didInjectHelpers {
            context.evaluateScript(Self.contextHelpers)
            if let jsLib = jsBridge.jsLib, !jsLib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.evaluateScript(jsLib)
            }
            didInjectHelpers = true
        }

        if let text = result as? String {
            context.setObject(text, forKeyedSubscript: "result" as NSString)
        } else if let list = result as? [String] {
            context.setObject(list as NSArray, forKeyedSubscript: "result" as NSString)
        } else if result == nil {
            context.setObject(NSNull(), forKeyedSubscript: "result" as NSString)
        } else {
            context.setObject(String(describing: result!), forKeyedSubscript: "result" as NSString)
        }
    }

    private func evaluateJSInContext(_ context: JSContext, js: String) throws -> Any? {
        let value = context.evaluateScript("(function(){ \(js) })()")
        if let exception = context.exception {
            context.exception = nil
            throw RuleError.jsError(exception.toString())
        }
        guard let value = value, !value.isUndefined, !value.isNull else {
            return nil
        }
        return value.toString() ?? ""
    }
    #endif

    // MARK: - 模板回填（对应 makeUpRule）

    /// substituteGroups = true 时替换 $1..$99（makeUpRule 语义，先于求值）
    private func substituteTemplate(_ template: String,
                                    input: Any?,
                                    content: String,
                                    substituteGroups: Bool) throws -> String {
        var output = template
        var guardCount = 0

        // @get:{key}
        while let range = output.range(of: "@get:\\{[^}]+?\\}", options: .regularExpression) {
            let token = String(output[range])
            let key = token
                .replacingOccurrences(of: "@get:{", with: "")
                .replacingOccurrences(of: "}", with: "")
            output.replaceSubrange(range, with: get(key))
            guardCount += 1
            if guardCount > 50 { break }
        }

        // {{js}} 或 {{嵌套规则}}
        guardCount = 0
        while let range = output.range(of: "\\{\\{[\\w\\W]*?\\}\\}", options: .regularExpression) {
            let token = String(output[range])
            let inner = String(token.dropFirst(2).dropLast(2))
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement: String
            if trimmed.hasPrefix("@") || trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[") || trimmed.hasPrefix("//") {
                // 嵌套规则：带 input 求值（per-element 时按元素回填）
                replacement = try getString(trimmed, content: content, input: input)
            } else {
                replacement = stringValue(try evalJS(inner, result: input, content: content))
            }
            output.replaceSubrange(range, with: replacement)
            guardCount += 1
            if guardCount > 50 { break }
        }

        // $1..$99 正则分组回填（makeUpRule：result 为 List 时按分组回填；
        // per-element 场景由调用方维护 lastRegexGroups）
        if substituteGroups, let regex = try? NSRegularExpression(pattern: "\\$\\d{1,2}") {
            let matches = regex.matches(in: output, range: NSRange(location: 0, length: (output as NSString).length))
            for match in matches.reversed() {
                let current = output as NSString
                let range = match.range
                let token = current.substring(with: range)
                if let index = Int(String(token.dropFirst())), index < lastRegexGroups.count {
                    output = current.replacingCharacters(in: range, with: lastRegexGroups[index])
                }
            }
        }
        return output
    }

    private func makeUp(_ result: String, content: String) throws -> String {
        try substituteTemplate(result, input: nil, content: content, substituteGroups: true)
    }

    // MARK: - 值转换工具

    private func stringValue(_ value: Any?) -> String {
        switch value {
        case nil:
            return ""
        case is NSNull:
            return ""
        case let text as String:
            return text
        case let element as Element:
            return (try? element.outerHtml()) ?? ""
        case let list as [Any]:
            return list.map { stringValue($0) }.joined(separator: "\n")
        case let dictionary as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: dictionary)
        case let number as NSNumber:
            return number.stringValue
        default:
            return String(describing: value)
        }
    }

    private func stringList(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.map { stringValue($0) } }
        let text = stringValue(value)
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    private func isEmptyValue(_ value: Any?) -> Bool {
        switch value {
        case nil:
            return true
        case let text as String:
            return text.isEmpty
        case let list as [Any]:
            return list.isEmpty
        default:
            return false
        }
    }

    /// %% 交错合并：多个列表按索引拼接（对应 legado 的 zip 合并）
    private func zipMerge(_ lists: [[String]]) -> [String] {
        guard !lists.isEmpty else { return [] }
        let count = lists.map { $0.count }.max() ?? 0
        var output: [String] = []
        for index in 0..<count {
            let merged = lists.map { list in
                list.indices.contains(index) ? list[index] : ""
            }.joined()
            output.append(merged)
        }
        return output
    }
}
