import Foundation
import SwiftSoup

// MARK: - 影视站点「通用站内搜索」
//
// 公子 2026-11-06 第三轮反馈：搜索页仍出不来视频结果，但进站点浏览器能搜到、能播。
// 截图里「以下书源未返回结果或失败」多数是「链接格式不正确」，其余是规则正常返回
// 但 0 命中——说明第三方影视书源的 ruleSearch 早已和站点改版脱节。
// 前两轮都在调「结果分类启发式」，但只要规则层没产出条目，分类再准也是 0。
//
// 这里绕开规则：用书源自带的 searchUrl（作者写的地址最准）+ 常见 CMS 搜索路径
// 直接请求站内搜索页，然后按两种形态抽结果：
//   ① 采集接口 JSON：vod_name / vod_id → 拼 ?ac=detail&ids=…（▶ 解析 vod_play_url）
//   ② 搜索结果 HTML：锚文本含关键词、href 指向详情页 → ▶ 解析明文直链或回退站内浏览器
// 产出的 ExploredBook 复用搜索页既有的 ▶ 播放链路，点一下即可播。

/// 纯值目标，可安全跨 Task 传递（BookSource 不是 Sendable）。
struct SiteTarget: Sendable {
    let sourceId: String
    let name: String
    let baseURL: String
    let searchTemplate: String?
}

struct SiteSearchHit: Sendable {
    let name: String
    /// 绝对 URL 字符串（用 String 而非 URL，保证 Sendable 无跨版本歧义）
    let url: String
    let sourceId: String
    let sourceName: String
}

enum SiteSearchService {

    static func target(source: BookSource) -> SiteTarget {
        SiteTarget(sourceId: source.bookSourceUrl,
                   name: source.bookSourceName,
                   baseURL: source.siteURLs.first?.absoluteString ?? source.bookSourceUrl,
                   searchTemplate: source.searchUrl)
    }

    /// 「站点直达」用：一键打开站内搜索结果页，不再让用户进首页手动输关键词。
    static func preferredSearchURL(target: SiteTarget, keyword: String) -> URL? {
        let urls = candidateURLs(target: target, keyword: keyword)
        // 采集接口返回的是 JSON，WebView 里只是一坨文本；直达优先落在可见的 HTML 搜索页。
        return urls.first { !$0.absoluteString.lowercased().contains("api.php") } ?? urls.first
    }

    /// 候选搜索页：书源自带 searchUrl 优先，其余为苹果 CMS / 通用影视站常见路径。
    static func candidateURLs(target: SiteTarget, keyword: String) -> [URL] {
        let k = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        guard let base = URLSanitizer.sanitize(target.baseURL),
              let scheme = base.scheme, let host = base.host else { return [] }
        let origin = scheme + "://" + host + (base.port.map { ":\($0)" } ?? "")
        var out: [URL] = []
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let resolved: String
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                resolved = trimmed
            } else {
                resolved = origin + (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
            }
            guard let u = URLSanitizer.sanitize(resolved) else { return }
            if out.contains(where: { $0.absoluteString == u.absoluteString }) { return }
            out.append(u)
        }

        if let tpl = target.searchTemplate, !tpl.isEmpty {
            let lower = tpl.lowercased()
            // @js: / <js> 型地址由 JS 动态构造，无法静态还原，跳过
            if !lower.contains("@js:") && !lower.contains("<js>") && !tpl.contains("\n") {
                var urlPart = tpl
                if let r = urlPart.range(of: ",{") {
                    urlPart = String(urlPart[urlPart.startIndex..<r.lowerBound])
                }
                urlPart = urlPart.trimmingCharacters(in: .whitespacesAndNewlines)
                urlPart = urlPart.replacingOccurrences(of: "{{key}}", with: k)
                urlPart = urlPart.replacingOccurrences(of: "searchKey", with: k)
                urlPart = urlPart.replacingOccurrences(of: "{{searchPage}}", with: "1")
                urlPart = urlPart.replacingOccurrences(of: "searchPage", with: "1")
                urlPart = urlPart.replacingOccurrences(of: "{{", with: "%7B%7B")
                urlPart = urlPart.replacingOccurrences(of: "}}", with: "%7D%7D")
                // 没有关键词占位符的采集接口：补 wd 参数
                if !urlPart.contains(k) && !urlPart.contains(keyword) {
                    urlPart += (urlPart.contains("?") ? "&" : "?") + "wd=" + k
                }
                add(urlPart)
            }
        }

        let common = [
            "/index.php/vod/search.html?wd=" + k,
            "/vodsearch.html?wd=" + k,
            "/search.php?searchword=" + k,
            "/search?keyword=" + k,
            "/?s=" + k
        ]
        for c in common { add(c) }
        return Array(out.prefix(6))
    }

    /// 多站点并行；每站先试自带搜索地址，没命中再并发试常见路径。
    static func search(targets: [SiteTarget], keyword: String) async -> [SiteSearchHit] {
        guard !keyword.isEmpty, !targets.isEmpty else { return [] }
        return await withTaskGroup(of: [SiteSearchHit].self,
                                   returning: [SiteSearchHit].self) { group in
            for t in targets {
                group.addTask { await searchOne(target: t, keyword: keyword) }
            }
            var all: [SiteSearchHit] = []
            for await hits in group { all.append(contentsOf: hits) }
            var seen = Set<String>()
            var out: [SiteSearchHit] = []
            for h in all {
                let key = h.url.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                out.append(h)
            }
            return out
        }
    }

    private static func searchOne(target: SiteTarget, keyword: String) async -> [SiteSearchHit] {
        let urls = candidateURLs(target: target, keyword: keyword)
        guard let first = urls.first else { return [] }
        let firstHits = await fetchHits(url: first, target: target, keyword: keyword)
        if !firstHits.isEmpty { return Array(firstHits.prefix(12)) }
        let rest = Array(urls.dropFirst().prefix(4))
        guard !rest.isEmpty else { return [] }
        return await withTaskGroup(of: [SiteSearchHit].self,
                                   returning: [SiteSearchHit].self) { group in
            for u in rest {
                group.addTask { await fetchHits(url: u, target: target, keyword: keyword) }
            }
            var out: [SiteSearchHit] = []
            for await hits in group {
                for h in hits where !out.contains(where: { $0.url == h.url }) {
                    out.append(h)
                }
            }
            return Array(out.prefix(12))
        }
    }

    private static func fetchHits(url: URL, target: SiteTarget, keyword: String) async -> [SiteSearchHit] {
        let headers = [
            "Referer": target.baseURL,
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        guard let text = try? await NetworkService.shared.fetchText(
            from: url, headers: headers, timeout: 6
        ), !text.isEmpty else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return jsonHits(text: text, pageURL: url, target: target, keyword: keyword)
        }
        return htmlHits(html: text, pageURL: url, target: target, keyword: keyword)
    }

    // MARK: - 采集接口 JSON

    private static func jsonHits(text: String, pageURL: URL, target: SiteTarget,
                                 keyword: String) -> [SiteSearchHit] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [SiteSearchHit] = []
        collectVod(obj, pageURL: pageURL, target: target, keyword: keyword, into: &out, depth: 0)
        return out
    }

    private static func collectVod(_ value: Any, pageURL: URL, target: SiteTarget,
                                   keyword: String, into out: inout [SiteSearchHit], depth: Int) {
        guard depth < 6, out.count < 12 else { return }
        if let arr = value as? [Any] {
            for item in arr {
                collectVod(item, pageURL: pageURL, target: target, keyword: keyword, into: &out, depth: depth + 1)
            }
            return
        }
        guard let dict = value as? [String: Any] else { return }
        let rawName = (dict["vod_name"] as? String) ?? (dict["name"] as? String) ?? ""
        let name = clean(rawName)
        if !name.isEmpty, name.lowercased().contains(keyword.lowercased()),
           let link = detailURL(dict: dict, pageURL: pageURL) {
            out.append(SiteSearchHit(name: name, url: link.absoluteString,
                                     sourceId: target.sourceId, sourceName: target.name))
        }
        for (_, v) in dict where v is [Any] || v is [String: Any] {
            collectVod(v, pageURL: pageURL, target: target, keyword: keyword, into: &out, depth: depth + 1)
        }
    }

    /// 苹果 CMS：`?ac=detail&ids=<vod_id>` 返回单部剧的 vod_play_url，选集最干净。
    private static func detailURL(dict: [String: Any], pageURL: URL) -> URL? {
        let id: String?
        if let s = dict["vod_id"] as? String { id = s }
        else if let n = dict["vod_id"] as? NSNumber { id = n.stringValue }
        else if let n = dict["id"] as? NSNumber { id = n.stringValue }
        else if let s = dict["id"] as? String { id = s }
        else { id = nil }
        guard let id = id, !id.isEmpty,
              var comps = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = (comps.queryItems ?? []).filter {
            !["wd", "ids", "ac", "page", "limit"].contains($0.name.lowercased())
        }
        items.append(URLQueryItem(name: "ac", value: "detail"))
        items.append(URLQueryItem(name: "ids", value: id))
        comps.queryItems = items
        return comps.url
    }

    // MARK: - 搜索结果 HTML

    private static func htmlHits(html: String, pageURL: URL, target: SiteTarget,
                                 keyword: String) -> [SiteSearchHit] {
        guard let doc = try? SwiftSoup.parse(html),
              let links = try? doc.select("a[href]") else { return [] }
        let k = keyword.lowercased()
        var out: [SiteSearchHit] = []
        for a in links {
            guard let href = try? a.attr("href"), !href.isEmpty else { continue }
            let title = clean((try? a.text()) ?? "")
            guard title.count >= 2 else { continue }
            let lowerTitle = title.lowercased()
            guard lowerTitle.contains(k) || (!lowerTitle.isEmpty && k.contains(lowerTitle)) else { continue }
            let h = href.lowercased()
            guard looksLikeDetail(h) else { continue }
            guard let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL,
                  let u = URLSanitizer.sanitize(resolved.absoluteString) else { continue }
            if out.contains(where: { $0.url == u.absoluteString }) { continue }
            out.append(SiteSearchHit(name: title, url: u.absoluteString,
                                     sourceId: target.sourceId, sourceName: target.name))
            if out.count >= 12 { break }
        }
        return out
    }

    private static func looksLikeDetail(_ h: String) -> Bool {
        if h.hasPrefix("javascript") || h == "#" || h.hasPrefix("mailto") { return false }
        let bad = ["/search", "/login", "/register", "/list/", "/type/", "/tag/",
                   "/category/", "/topic/", "/sort/", ".js", ".css", "/upload/"]
        if bad.contains(where: { h.contains($0) }) { return false }
        let hints = ["/vod/", "/detail/", "/video/", "/movie/", "/play/", "/show/",
                     "/d/", "/b/", "/html/", ".html", "id=", "/index.php/vod/"]
        return hints.contains(where: { h.contains($0) })
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 60 { s = String(s.prefix(60)) }
        return s
    }
}
