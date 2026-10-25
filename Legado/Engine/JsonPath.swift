import Foundation

/// JSONPath 子集求值（对应 Android 端 AnalyzeByJSonPath 的常用能力）
/// 支持：$.a.b / $.a[0] / $.a[*] / $['a']["b"] / $.a[*].b / $..a（递归下降）/ $..a[0]
enum JsonPath {

    static func evaluate(_ path: String, root: Any) -> Any? {
        var rest = Substring(path)
        if rest.hasPrefix("$") {
            rest = rest.dropFirst()
        }
        var current: [Any] = [root]

        while !rest.isEmpty {
            // `..` 递归下降：$..key —— 收集当前节点集合中所有层级下的 key 值
            if rest.hasPrefix("..") {
                rest = rest.dropFirst(2)
                if rest.hasPrefix(".") { rest = rest.dropFirst() }
                var name = ""
                while let character = rest.first, character != ".", character != "[" {
                    name.append(character)
                    rest = rest.dropFirst()
                }
                if name.isEmpty { return nil }
                current = current.flatMap { collect($0, key: name) }
                continue
            }
            if rest.hasPrefix(".") {
                rest = rest.dropFirst()
                if rest.isEmpty { break }
            }
            if rest.hasPrefix("[") {
                guard let close = rest.firstIndex(of: "]") else { return nil }
                let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
                if inner == "*" {
                    current = current.flatMap { element -> [Any] in
                        element as? [Any] ?? []
                    }
                } else if let index = Int(inner), index >= 0 {
                    current = current.compactMap { element -> Any? in
                        guard let list = element as? [Any], index < list.count else { return nil }
                        return list[index]
                    }
                } else {
                    let key = inner.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    current = current.compactMap { element -> Any? in
                        (element as? [String: Any])?[key]
                    }
                }
            } else {
                var name = ""
                while let character = rest.first, character != ".", character != "[" {
                    name.append(character)
                    rest = rest.dropFirst()
                }
                if name.isEmpty { return nil }
                current = current.compactMap { element -> Any? in
                    (element as? [String: Any])?[name]
                }
            }
        }

        if current.isEmpty { return nil }
        if current.count == 1 { return current[0] }
        return current
    }

    /// 递归收集 node 所有层级（含自身）中键为 key 的值，保持文档序
    private static func collect(_ node: Any, key: String) -> [Any] {
        var result: [Any] = []
        func walk(_ n: Any) {
            if let dict = n as? [String: Any] {
                if let value = dict[key] { result.append(value) }
                for (_, value) in dict { walk(value) }
            } else if let array = n as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(node)
        return result
    }
}
