import Foundation
import SwiftSoup

// MARK: - 影视站点「通用站内搜索」
//
// v47：公子第四轮反馈 v46 仍 0 结果，但点「站点直达」在网页里能搜到、能播。
// 复查确认三处确定性缺陷（都不是「分类」问题）：
//   ① siteTargets 按书源名称排序取前 10，720 源里真正可用的「黄果剧场」被
//      一堆 📺 / 资源采集站挤出，站内搜索查的全是别的站；
//   ② 站点类书源 bookSourceUrl 是中文名，siteURLs.first 取的是 comment 里
//      第一个采集 API 域名，拼 CMS 搜索路径必然 404；应遍历全部候选域名；
//   ③ 搜索结果由页面 JS 渲染 / 非 WebView 请求被拦截，纯 HTTP 抓 HTML 永远
//      拿不到链接。用隐藏 WKWebView 渲染后读 DOM（v44 漫画已真机验证）。
//
// 另外：即使一个站都没抽出剧名，也给出「可直接点开的站内搜索结果页」结果行，
// 保证搜索页不是空的，且点的就是用户已验证能播的那条路径。

/// 纯值目标，可安全跨 Task 传递（BookSource 不是 Sendable）。
struct SiteTarget: Sendable {
    let sourceId: String
    let name: String
    /// 兼容旧调用：候选站点根里的第一个
    let baseURL: String
    /// 书源 comment / searchUrl 里出现的全部站点根，逐个尝试
    let baseURLs: [String]
    let searchTemplate: String?
}

struct SiteSearchHit: Sendable {
    let name: String
    /// 绝对 URL 字符串（用 String 而非 URL，保证 Sendable 无跨版本歧义）
    let url: String
    let sourceId: String
    let sourceName: String
}

/// 每站 HTTP 抓取结果 + 该站可用于 WebView 兜底的页面地址
private struct SiteOneResult: Sendable {
    let sourceId: String
    let name: String
    let hits: [SiteSearchHit]
    let domURL: String?
}

/// 逐站诊断：搜索页可见，下一轮一张截图就能定位是哪个站、哪一步失败
struct SiteSearchReport: Sendable {
    let hits: [SiteSearchHit]
    let lines: [String]
}

enum SiteSearchService {

    static func target(source: BookSource) -> SiteTarget {
        let urls = source.siteURLs.map { $0.absoluteString }
        let all = urls.isEmpty ? [source.bookSourceUrl] : Array(urls.prefix(4))
        return SiteTarget(sourceId: source.bookSourceUrl,
                          name: source.bookSourceName,
                          baseURL: all.first ?? source.bookSourceUrl,
                          baseURLs: all,
                          searchTemplate: source.searchUrl)
    }

    /// 「站点直达」用：一键打开站内搜索结果页，不再让用户进首页手动输关键词。
    static func preferredSearchURL(target: SiteTarget, keyword: String) -> URL? {
        let urls = candidateURLs(target: target, keyword: keyword)
        // 采集接口返回的是 JSON，WebView 里只是一坨文本；直达优先落在可见的 HTML 搜索页。
        return urls.first { !$0.absoluteString.lowercased().contains("api.php") } ?? urls.first
    }

    /// 候选搜索页：书源自带 searchUrl 优先，其余为苹果 CMS / 通用影视站常见路径。
    /// 对「bookSourceUrl 是中文名」的采集类源，逐个尝试 comment 里的候选域名。
    static func candidateURLs(target: SiteTarget, keyword: String) -> [URL] {
        let k = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        var out: [URL] = []
        var origins: [String] = []
        for raw in target.baseURLs {
            guard let base = URLSanitizer.sanitize(raw),
                  let scheme = base.scheme, let host = base.host else { continue }
            let origin = scheme + "://" + host + (base.port.map { ":\($0)" } ?? "")
            if !origins.contains(origin) { origins.append(origin) }
        }
        guard !origins.isEmpty else { return [] }
        let primary = origins[0]

        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let resolved: String
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                resolved = trimmed
            } else {
                resolved = primary + (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
            }
            guard let u = URLSanitizer.sanitize(resolved) else { return }
            if out.contains(where: { $0.absoluteString == u.absoluteString }) { return }
            out.append(u)
        }

        if let tpl = target.searchTemplate, !tpl.isEmpty {
            let lower = tpl.lowercased()
            if lower.contains("@js:") || lower.contains("<js>") {
                // @js: 型采集接口：JS 拼出的地址无法静态还原，但路径形态明确，
                // 按苹果 CMS 采集协议直接构造（样本实证：?ac=detail&wd=）。
                if lower.contains("api.php/provide/vod") {
                    add("/api.php/provide/vod/?ac=detail&wd=" + k)
                    add("/api.php/provide/vod/?ac=list&wd=" + k)
                }
            } else if !tpl.contains("\n") {
                var urlPart = tpl
                if let r = urlPart.range(of: ",{") {
                    urlPart = String(urlPart[urlPart.startIndex..<r.lowerBound])
                }
                urlPart = urlPart.trimmingCharacters(in: .whitespacesAndNewlines)
                urlPart = urlPart.replacingOccurrences(of: "{{key}}", with: k)
                urlPart = urlPart.replacingOccurrences(of: "searchKey", with: k)
                urlPart = urlPart.replacingOccurrences(of: "{{searchPage}}", with: "1")
                urlPart = urlPart.replacingOccurrences(of: "searchPage", with: "1")
                urlPart = urlPart.replacingOccurrences(of: "{{page}}", with: "1")
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

        // 其余候选域名只试两个最通用的路径，控制请求量
        for origin in origins.dropFirst().prefix(2) {
            add(origin + "/index.php/vod/search.html?wd=" + k)
            add(origin + "/search.php?searchword=" + k)
        }
        return Array(out.prefix(10))
    }

    /// 兼容旧调用：只返回结果列表。
    static func search(targets: [SiteTarget], keyword: String) async -> [SiteSearchHit] {
        await searchReport(targets: targets, keyword: keyword).hits
    }

    /// 先并行 HTTP 抓取；0 命中的站点再串行用隐藏 WebView 渲染 DOM 兜底。
    /// WebView 不能并发十几个（内存 / 主线程），故限制 8 个并串行执行。
    static func searchReport(targets: [SiteTarget], keyword: String) async -> SiteSearchReport {
        guard !keyword.isEmpty, !targets.isEmpty else {
            return SiteSearchReport(hits: [], lines: [])
        }
        let results: [SiteOneResult] = await withTaskGroup(
            of: SiteOneResult.self, returning: [SiteOneResult].self) { group in
            for t in targets {
                group.addTask { await searchOne(target: t, keyword: keyword) }
            }
            var all: [SiteOneResult] = []
            for await one in group { all.append(one) }
            return all
        }

        var hits: [SiteSearchHit] = []
        for one in results { hits.append(contentsOf: one.hits) }

        // 浏览器渲染兜底：只对 HTTP 0 命中的站做，最多 8 个，串行
        let pending = results.filter { $0.hits.isEmpty && $0.domURL != nil }.prefix(8)
        for one in pending {
            guard let raw = one.domURL, let url = URL(string: raw),
                  let t = targets.first(where: { $0.sourceId == one.sourceId }) else { continue }
            let links = await SiteDomProbe.links(from: url, referer: t.baseURL)
            let pairs = links.map { ($0.title, $0.href) }
            let got = hitsFromPairs(pairs, pageURL: url, target: t, keyword: keyword)
            if !got.isEmpty { hits.append(contentsOf: got) }
        }

        var seen = Set<String>()
        var out: [SiteSearchHit] = []
        for h in hits {
            let key = h.url.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(h)
        }

        var lines: [String] = []
        for one in results {
            let count = out.filter { $0.sourceId == one.sourceId }.count
            if count > 0 {
                lines.append("\(one.name)：命中 \(count) 条")
            } else if one.domURL == nil {
                lines.append("\(one.name)：站点地址不可用")
            } else {
                lines.append("\(one.name)：搜索页无结果（含网页渲染）")
            }
        }
        return SiteSearchReport(hits: Array(out.prefix(60)), lines: lines)
    }

    private static func searchOne(target: SiteTarget, keyword: String) async -> SiteOneResult {
        let urls = candidateURLs(target: target, keyword: keyword)
        let domURL = preferredSearchURL(target: target, keyword: keyword)?.absoluteString
        guard let first = urls.first else {
            return SiteOneResult(sourceId: target.sourceId, name: target.name,
                                 hits: [], domURL: nil)
        }
        let firstHits = await fetchHits(url: first, target: target, keyword: keyword)
        if !firstHits.isEmpty {
            return SiteOneResult(sourceId: target.sourceId, name: target.name,
                                 hits: Array(firstHits.prefix(12)), domURL: domURL)
        }
        let rest = Array(urls.dropFirst().prefix(5))
        guard !rest.isEmpty else {
            return SiteOneResult(sourceId: target.sourceId, name: target.name,
                                 hits: [], domURL: domURL)
        }
        let got: [SiteSearchHit] = await withTaskGroup(
            of: [SiteSearchHit].self, returning: [SiteSearchHit].self) { group in
            for u in rest {
                group.addTask { await fetchHits(url: u, target: target, keyword: keyword) }
            }
            var out: [SiteSearchHit] = []
            for await part in group {
                for h in part where !out.contains(where: { $0.url == h.url }) {
                    out.append(h)
                }
            }
            return out
        }
        return SiteOneResult(sourceId: target.sourceId, name: target.name,
                             hits: Array(got.prefix(12)), domURL: domURL)
    }

    private static func fetchHits(url: URL, target: SiteTarget, keyword: String) async -> [SiteSearchHit] {
        let headers = [
            "Referer": target.baseURL,
            "User-Agent": NetworkService.iPhoneUA
        ]
        guard let text = try? await NetworkService.shared.fetchText(
            from: url, headers: headers, timeout: 6
        ), !text.isEmpty else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return jsonHits(text: text, pageURL: url, target: target, keyword: keyword)
        }
        guard let doc = try? SwiftSoup.parse(text),
              let links = try? doc.select("a[href]") else { return [] }
        var pairs: [(String, String)] = []
        for a in links {
            let href = (try? a.attr("href")) ?? ""
            var title = clean((try? a.text()) ?? "")
            if title.isEmpty { title = clean((try? a.attr("title")) ?? "") }
            if href.isEmpty || title.isEmpty { continue }
            pairs.append((title, href))
        }
        return hitsFromPairs(pairs, pageURL: url, target: target, keyword: keyword)
    }

    /// HTTP 与 WebView 两条通道共用的过滤逻辑
    private static func hitsFromPairs(_ pairs: [(String, String)], pageURL: URL,
                                      target: SiteTarget,
                                      keyword: String) -> [SiteSearchHit] {
        let k = keyword.lowercased()
        var out: [SiteSearchHit] = []
        for (rawTitle, href) in pairs {
            let title = clean(rawTitle)
            guard title.count >= 2 else { continue }
            let lowerTitle = title.lowercased()
            guard lowerTitle.contains(k) || (!k.isEmpty && k.contains(lowerTitle)) else { continue }
            let h = href.lowercased()
            guard looksLikeDetail(h) else { continue }
            let absolute: String
            if h.hasPrefix("http://") || h.hasPrefix("https://") {
                absolute = href
            } else {
                guard let u = URL(string: href, relativeTo: pageURL)?.absoluteURL else { continue }
                absolute = u.absoluteString
            }
            guard let u = URLSanitizer.sanitize(absolute) else { continue }
            if out.contains(where: { $0.url == u.absoluteString }) { continue }
            out.append(SiteSearchHit(name: title, url: u.absoluteString,
                                     sourceId: target.sourceId, sourceName: target.name))
            if out.count >= 12 { break }
        }
        return out
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
                collectVod(item, pageURL: pageURL, target: target, keyword: keyword,
                           into: &out, depth: depth + 1)
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
            collectVod(v, pageURL: pageURL, target: target, keyword: keyword,
                       into: &out, depth: depth + 1)
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
            !["wd", "ids", "ac", "page", "limit", "pg"].contains($0.name.lowercased())
        }
        items.append(URLQueryItem(name: "ac", value: "detail"))
        items.append(URLQueryItem(name: "ids", value: id))
        comps.queryItems = items
        return comps.url
    }

    // MARK: - 详情链接判定

    private static func looksLikeDetail(_ h: String) -> Bool {
        if h.hasPrefix("javascript") || h == "#" || h.hasPrefix("mailto") { return false }
        let bad = ["/search", "/login", "/register", "/tag/", "/topic/",
                   ".js", ".css", "/upload/", "/static/"]
        if bad.contains(where: { h.contains($0) }) { return false }
        // v46 过窄：很多影视站用 ?m=vod-detail-id-123 / /detail/123 / ?id=123
        // 这类地址不带 .html 也不带 /vod/，全被丢掉。
        let hints = ["/vod/", "/detail/", "/video/", "/movie/", "/play/", "/show/",
                     "/d/", "/b/", "/html/", ".html", "id=", "ids=", "ac=detail",
                     "vod-detail", "/index.php/vod/", "/watch/", "/drama/"]
        if hints.contains(where: { h.contains($0) }) { return true }
        // 纯数字 id 结尾的详情路径
        let tail: String
        if let first = h.split(separator: "?").first {
            tail = String(first)
        } else {
            tail = h
        }
        let parts = tail.split(separator: "/")
        if let last = parts.last, last.count >= 2, last.allSatisfy({ $0.isNumber }) {
            return true
        }
        return false
    }

    private static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 60 { s = String(s.prefix(60)) }
        return s
    }
}
