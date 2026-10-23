import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// legado AnalyzeRule 的 iOS 复刻核心（P0：JSON / 正则 / JS 三种模式）
///
/// 与 Android 原版的对应关系：
/// - splitSourceRule(_:)          → splitSourceRule（切出 `<js>` / `@js:` 段）
/// - RuleSplitter.splitBalanced   → RuleAnalyzer.splitRule（&& / || / %% 平衡组切分）
/// - JsonPath.evaluate            → AnalyzeByJSonPath（JSONPath 子集）
/// - applyRegex                   → AnalyzeByRegex（分组提取 + ## 替换）
/// - evalJS                       → AnalyzeRule.evalJS（JavaScriptCore + java.* 桥）
/// - substituteTemplate           → makeUpRule（@get / {{}} / $n 回填）
/// - put(_:_:)                    → AnalyzeRule.put / get
///
/// CSS / XPath 模式依赖 HTML 解析（SwiftSoup），留待 P1 开放；
/// 触达这些模式时会抛出带说明的 unsupportedMode 错误。
final class RuleEngine {

    // MARK: - 内部状态

    private var variables: [String: String] = [:]
    private var lastRegexGroups: [String] = []
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
        context?.setObject(jsBridge, forKeyedSubscript: "java" as NSString)
        jsContext = context
        #endif
    }

    // MARK: - 公开 API

    /// 对应 AnalyzeRule.getString
    func getString(_ rule: String, content: String) throws -> String {
        let value = try run(rule, content: content)
        return try makeUp(stringValue(value), content: content)
    }

    /// 对应 AnalyzeRule.getStringList
    func getStringList(_ rule: String, content: String) throws -> [String] {
        let text = try getString(rule, content: content)
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    /// 对应 AnalyzeRule.put
    func put(_ key: String, _ value: String) {
        variables[key] = value
    }

    private func get(_ key: String) -> String? {
        variables[key]
    }

    // MARK: - 主流程

    private func run(_ rule: String, content: String) throws -> Any {
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        var result: Any?
        for segment in splitSourceRule(rule) {
            switch segment.mode {
            case .js:
                result = try evalJS(segment.text, result: result, content: content)
            default:
                result = try executeChain(segment.text, input: result, content: content)
            }
        }
        guard let result = result else {
            throw RuleError.emptyResult
        }
        return result
    }

    /// 整串切分：`<js>...</js>` 与 `@js:...`（对应 splitSourceRule）
    private func splitSourceRule(_ rule: String) -> [RuleSegment] {
        let pattern = "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)"
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
                if !text.isEmpty {
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
            if !text.isEmpty {
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

    /// 单条规则求值（对应 SourceRule 各解析器入口）
    private func applyRule(_ rule: String, input: Any?, content: String) throws -> Any? {
        var rule = rule
        if rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input
        }
        if rule.hasPrefix("@@") {
            rule = String(rule.dropFirst(2))
        }

        // ① @put:{"k":"v"} —— 先剥离并求值存入变量
        let putRules = RuleSplitter.extractPutRules(&rule)
        for putRule in putRules {
            let value = try applyRule(putRule.value, input: input, content: content)
            put(putRule.key, stringValue(value))
        }

        // ② 模式识别（对应 SourceRule.init）
        let mode = detectMode(rule)
        switch mode {
        case .js:
            return try evalJS(rule, result: input, content: content)
        case .regex:
            return try applyRegex(rule, input: input, content: content)
        case .json:
            return try applyJson(rule, input: input, content: content)
        case .css:
            throw RuleError.unsupportedMode("CSS（HTML 选择器）")
        case .xpath:
            throw RuleError.unsupportedMode("XPath")
        case .webJs:
            throw RuleError.unsupportedMode("WebJs（后台 WebView）")
        case .plain:
            if rule.contains("@get:") || rule.contains("{{") || isPlainLiteral(rule) {
                return try substituteTemplate(rule, input: input, content: content, substituteGroups: false)
            }
            throw RuleError.unsupportedMode("CSS（HTML 选择器）")
        }
    }

    /// 模式识别（对应 SourceRule.init 的规则串特征判断）
    private func detectMode(_ rule: String) -> RuleMode {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("@css:") { return .css }
        if trimmed.hasPrefix("@@") { return .css }
        if lower.hasPrefix("@xpath:") { return .xpath }
        if lower.hasPrefix("@json:") { return .json }
        if lower.hasPrefix("@js:") { return .js }
        if trimmed.hasPrefix("<js>") { return .js }
        if trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[") { return .json }
        if trimmed.hasPrefix("/") { return .xpath }
        if (trimmed.contains("@get:") || trimmed.contains("{{")) && !trimmed.contains("##") {
            return .regex
        }
        return .plain
    }

    /// 纯字面量判断：不含 CSS 语法字符时可作为模板字符串直出
    private func isPlainLiteral(_ rule: String) -> Bool {
        let syntaxCharacters = CharacterSet(charactersIn: ".#@[]>")
        return rule.rangeOfCharacter(from: syntaxCharacters) == nil
    }

    // MARK: - JSON 模式

    private func applyJson(_ rule: String, input: Any?, content: String) throws -> Any? {
        var path = rule
        if path.lowercased().hasPrefix("@json:") {
            path = String(path.dropFirst(6))
        }
        path = try substituteTemplate(path, input: input, content: content, substituteGroups: false)
        return JsonPath.evaluate(path, root: jsonRoot(input, content: content))
    }

    private func jsonRoot(_ input: Any?, content: String) -> Any {
        if let dictionary = input as? [String: Any] { return dictionary }
        if let array = input as? [Any] { return array }
        if let text = input as? String { return parseJSON(text) ?? text }
        if let parsed = parseJSON(content) { return parsed }
        return content
    }

    private func parseJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - 正则模式

    /// 对应 AnalyzeByRegex：`rule##regex##replacement` 提取/替换，`###` 只替换首个
    private func applyRegex(_ rule: String, input: Any?, content: String) throws -> Any? {
        let parts = rule.components(separatedBy: "##")
        var pattern = parts[0]
        var replacement: String?
        var replaceFirstOnly = false
        if parts.count >= 3 {
            pattern = parts[0]
            let rawReplacement = parts[2]
            if rawReplacement.hasPrefix("#") {
                replaceFirstOnly = true
                replacement = String(rawReplacement.dropFirst())
            } else {
                replacement = rawReplacement
            }
        }
        pattern = try substituteTemplate(pattern, input: input, content: content, substituteGroups: false)
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw RuleError.regexError(pattern)
        }

        let targets = regexTargets(input, content: content)
        var groupLists: [[String]] = []
        var firstGroups: [String] = []
        for target in targets {
            let nsTarget = target as NSString
            let matches = regex.matches(in: target, range: NSRange(location: 0, length: nsTarget.length))
            for match in matches {
                var groups: [String] = []
                for index in 0..<match.numberOfRanges {
                    let range = match.range(at: index)
                    if range.location == NSNotFound {
                        groups.append("")
                    } else {
                        groups.append(nsTarget.substring(with: range))
                    }
                }
                groupLists.append(groups)
                if firstGroups.isEmpty {
                    firstGroups = groups
                }
            }
        }
        lastRegexGroups = firstGroups

        if var template = replacement {
            template = try substituteTemplate(template, input: input, content: content, substituteGroups: false)
            template = safeReplacementTemplate(template, groupCount: max(firstGroups.count - 1, 0))
            var output: [String] = []
            for target in targets {
                let nsTarget = target as NSString
                output.append(regex.stringByReplacingMatches(
                    in: target,
                    options: [],
                    range: NSRange(location: 0, length: nsTarget.length),
                    withTemplate: template
                ))
                if replaceFirstOnly { break }
            }
            return output
        }

        guard !groupLists.isEmpty else {
            return nil
        }
        if groupLists.count == 1 {
            let groups = groupLists[0]
            if groups.count > 1 {
                return Array(groups[1...]).joined(separator: "\n")
            }
            return groups[0]
        }
        return groupLists.map { groups -> String in
            groups.count > 1 ? Array(groups[1...]).joined(separator: "\n") : groups[0]
        }
    }

    private func regexTargets(_ input: Any?, content: String) -> [String] {
        if let list = input as? [String] { return list }
        if let list = input as? [Any] { return list.map { stringValue($0) } }
        if let text = input as? String { return [text] }
        return [content]
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

    /// 对应 AnalyzeRule.evalJS：bindings 暴露 result / src / java
    private func evalJS(_ js: String, result: Any?, content: String) throws -> Any? {
        #if canImport(JavaScriptCore)
        guard let context = jsContext else {
            throw RuleError.unsupportedMode("js")
        }
        context.setObject(content, forKeyedSubscript: "src" as NSString)
        if let text = result as? String {
            context.setObject(text, forKeyedSubscript: "result" as NSString)
        } else if let list = result as? [String] {
            context.setObject(list as NSArray, forKeyedSubscript: "result" as NSString)
        } else if result == nil {
            context.setObject(NSNull(), forKeyedSubscript: "result" as NSString)
        } else {
            context.setObject(String(describing: result!), forKeyedSubscript: "result" as NSString)
        }
        let value = context.evaluateScript("(function(){ \(js) })()")
        if let exception = context.exception {
            context.exception = nil
            throw RuleError.jsError(exception.toString())
        }
        guard let value = value, !value.isUndefined, !value.isNull else {
            return nil
        }
        return value.toString() ?? ""
        #else
        throw RuleError.unsupportedMode("js")
        #endif
    }

    // MARK: - 模板回填（对应 makeUpRule）

    /// substituteGroups = true 时替换 $1..$99（仅用于结果回填，避免污染正则）
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
            output.replaceSubrange(range, with: get(key) ?? "")
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
                replacement = try getString(trimmed, content: content)
            } else {
                replacement = stringValue(try evalJS(inner, result: input, content: content))
            }
            output.replaceSubrange(range, with: replacement)
            guardCount += 1
            if guardCount > 50 { break }
        }

        // $1..$99 正则分组回填（仅结果上下文）
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
