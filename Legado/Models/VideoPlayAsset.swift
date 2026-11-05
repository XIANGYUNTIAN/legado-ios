import Foundation

/// 视频流类型（对应 legado 的 url 后缀自动识别 + JSON 的 type 字段）
///
/// 说明：iOS 原生 AVPlayer 仅支持 HLS(.m3u8) 与 MP4；DASH(.mpd) 与 FLV(.flv)
/// 需第三方软解播放器，MVP 阶段直接报「不支持」而非崩溃。
enum VideoStreamType: String {
    case hls   // .m3u8
    case dash  // .mpd
    case flv   // .flv
    case mp4   // 其它常规封装
    case other // 无法识别
}

/// 多清晰度（legado 视频书源 JSON 的 qualities 字段）
struct VideoQuality: Identifiable {
    let id = UUID()
    let label: String
    let url: URL?
}

/// 外挂字幕（legado 视频书源 JSON 的 subtitles 字段）
struct VideoSubtitle: Identifiable {
    let id = UUID()
    let label: String
    let url: URL?
    let srclang: String
    let isDefault: Bool
}

/// 视频播放资产：chapterContent() 的归一化结果。
///
/// legado 视频书源的「正文」不是文本，而是播放地址，有三种形态：
/// 1) 纯 URL 字符串（`.m3u8`→HLS / `.mpd`→DASH / `.flv`→FLV / 其余→MP4）；
/// 2) JSON 字符串（`{url, type, headers, qualities, subtitles, m3u8Content}`）；
/// 3) 内联 m3u8 文本内容（或以 m3u8Content 字段返回）。
struct VideoPlayAsset {
    let url: URL?                // 主播放地址（纯 URL 形态或 JSON 的 url）
    let type: VideoStreamType
    let headers: [String: String] // 防盗链请求头（Referer / Origin 等）
    let qualities: [VideoQuality] // 多清晰度候选
    let subtitles: [VideoSubtitle]
    let inlineM3U8: String?      // 内联 m3u8 文本（需自行修复相对路径 / 替换 CDN 时使用）
    let raw: String              // 原始 chapterContent 返回值（调试用）

    /// 当前应选用的播放地址：多清晰度优先第一个，否则主地址
    var activeURL: URL? {
        qualities.first?.url ?? url
    }

    /// 是否有可交给 AVPlayer 的媒体（直链或内联 m3u8）
    var isPlayable: Bool {
        activeURL != nil || (inlineM3U8?.isEmpty == false)
    }

    /// 仅按明确后缀 / query 判定直链，用于「章节 URL 本身就是媒体文件」的场景。
    /// 不做内容特征猜测，避免把 /video/123.html 这类播放页当媒体。
    var isExplicitMediaURL: Bool {
        guard let u = activeURL,
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return false }
        let path = comps.path.lowercased()
        let query = (comps.query ?? "").lowercased()
        let exts = [".m3u8", ".mp4", ".mpd", ".flv", ".ts", ".m4v", ".webm", ".mkv", ".mov", ".avi", ".m4a", ".mp3"]
        return exts.contains(where: { path.hasSuffix($0) })
            || query.contains(".m3u8") || query.contains(".mp4")
    }

    /// 是否为可直接交给播放器的媒体地址（而非需要 WebView 嗅探的播放页）。
    /// 在线视频站书源的正文规则常返回 /play/123.html 这类页面 URL，旧实现把它
    /// 一律猜成 .mp4、isPlayable 判 true → AVPlayer 播 HTML 黑屏，嗅探分支永不触发。
    var isDirectMedia: Bool {
        if inlineM3U8?.isEmpty == false { return true }
        if isExplicitMediaURL { return true }
        guard let u = activeURL,
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return false }
        let path = comps.path.lowercased()
        let query = (comps.query ?? "").lowercased()
        if path.hasSuffix(".html") || path.hasSuffix(".htm") { return false }
        return path.contains("m3u8") || query.contains("m3u8")
    }

    /// 原生 AVPlayer 不支持的类型（DASH / FLV）
    var needsUnsupportedEngine: Bool {
        type == .dash || type == .flv
    }

    /// 解析 chapterContent 返回值（纯 URL / JSON / 内联 m3u8）
    static func parse(_ raw: String, base: URL? = nil) -> VideoPlayAsset {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return VideoPlayAsset(url: nil, type: .other, headers: [:],
                                 qualities: [], subtitles: [], inlineM3U8: nil, raw: raw)
        }
        // 形态二：JSON（含 url / type / headers / qualities / subtitles / m3u8Content）
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parseJSON(obj, raw: raw, base: base)
        }
        // 形态三：内联 m3u8（以 #EXTM3U 开头）
        if trimmed.hasPrefix("#EXTM3U") {
            return VideoPlayAsset(url: nil, type: .hls, headers: [:],
                                 qualities: [], subtitles: [], inlineM3U8: trimmed, raw: raw)
        }
        // 形态一：纯 URL
        if let resolved = URLSanitizer.sanitize(trimmed)
            ?? base.flatMap({ URL(string: trimmed, relativeTo: $0)?.absoluteURL }) {
            return VideoPlayAsset(url: resolved, type: guessType(from: resolved), headers: [:],
                                 qualities: [], subtitles: [], inlineM3U8: nil, raw: raw)
        }
        return VideoPlayAsset(url: nil, type: .other, headers: [:],
                             qualities: [], subtitles: [], inlineM3U8: nil, raw: raw)
    }

    private static func parseJSON(_ obj: [String: Any], raw: String, base: URL?) -> VideoPlayAsset {
        var headers: [String: String] = [:]
        if let h = obj["headers"] as? [String: String] { headers = h }

        let urlStr = (obj["url"] as? String) ?? ""
        let typeRaw = (obj["type"] as? String)?.lowercased()
        let type = VideoStreamType(rawValue: typeRaw ?? "")
            ?? guessType(from: URLSanitizer.sanitize(urlStr))

        func resolve(_ s: String?) -> URL? {
            guard let s, !s.isEmpty else { return nil }
            return URLSanitizer.sanitize(s)
                ?? base.flatMap({ URL(string: s, relativeTo: $0)?.absoluteURL })
        }

        let url = resolve(urlStr)

        var qualities: [VideoQuality] = []
        if let qs = obj["qualities"] as? [[String: Any]] {
            for q in qs {
                let label = (q["label"] as? String) ?? "默认"
                qualities.append(VideoQuality(label: label, url: resolve(q["url"] as? String)))
            }
        }

        var subtitles: [VideoSubtitle] = []
        if let ss = obj["subtitles"] as? [[String: Any]] {
            for s in ss {
                let label = (s["label"] as? String) ?? "字幕"
                let lang = (s["srclang"] as? String) ?? "zh-CN"
                let def = (s["default"] as? Bool) ?? false
                subtitles.append(VideoSubtitle(label: label, url: resolve(s["url"] as? String),
                                               srclang: lang, isDefault: def))
            }
        }

        let inline = obj["m3u8Content"] as? String
        return VideoPlayAsset(url: url, type: type, headers: headers,
                             qualities: qualities, subtitles: subtitles,
                             inlineM3U8: inline, raw: raw)
    }

    private static func guessType(from url: URL?) -> VideoStreamType {
        guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .other
        }
        let path = comps.path.lowercased()
        let query = (comps.query ?? "").lowercased()
        if path.contains(".m3u8") || query.contains("m3u8") { return .hls }
        if path.hasSuffix(".mpd") || query.contains(".mpd") { return .dash }
        if path.hasSuffix(".flv") || query.contains(".flv") { return .flv }
        return .mp4
    }

    /// 合并书源级防盗链头；规则 JSON 自带的 headers 优先。
    func mergingHeaders(_ extra: [String: String]) -> VideoPlayAsset {
        var merged = extra
        for (k, v) in headers { merged[k] = v }
        return VideoPlayAsset(url: url, type: type, headers: merged,
                              qualities: qualities, subtitles: subtitles,
                              inlineM3U8: inlineM3U8, raw: raw)
    }

    /// 把内联 m3u8 文本落地为本地 playlist（相对分片 / URI 属性按 base 补全），
    /// 否则只有文本没有 URL，AVPlayer 拿到的是空白画面。
    func materializeInlineM3U8(base: URL?) -> URL? {
        guard let text = inlineM3U8, !text.isEmpty else { return nil }
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { lines.append(line); continue }
            if t.hasPrefix("#") {
                lines.append(Self.resolveAttributeURIs(in: line, base: base))
            } else if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://"),
                      let abs = base.flatMap({ URL(string: t, relativeTo: $0)?.absoluteString }) {
                lines.append(abs)
            } else {
                lines.append(line)
            }
        }
        let payload = lines.joined(separator: "\n")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado_\(UUID().uuidString.prefix(8)).m3u8")
        do {
            try payload.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    /// 补全 m3u8 中 #EXT-X-KEY / #EXT-X-MAP 的 URI="..." 相对地址。
    private static func resolveAttributeURIs(in line: String, base: URL?) -> String {
        guard let base = base,
              let rx = try? NSRegularExpression(pattern: #"URI="([^"]+)""#, options: []) else { return line }
        let ns = line as NSString
        let matches = rx.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var out = line as NSString
        for m in matches.reversed() {
            let rel = ns.substring(with: m.range(at: 1))
            if !rel.lowercased().hasPrefix("http"),
               let abs = URL(string: rel, relativeTo: base)?.absoluteString {
                out = out.replacingCharacters(in: m.range(at: 1), with: abs) as NSString
            }
        }
        return out as String
    }
}
