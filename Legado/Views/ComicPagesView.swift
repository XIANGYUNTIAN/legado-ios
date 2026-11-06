import SwiftUI
import UIKit

// MARK: - 漫画 / 图片书源正文
//
// 公子 2026-11-05 反馈：漫画加入书架后无法观看。文本阅读器把 ruleContent 结果
// 一律走 cleanChapterContent 文本清洗，漫画源返回的图片地址列表会被当成正文文字显示。
// 这里把「图片地址列表」识别出来并渲染成可纵向滚动的图片页，请求头沿用书源 header
// （Referer 防盗链），避免 AsyncImage 无法带 header 导致整页加载失败。
//
// 公子 2026-11-06 再反馈「漫画又看不了」。v43 加固三处（v42 只动过按钮，不是回归）：
//   1) 路由：BookReaderView.body 原先只要 isVideoLike 为真就整页进视频阅读器，
//      而漫画源常用 webJs 加载动态图页，被误判成视频（BookSource.isVideoLike 已修）；
//   2) 提取：旧正则只认「带 .jpg/.png 后缀的绝对 http(s) URL」，无扩展名图床、
//      协议相对 //、.jpg!w800、HTML 懒加载属性、JSON 字段全漏，命中不足 2 张
//      就落回文本清洗；
//   3) 下载：书源没写 Referer 时旧代码用「图片自己的 host」当来源，图床白名单
//      通常只认源站 → 每页 403；且失败无任何诊断信息。

enum ComicPageDetector {
    /// 从正文规则结果里提取图片地址。
    /// 三条通道合并去重：① 全文带图片扩展名的 URL；② HTML 图片属性值（可无扩展名）；
    /// ③ JSON / JS 里的 url / src / img 字段值（可无扩展名）。
    /// 支持 https:\/\/ 转义、&amp;、协议相对 //、.jpg!w800、.jpg@webp、query。
    static func imageURLs(from raw: String, base: URL, looseLines: Bool = false) -> [URL] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 300_000 else { return [] }
        let normalized = text
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")

        var out: [URL] = []
        var seen = Set<String>()
        // 漫画章节页侧栏有几十张「推荐漫画封面」，无扩展名图床地址会被 ② 通道
        // 一并收走；不排掉就会把封面当成正文页铺满整屏。
        let noise = ["logo", "icon", "avatar", "banner", "/ad/", "ads.",
                     "qrcode", "qr_code", "loading", "placeholder", "sprite",
                     "/btn", "button", "favicon", "share.", "blank.gif", "1x1",
                     "/cover/", "cover/", "/covers/", "/thumb", "thumb/",
                     "load.gif", "loading.gif", "small_", "/avatar/"]

        func append(_ candidate: String) {
            let s = candidate.trimmingCharacters(
                in: CharacterSet(charactersIn: ",;)]}\"'\\"))
            guard !s.isEmpty else { return }
            var address = s
            if address.hasPrefix("//") {
                address = (base.scheme ?? "https") + ":" + address
            }
            // img@src 常给相对路径（/upload/1.jpg），交给 relativeTo 补全；
            // 同时挡掉 JSON 里的短值（"1"、"null"）被当成图片地址。
            let isRelative = address.hasPrefix("/")
            if !isRelative && address.count < 13 { return }
            guard let url = URLSanitizer.sanitize(address)
                    ?? URL(string: address, relativeTo: base)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            let key = url.absoluteString
            if seen.contains(key) { return }
            // ② 通道会连带命中 <script src> / <link href> / data-original="/"，
            // 不排掉就会把几十个 JS/CSS 或站点根当漫画页铺出来。
            let pathLower = url.path.lowercased()
            guard pathLower != "/" && !pathLower.isEmpty else { return }
            let nonImage = [".js", ".css", ".html", ".htm", ".php", ".asp",
                            ".aspx", ".ico", ".woff", ".woff2", ".ttf",
                            ".svg", ".mp4", ".m3u8", ".mp3", ".json", ".xml"]
            guard !nonImage.contains(where: { pathLower.hasSuffix($0) }) else { return }
            let lower = key.lowercased()
            guard !noise.contains(where: { lower.contains($0) }) else { return }
            seen.insert(key)
            out.append(url)
        }

        // 输入已是「候选 URL 列表」（WebView DOM 收集结果）时不做 HTML/JSON 正则，
        // 只按行取绝对地址，避免把页面里的 CSS/JS/推荐位链接误当成图片。
        if looseLines {
            for line in normalized.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("//"),
                      t.count < 500, !t.contains(" ") else { continue }
                append(t)
                if out.count >= 200 { break }
            }
            return out
        }

        func collect(_ pattern: String, group: Int = 0) {
            guard let rx = try? NSRegularExpression(pattern: pattern,
                                                    options: .caseInsensitive) else { return }
            let ns = normalized as NSString
            for match in rx.matches(in: normalized,
                                    range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > group else { continue }
                let range = match.range(at: group)
                guard range.location != NSNotFound else { continue }
                append(ns.substring(with: range))
                if out.count >= 200 { return }
            }
        }

        // ① 全文：带图片扩展名，允许 !w800 / @webp 变体与 query
        collect(#"(?:https?:)?//[^\s"'<>\\]+?\.(?:jpe?g|png|webp|gif|bmp|avif)(?:[!@][^\s"'<>]*)?(?:\?[^\s"'<>]*)?"#)
        // ② HTML 图片属性：src / data-src / data-original / srcset 等懒加载写法
        collect(#"(?i)(?:data-(?:src|original|url|lazy-?src|echo)|srcset|src|data-?url)\s*=\s*["']?([^"'<>\s,]+)"#, group: 1)
        // ③ JSON / JS：{"url":"…"}、imgUrl = "…"
        collect(#"(?i)["']?(?:url|src|img|image|pic|imgurl|imageurl|picurl)["']?\s*[:=]\s*["']([^"']+)["']"#, group: 1)
        return out
    }

    /// 正文是否「短到不可能是小说章节」：一张图 + 极少的中文正文时允许切图片页。
    static func isImageOnlyPayload(_ raw: String) -> Bool {
        let stripped = raw
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count < 2000 else { return false }
        let chinese = stripped.unicodeScalars.filter {
            ($0.value >= 0x4E00 && $0.value <= 0x9FFF)
        }.count
        return chinese < 100
    }
}

struct ComicPagesView: View {
    let pages: [URL]
    let headers: [String: String]
    let title: String
    /// 章节页地址：书源没写 Referer 时用它做防盗链来源，不能用图片自己的域名。
    let referer: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { idx in
                    ComicPageImage(url: pages[idx],
                                   headers: headers,
                                   referer: referer,
                                   index: idx)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 单页图片：带书源 header 下载；失败时按「换来源 / 去来源 / 升 https」降级重试，
/// 并显示具体失败原因，便于按截图定位是 403 防盗链、ATS 还是非图片响应。
private struct ComicPageImage: View {
    let url: URL
    let headers: [String: String]
    let referer: String?
    let index: Int

    @State private var image: UIImage?
    @State private var failed = false
    @State private var failureDetail = ""

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("第 \(index + 1) 页加载失败 · \(failureDetail)")
                    Text(url.absoluteString)
                        .font(.caption2)
                        .lineLimit(2)
                    Button("重试") {
                        failed = false
                        failureDetail = ""
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 170)
                .padding(.horizontal, 12)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard image == nil, !failed else { return }
        var reason = ""
        for request in candidateRequests() {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let decoded = UIImage(data: data) {
                    image = decoded
                    return
                }
                reason = code > 0
                    ? "HTTP \(code)，\(data.count) B 非图片"
                    : "\(data.count) B 非图片"
            } catch {
                reason = "网络错误（\((error as NSError).code)）"
            }
        }
        failureDetail = reason.isEmpty ? "图片加载失败" : reason
        failed = true
    }

    private func candidateRequests() -> [URLRequest] {
        let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        let hasReferer = headers.keys.contains {
            $0.caseInsensitiveCompare("Referer") == .orderedSame
        }
        var primary = headers
        if !hasReferer {
            primary["Referer"] = referer.flatMap { $0.isEmpty ? nil : $0 }
                ?? url.absoluteString
        }
        if primary["User-Agent"] == nil && primary["user-agent"] == nil {
            primary["User-Agent"] = agent
        }
        // 图床白名单常只认站点根，不认带路径的章节页
        let rootReferer: String? = {
            guard let r = primary["Referer"] else { return nil }
            let parts = r.components(separatedBy: "/")
            return parts.count >= 3 ? parts.prefix(3).joined(separator: "/") + "/" : r
        }()

        var variants: [[String: String]] = [primary, ["User-Agent": agent]]
        if let rootReferer, rootReferer != primary["Referer"] {
            variants.append(["User-Agent": agent, "Referer": rootReferer])
        }

        var urls: [URL] = [url]
        // iOS ATS 会拦截 https 页面里的 http 图片，补一个 https 版本
        if url.scheme?.lowercased() == "http",
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            if let upgraded = comps.url { urls.append(upgraded) }
        }

        var out: [URLRequest] = []
        for target in urls {
            for fields in variants {
                var request = URLRequest(url: target)
                request.timeoutInterval = 15
                request.cachePolicy = .returnCacheDataElseLoad
                for (key, value) in fields {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                out.append(request)
            }
        }
        return out
    }
}
