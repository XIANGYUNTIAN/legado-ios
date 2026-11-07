import Foundation
import SwiftSoup

// MARK: - 影视站点「通用站内搜索」
//
// v49（公子第五轮反馈「结果区仍是站内搜索，不是直接进播放器」）：
// 用样本 shareBookSource.json 精确复现 v47/v48 的请求清单，确认三个硬缺陷：
//   ① 「资源采集」书源的 bookSourceComment 里有 12 个采集域名，$=[["站名","http://域名"],…]，
//      但 SiteTarget.baseURLs 只取 prefix(4)，candidateURLs 又只对 origins[0] 拼
//      api.php/provide/vod —— 11 个域名一个 API 都没请求；
//   ② 6 个请求里 4 个是同一个采集域名上的 HTML 猜测路径（采集站根本没有网页），
//      纯 HTTP 抓不到、WebView 渲染也 404，于是 24 站全 0 命中；
//   ③ 即便 JSON 拿到，旧 collectVod 丢弃了已经写在里面的 vod_play_url，
//      改去再请求一次 ?ac=detail&ids=，点 ▶ 还要抓网页、再选集。
//
// 现在：采集类源逐个域名并发查苹果 CMS；返回 JSON 里的 vod_play_url 当场拆成
// 可播放剧集，结果行的 bookUrl 就是真实直链 —— 点 ▶ 直接进播放器。
// 有网页的影视站仍保留 HTTP + 隐藏 WebView DOM 兜底。

/// 纯值目标，可安全跨 Task 传递（BookSource 不是 Sendable）。
struct SiteTarget: Sendable {
    let sourceId: String
    let name: String
    /// 兼容旧调用：候选站点根里的第一个
    let baseURL: String
    /// 书源 comment / searchUrl 里出现的全部站点根，逐个尝试
    let baseURLs: [String]
    let searchTemplate: String?
    /// searchUrl 是 @js: 且含 api.php/provide/vod：按苹果 CMS 采集协议直查
    let isCollector: Bool
}

/// 一条剧集直链（String 保证 Sendable，URL 在 MainActor 侧还原）
struct SiteEpisode: Sendable {
    let name: String
    let url: String
}

struct SiteSearchHit: Sendable {
    let name: String
    /// 绝对 URL 字符串。可直接播放时是真实 m3u8/mp4 直链
    let url: String
    let sourceId: String
    let sourceName: String
    /// 该剧的全部剧集。非空时点 ▶ 直接进播放器，不再二次抓网页。
    /// 必须是 var：let + 默认值会让 Swift 的 memberwise init 省略该参数。
    var episodes: [SiteEpisode] = []
}

/// 每站 HTTP 抓取结果 + 该站可用于 WebView 兜底的页面地址
private struct SiteOneResult: Sendable {
    let sourceId: String
    let name: String
    let hits: [SiteSearchHit]
    let domURL: String?
    let apiTried: Int
    let isCollector: Bool
}

/// v50：表单驱动搜索的单站产出（纯值，可跨 Task 传递）
private struct FormOutcome: Sendable {
    let sourceId: String
    let note: String
    let hits: [SiteSearchHit]
}

/// 逐站诊断：搜索页可见，下一轮一张截图就能定位是哪个站、哪一步失败
struct SiteSearchReport: Sendable {
    let hits: [SiteSearchHit]
    let lines: [String]
}

enum SiteSearchService {

    /// 记下「实际返回过内容」的站内搜索页：站点直达优先用它，
    /// 避免打开 0 结果的猜测地址。缓存按「书源 + 关键词」，换词不串页。
    private static let cacheLock = NSLock()
    private static var goodSearchURLs: [String: String] = [:]

    private static func remember(_ sourceId: String, _ url: URL, keyword: String) {
        let s = url.absoluteString
        guard !s.lowercased().contains("api.php") else { return }
        cacheLock.lock()
        goodSearchURLs[sourceId + "|" + keyword] = s
        cacheLock.unlock()
    }

    private static func remembered(_ sourceId: String, keyword: String) -> URL? {
        cacheLock.lock()
        let raw = goodSearchURLs[sourceId + "|" + keyword]
        cacheLock.unlock()
        guard let raw = raw else { return nil }
        return URLSanitizer.sanitize(raw)
    }

    static func target(source: BookSource) -> SiteTarget {
        let urls = source.siteURLs.map { $0.absoluteString }
        // v49：采集类源的可用域名散在 comment 的 JS 数组里，不能只留前 4 个
        let all = urls.isEmpty ? [source.bookSourceUrl] : urls
        let tpl = source.searchUrl ?? ""
        let low = tpl.lowercased()
        let collector = (low.contains("@js:") || low.contains("<js>"))
            && low.contains("api.php/provide/vod")
        return SiteTarget(sourceId: source.bookSourceUrl,
                          name: source.bookSourceName,
                          baseURL: all.first ?? source.bookSourceUrl,
                          baseURLs: all,
                          searchTemplate: source.searchUrl,
                          isCollector: collector)
    }

    /// 「站点直达」用：一键打开站内搜索结果页，不再让用户进首页手动输关键词。
    static func preferredSearchURL(target: SiteTarget, keyword: String) -> URL? {
        if let cached = remembered(target.sourceId, keyword: keyword) { return cached }
        let urls = candidateURLs(target: target, keyword: keyword)
        // 采集接口返回 JSON，WebView 里只是一坨文本；解析接口域名也没有可浏览页面。
        let bad = ["api.php", "/m3u8/", "/parse/", "/jiexi/"]
        return urls.first { u in
            let s = u.absoluteString.lowercased()
            return !bad.contains(where: { s.contains($0) })
        }
    }

    /// 候选搜索页：书源自带 searchUrl 优先，其余为苹果 CMS / 通用影视站常见路径。
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

        // v49：采集类源把「每个候选域名」都试一遍 ac=detail（返回体自带 vod_play_url）。
        // 旧实现只试 origins[0]，第一个域名失效就整站 0 命中。
        if target.isCollector {
            for origin in origins.prefix(12) {
                add(origin + "/api.php/provide/vod/?ac=detail&wd=" + k + "&pg=1")
            }
            for origin in origins.prefix(3) {
                add(origin + "/api.php/provide/vod/?ac=list&wd=" + k + "&pg=1")
            }
            add("/index.php/vod/search.html?wd=" + k)
            return Array(out.prefix(24))
        }

        if let tpl = target.searchTemplate, !tpl.isEmpty {
            let lower = tpl.lowercased()
            if lower.contains("@js:") || lower.contains("<js>") {
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
                // 苹果 CMS 伪静态：关键词要放路径，query 的 wd 站点并不读
                if urlPart.contains("-------------") {
                    urlPart = urlPart.replacingOccurrences(of: "-------------",
                                                          with: k + "-------------")
                    if let q = urlPart.range(of: "?wd=") {
                        urlPart = String(urlPart[urlPart.startIndex..<q.lowerBound])
                    }
                }
                if !urlPart.contains(k) && !urlPart.contains(keyword) {
                    urlPart += (urlPart.contains("?") ? "&" : "?") + "wd=" + k
                }
                add(urlPart)
            }
        }

        let common = [
            "/index.php/vod/search.html?wd=" + k,
            "/vodsearch.html?wd=" + k,
            "/vodsearch/" + k + "-------------.html",
            "/search.php?searchword=" + k,
            "/search?wd=" + k,
            "/search.html?wd=" + k,
            "/?s=" + k
        ]
        for c in common { add(c) }

        for origin in origins.dropFirst().prefix(3) {
            add(origin + "/index.php/vod/search.html?wd=" + k)
            add(origin + "/search.php?searchword=" + k)
        }
        return Array(out.prefix(20))
    }

    /// 兼容旧调用：只返回结果列表。
    static func search(targets: [SiteTarget], keyword: String) async -> [SiteSearchHit] {
        await searchReport(targets: targets, keyword: keyword).hits
    }

    /// 先并行 HTTP 抓取；0 命中的「有网页」站点再串行用隐藏 WebView 渲染 DOM 兜底。
    static func searchReport(targets: [SiteTarget], keyword: String) async -> SiteSearchReport {
        guard !keyword.isEmpty, !targets.isEmpty else {
            return SiteSearchReport(hits: [], lines: [])
        }
        // 分批并发：24 个站点 × 每站十几个采集域名会瞬间发起几百个请求，
        // 按 8 站一批控制峰值（每站最多 10 个域名 → 峰值约 80 个请求）。
        var results: [SiteOneResult] = []
        var cursor = 0
        while cursor < targets.count {
            let end = min(cursor + 8, targets.count)
            let slice = Array(targets[cursor..<end])
            let part: [SiteOneResult] = await withTaskGroup(
                of: SiteOneResult.self, returning: [SiteOneResult].self) { group in
                for t in slice {
                    group.addTask { await searchOne(target: t, keyword: keyword) }
                }
                var all: [SiteOneResult] = []
                for await one in group { all.append(one) }
                return all
            }
            results.append(contentsOf: part)
            cursor = end
        }

        var hits: [SiteSearchHit] = []
        for one in results { hits.append(contentsOf: one.hits) }

        // v50：不再猜站内搜索 URL。诊断截图证实 24 站全是「搜索页无结果（含网页渲染）」：
        // 页面能渲染，只是程序拼的 /vodsearch/?wd=… 根本不是这些站真实的搜索入口。
        // 改为复刻用户手动路径：打开站点首页 → 找页面自带的搜索表单 → 填词提交 →
        // 收结果页渲染后的详情链接。6 路并发，每站 11s 硬超时。
        let pending = Array(results.filter {
            $0.hits.isEmpty && !$0.isCollector
        }.prefix(16))
        var formNotes: [String: String] = [:]
        var cursorForm = 0
        while cursorForm < pending.count {
            let endForm = min(cursorForm + 6, pending.count)
            let slice = Array(pending[cursorForm..<endForm])
            let batch: [FormOutcome] = await withTaskGroup(
                of: FormOutcome.self, returning: [FormOutcome].self) { group in
                for one in slice {
                    group.addTask {
                        guard let t = targets.first(where: { $0.sourceId == one.sourceId }),
                              let home = URLSanitizer.sanitize(t.baseURL) else {
                            return FormOutcome(sourceId: one.sourceId,
                                               note: "首页地址不可用", hits: [])
                        }
                        let out = await SiteFormProbe.search(home: home, keyword: keyword)
                        let pairs = out.links.map { ($0.title, $0.href) }
                        let got = SiteSearchService.hitsFromPairs(
                            pairs, pageURL: home, target: t,
                            keyword: keyword, relaxed: true)
                        return FormOutcome(sourceId: one.sourceId,
                                           note: out.note + " · 命中 " + String(got.count) + " 条",
                                           hits: got)
                    }
                }
                var all: [FormOutcome] = []
                for await item in group { all.append(item) }
                return all
            }
            for item in batch {
                formNotes[item.sourceId] = item.note
                hits.append(contentsOf: item.hits)
            }
            cursorForm = endForm
        }

        // 去重：可播放结果按「剧名 + 来源」收敛，保留集数最多的那份；
        // 其余按链接去重。不同采集域名常返回同一部剧，避免结果区刷屏。
        var seen = Set<String>()
        var playableSeen = Set<String>()
        var out: [SiteSearchHit] = []
        for h in hits.sorted(by: { $0.episodes.count > $1.episodes.count }) {
            if !h.episodes.isEmpty {
                let key = h.name.lowercased() + "|" + h.sourceName.lowercased()
                if playableSeen.contains(key) { continue }
                playableSeen.insert(key)
            }
            let key = h.url.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(h)
        }

        var lines: [String] = []
        for one in results {
            let mine = out.filter { $0.sourceId == one.sourceId }
            let epCount = mine.reduce(0) { $0 + $1.episodes.count }
            if !mine.isEmpty {
                lines.append("\(one.name)：命中 \(mine.count) 部 / \(epCount) 集直链")
            } else if one.isCollector {
                lines.append("\(one.name)：\(one.apiTried) 个采集接口均无结果")
            } else if let note = formNotes[one.sourceId] {
                lines.append("\(one.name)：表单搜索 \(note)")
            } else if one.domURL == nil {
                lines.append("\(one.name)：站点地址不可用")
            } else {
                lines.append("\(one.name)：未进入表单搜索")
            }
        }
        return SiteSearchReport(hits: Array(out.prefix(60)), lines: lines)
    }

    private static func searchOne(target: SiteTarget, keyword: String) async -> SiteOneResult {
        let urls = candidateURLs(target: target, keyword: keyword)
        let domURL = urls.first {
            !$0.absoluteString.lowercased().contains("api.php")
        }?.absoluteString
        guard let first = urls.first else {
            return SiteOneResult(sourceId: target.sourceId, name: target.name,
                                 hits: [], domURL: nil, apiTried: 0,
                                 isCollector: target.isCollector)
        }
        // v49：采集类源把全部候选域名的 API 并发跑完，任一域名可用就能出结果。
        let batch: [URL]
        if target.isCollector {
            batch = Array(urls.prefix(10))
        } else {
            batch = [first] + Array(urls.dropFirst().prefix(7))
        }
        let got: [SiteSearchHit] = await withTaskGroup(
            of: [SiteSearchHit].self, returning: [SiteSearchHit].self) { group in
            for u in batch {
                group.addTask { await fetchHits(url: u, target: target, keyword: keyword) }
            }
            var all: [SiteSearchHit] = []
            for await part in group {
                for h in part where !all.contains(where: { $0.url == h.url }) {
                    all.append(h)
                }
            }
            return all
        }
        return SiteOneResult(sourceId: target.sourceId, name: target.name,
                             hits: Array(got.prefix(20)), domURL: domURL,
                             apiTried: batch.count,
                             isCollector: target.isCollector)
    }

    private static func fetchHits(url: URL, target: SiteTarget, keyword: String) async -> [SiteSearchHit] {
        let headers = [
            "Referer": target.baseURL,
            "User-Agent": NetworkService.iPhoneUA
        ]
        guard let text = try? await NetworkService.shared.fetchText(
            from: url, headers: headers, timeout: 6
        ), !text.isEmpty else { return [] }
        if text.count > 400 { remember(target.sourceId, url, keyword: keyword) }
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
                                      target: SiteTarget, keyword: String,
                                      relaxed: Bool = false) -> [SiteSearchHit] {
        let k = keyword.lowercased()
        var out: [SiteSearchHit] = []
        for (rawTitle, href) in pairs {
            let title = clean(rawTitle)
            guard title.count >= 2 else { continue }
            let lowerTitle = title.lowercased()
            guard lowerTitle.contains(k) || (!k.isEmpty && k.contains(lowerTitle)) else { continue }
            let h = href.lowercased()
            if relaxed {
                guard relaxedDetailOK(h) else { continue }
            } else {
                guard looksLikeDetail(h) else { continue }
            }
            let absolute: String
            if h.hasPrefix("http://") || h.hasPrefix("https://") {
                absolute = href
            } else {
                guard let u = URL(string: href, relativeTo: pageURL)?.absoluteURL else { continue }
                absolute = u.absoluteString
            }
            guard let u = URLSanitizer.sanitize(absolute) else { continue }
            if u.absoluteString.lowercased() == pageURL.absoluteString.lowercased() { continue }
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
        if !name.isEmpty, name.lowercased().contains(keyword.lowercased()) {
            // v49：苹果 CMS 的 ac=detail 已经把 vod_play_url 写在每部剧里。
            // 只序列化这一部剧再交给 VodPlaylistParser，避免多部剧的集混在一起。
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let one = String(data: data, encoding: .utf8),
               VodPlaylistParser.isPlaylistPayload(one) {
                let eps = VodPlaylistParser.episodes(from: one, base: pageURL).map {
                    SiteEpisode(name: $0.name, url: $0.url.absoluteString)
                }
                if let first = eps.first {
                    out.append(SiteSearchHit(name: name, url: first.url,
                                             sourceId: target.sourceId,
                                             sourceName: target.name,
                                             episodes: eps))
                    return
                }
            }
            // 没有直链的采集源：退回 ?ac=detail&ids= 详情页，点 ▶ 再解析一次
            if let link = detailURL(dict: dict, pageURL: pageURL) {
                out.append(SiteSearchHit(name: name, url: link.absoluteString,
                                         sourceId: target.sourceId, sourceName: target.name))
                return
            }
        }
        for (_, v) in dict where v is [Any] || v is [String: Any] {
            collectVod(v, pageURL: pageURL, target: target, keyword: keyword,
                       into: &out, depth: depth + 1)
        }
    }

    /// 苹果 CMS：`?ac=detail&ids=<vod_id>` 返回单部剧的 vod_play_url。
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

    /// v50：表单提交后的结果页由各站自定义模板渲染，详情页 URL 未必带 /vod/ 等特征。
    /// 这里只排掉明确的静态资源、导航与搜索页自身，其余交给标题关键词判定。
    private static func relaxedDetailOK(_ h: String) -> Bool {
        if h.hasPrefix("javascript") || h.hasPrefix("mailto") || h == "#" { return false }
        let bad = [".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg",
                   "/login", "/register", "/upload/", "/static/", "api.php",
                   "/m3u8/", "/parse/", "/jiexi/", "?wd=", "&wd=", "keyword=",
                   "vodsearch", "/search", "/tag/", "/topic/"]
        if bad.contains(where: { h.contains($0) }) { return false }
        return h.count >= 8
    }

    private static func looksLikeDetail(_ h: String) -> Bool {
        if h.hasPrefix("javascript") || h == "#" || h.hasPrefix("mailto") { return false }
        let bad = ["/search", "vodsearch", "/login", "/register", "/tag/", "/topic/",
                   ".js", ".css", "/upload/", "/static/", "api.php", "/m3u8/",
                   "/parse/", "/jiexi/", "?wd=", "&wd=", "keyword=", "?url="]
        if bad.contains(where: { h.contains($0) }) { return false }
        let hints = ["/vod/", "/detail/", "/video/", "/movie/", "/play/", "/show/",
                     "/d/", "/b/", "/html/", ".html", "id=", "ids=", "ac=detail",
                     "vod-detail", "/index.php/vod/", "/watch/", "/drama/"]
        if hints.contains(where: { h.contains($0) }) { return true }
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
