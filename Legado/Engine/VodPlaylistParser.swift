import Foundation

// MARK: - 采集站（苹果 CMS / 资源采集）播放列表解析
//
// 公子 2026-11-05 截图实证：搜索结果点开后落到的不是网页，而是
// `https://…/api.php/provide/vod/?ac=detail&ids=…` 返回的 JSON 播放列表，
// 里面 `vod_play_url` 已经写好 `第01集$https://…/index.m3u8#第02集$…`。
// v39 之前只是把这个 JSON 当网页显示，用户还得自己在网页里找播放按钮、吃广告。
// 这里把播放列表直接还原成剧集 → 原生播放器，绕开网页与广告。

struct VodEpisode: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
}

/// 一次解析结果，供选集面板与 sheet(item:) 使用。
struct VodEpisodeList: Identifiable {
    let id = UUID()
    let title: String
    let episodes: [VodEpisode]
    let headers: [String: String]
    let referer: String
}

enum VodPlaylistParser {

    private static let mediaKeys = ["vod_play_url", "vod_play_list", "vod_content",
                                    "vod_url", "play_url", "playUrl", "m3u8"]
    private static let containerKeys: Set<String> = [
        "list", "data", "episodes", "videos", "results", "items", "vod"
    ]

    /// 页面文本是否像「采集站播放列表」。用于 WebView 里自动拦截 JSON 页。
    static func isPlaylistPayload(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("vod_play_url") || lower.contains("vod_play_from")
            || lower.contains("vod_play_list") || lower.contains("vod_play_note")
            || lower.contains("\"play_url\"")
    }

    /// 从 JSON / 纯文本 / HTML 里提取可播剧集。
    /// - 优先按 JSON 结构取 `vod_play_url`；取不到再退回全文捞 m3u8 / mp4 明文
    ///   （站点详情页常把播放地址写在 `<script>` 或 `data-*` 属性里）。
    static func episodes(from text: String, base: URL) -> [VodEpisode] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        var found: [VodEpisode] = []
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            collect(obj, into: &found, base: base, depth: 0)
        }
        if found.isEmpty {
            collectPlain(s, into: &found, base: base)
        }
        var seen = Set<String>()
        var out: [VodEpisode] = []
        for ep in found {
            let key = ep.url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(ep)
        }
        return out
    }

    // MARK: - 内部

    private static func collect(_ value: Any,
                                into out: inout [VodEpisode],
                                base: URL,
                                depth: Int) {
        guard depth < 6 else { return }
        if let dict = value as? [String: Any] {
            // ① 标准字段：字符串直接按「名称$地址#…」拆，数组/字典继续下钻
            for key in mediaKeys {
                guard let raw = dict[key] else { continue }
                if let s = raw as? String {
                    parseList(s, into: &out, base: base)
                } else {
                    collect(raw, into: &out, base: base, depth: depth + 1)
                }
            }
            // ② { "name": "第1集", "url": "https://…/index.m3u8" }
            var link: String?
            for k in ["url", "playUrl", "src", "videoUrl", "link"] {
                if let v = dict[k] as? String { link = v; break }
            }
            var label: String?
            for k in ["name", "title", "episode", "part", "text"] {
                if let v = dict[k] as? String { label = v; break }
            }
            if let l = link, let u = resolve(l, base: base), isMedia(u) {
                let n = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(VodEpisode(name: n.isEmpty ? "第\(out.count + 1)集" : n, url: u))
            }
            // ③ 容器字段继续下钻（list / data / episodes…）
            for (k, v) in dict where containerKeys.contains(k.lowercased()) {
                collect(v, into: &out, base: base, depth: depth + 1)
            }
            return
        }
        if let arr = value as? [Any] {
            for item in arr { collect(item, into: &out, base: base, depth: depth + 1) }
            return
        }
        if let s = value as? String {
            parseList(s, into: &out, base: base)
        }
    }

    /// `$$$` 分播放源、`#` 分集、`$` 分「集名$地址」；也兼容纯地址列表。
    private static func parseList(_ raw: String, into out: inout [VodEpisode], base: URL) {
        for group in raw.components(separatedBy: "$$$") {
            for seg in group.components(separatedBy: "#") {
                let parts = seg.components(separatedBy: "$")
                var label: String?
                var link: String?
                if parts.count >= 2 {
                    label = parts[0]
                    link = parts[1]
                } else if let first = parts.first {
                    link = first
                }
                guard let l = link?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let u = resolve(l, base: base), isMedia(u) else { continue }
                let n = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(VodEpisode(name: n.isEmpty ? "第\(out.count + 1)集" : n, url: u))
            }
        }
    }

    /// JSON 解析失败 / 站点把播放地址写在 HTML script 里时，全文捞直链。
    private static func collectPlain(_ text: String, into out: inout [VodEpisode], base: URL) {
        guard let rx = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#) else { return }
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            s = s.replacingOccurrences(of: #"\/"#, with: "/")
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;)]}\"'\\"))
            guard let u = resolve(s, base: base), isMedia(u) else { continue }
            out.append(VodEpisode(name: "第\(out.count + 1)集", url: u))
        }
    }

    private static func resolve(_ raw: String, base: URL) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("//") { return URL(string: "https:" + s) }
        if let u = URLSanitizer.sanitize(s) { return u }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    /// 只认媒体地址，避免把封面 jpg、详情 API、普通页面链接当剧集。
    private static func isMedia(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        let s = url.absoluteString.lowercased()
        for mark in [".m3u8", ".mp4", ".mpd", ".flv", ".m4v", ".mkv", ".webm", "m3u8"] {
            if s.contains(mark) { return true }
        }
        return false
    }
}
