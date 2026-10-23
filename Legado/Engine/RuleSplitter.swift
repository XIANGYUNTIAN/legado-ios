import Foundation

enum RuleSplitter {

    /// 平衡组 + 引号感知的规则切分（对应 Android 端 RuleAnalyzer.splitRule）
    /// 括号 [] () {} 内与引号内的分隔符不生效。
    static func splitBalanced(_ text: String, by separator: String) -> [String] {
        var parts: [String] = []
        var current = Substring()
        var depth = 0
        var quote: Character? = nil
        var rest = Substring(text)

        while let character = rest.first {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                rest = rest.dropFirst()
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                current.append(character)
            case "[", "(", "{":
                depth += 1
                current.append(character)
            case "]", ")", "}":
                depth = max(0, depth - 1)
                current.append(character)
            default:
                if depth == 0 && rest.hasPrefix(separator) {
                    parts.append(String(current))
                    current = ""
                    rest = rest.dropFirst(separator.count)
                    continue
                }
                current.append(character)
            }
            rest = rest.dropFirst()
        }
        parts.append(String(current))
        return parts
    }

    /// 提取 @put:{"k":"v"} 并从规则串中移除（对应 splitPutRule）
    static func extractPutRules(_ rule: inout String) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        var guardCount = 0
        while let range = rule.range(of: "@put:(\\{[^}]+?\\})", options: .regularExpression) {
            let token = String(rule[range])
            rule.removeSubrange(range)
            let json = String(token.dropFirst(5))
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            if let dict = object as? [String: String] {
                for (key, value) in dict {
                    result.append((key, value))
                }
            } else if let dict = object as? [String: Any] {
                for (key, value) in dict {
                    result.append((key, "\(value)"))
                }
            }
            guardCount += 1
            if guardCount > 50 { break }
        }
        return result
    }
}
