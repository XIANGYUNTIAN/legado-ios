import Foundation

// MARK: - 书源重复检测
//
// 公子 2026-11-06 需求：在书源检测里合并去重检测，重复书源直接选中，
// 自助决定一键删除或部分删除，确保相同的有效书源只保留一个。
//
// 判重口径（保守：宁可漏判，不可误删）：
//   1) bookSourceUrl 是 http(s) 地址时，以「规范化地址」为键：不比较 scheme（http/https
//      视为同一个源）、host 小写、去 www.、去默认端口、去末尾斜杠、去 fragment；
//      query 保留（不同参数的接口不是同一个源）。
//      BookSourceStore.importSources 用**精确字符串相等**去重，所以尾斜杠 / www /
//      http-https / 大小写的差异会留下重复项，这里正好补齐。
//   2) bookSourceUrl 不是 URL（采集类写成「资源采集19」这类名称）时，
//      以「规范化名称 + 首个站点 host」为键，避免把同名但不同站的源误合并。
//   3) 名称相同、站点地址不同，**不判重复**（可能是不同镜像 / 不同规则）。
//
// 每组保留 1 个，优先级：检测可用 > 启用 > 规则完整 > 原始顺序靠前。
// 其余成员标为重复并自动选中；保留项永不因「重复」被选中。
//
// SourceFingerprint 是纯值类型（Sendable）：检测任务里重算分组只传它，
// 不把非 Sendable 的 BookSource 捕获进 @MainActor / Task 闭包。

struct SourceFingerprint: Sendable {
    let id: String
    let name: String
    let key: String
    let enabled: Bool
    let ruleScore: Int
}

struct SourceDuplicateGroup: Identifiable, Sendable {
    let id: String
    /// 展示用组名（站点类为规范化地址，采集类为书源名称）
    let label: String
    /// 保留的书源 bookSourceUrl
    let keepID: String
    let keepName: String
    /// 组内多余的成员（已排除保留项）
    let duplicateIDs: [String]
}

enum SourceDuplicateDetector {
    static func fingerprints(from sources: [BookSource]) -> [SourceFingerprint] {
        sources.map { source in
            SourceFingerprint(
                id: source.bookSourceUrl,
                name: source.bookSourceName.isEmpty
                    ? source.bookSourceUrl : source.bookSourceName,
                key: normalizedKey(source),
                enabled: source.enabled,
                ruleScore: ruleCompleteness(source)
            )
        }
    }

    static func groups(from fingerprints: [SourceFingerprint],
                       health: [String: SourceCheckState]) -> [SourceDuplicateGroup] {
        var buckets: [String: [SourceFingerprint]] = [:]
        for fp in fingerprints {
            buckets[fp.key, default: []].append(fp)
        }
        let result: [SourceDuplicateGroup] = buckets.compactMap { entry -> SourceDuplicateGroup? in
            let key = entry.key
            let members = entry.value
            guard members.count > 1 else { return nil }
            // enumerated 的 offset 作最终 tie-breaker，保证排序结果稳定
            let ordered = members.enumerated().sorted { a, b in
                let pa = priority(a.element, health: health)
                let pb = priority(b.element, health: health)
                if pa != pb { return pa > pb }
                return a.offset < b.offset
            }
            let keeper = ordered[0].element
            return SourceDuplicateGroup(
                id: key,
                label: key.hasPrefix("name:") ? keeper.name : key,
                keepID: keeper.id,
                keepName: keeper.name,
                duplicateIDs: ordered.dropFirst().map { $0.id }
            )
        }
        return result.sorted { $0.label < $1.label }
    }

    /// 保留优先级，数值越大越优先。
    private static func priority(_ fp: SourceFingerprint,
                                 health: [String: SourceCheckState]) -> Int {
        var score = 0
        switch health[fp.id] {
        case .some(.ok): score += 1000
        case .some(.unknown), nil: score += 500
        case .some(.cancelled): score += 400
        case .some(.failed): break
        }
        if fp.enabled { score += 200 }
        score += fp.ruleScore
        return score
    }

    /// 规则完整度：五套规则里非空的数量，重复时优先留规则更全的那份。
    private static func ruleCompleteness(_ source: BookSource) -> Int {
        [source.ruleSearch, source.ruleBookInfo, source.ruleToc,
         source.ruleContent, source.ruleExplore]
            .reduce(0) { $0 + ($1?.isEmpty == false ? 1 : 0) }
    }

    static func normalizedKey(_ source: BookSource) -> String {
        let raw = source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: raw),
           let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let host = comps.host, !host.isEmpty {
            var h = host.lowercased()
            if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
            var path = comps.path
            while path.hasSuffix("/") { path.removeLast() }
            let port: String = {
                guard let p = comps.port else { return "" }
                if (scheme == "http" && p == 80) || (scheme == "https" && p == 443) { return "" }
                return ":\(p)"
            }()
            let query = comps.query.map { "?" + $0.lowercased() } ?? ""
            return "\(h)\(port)\(path.lowercased())\(query)"
        }
        // 非 URL（采集类名称）：名称 + 首个站点 host
        let name = normalizedName(source.bookSourceName.isEmpty ? raw : source.bookSourceName)
        let host = source.siteURLs.first?.host?.lowercased() ?? "no-host"
        return "name:\(host)|\(name)"
    }

    private static func normalizedName(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace }
    }
}
