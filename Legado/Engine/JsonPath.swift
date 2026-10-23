import Foundation

/// JSONPath 子集求值（对应 Android 端 AnalyzeByJSonPath 的常用能力）
/// 支持：$.a.b / $.a[0] / $.a[*] / $['a']["b"] / $.a[*].b / $..a
enum JsonPath {

    static func evaluate(_ path: String, root: Any) -> Any? {
        var rest = Substring(path)
        if rest.hasPrefix("$") {
            rest = rest.dropFirst()
        }
        var current: [Any] = [root]

        while !rest.isEmpty {
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
}
