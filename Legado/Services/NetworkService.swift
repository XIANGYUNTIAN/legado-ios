import Foundation
import CoreFoundation
import zlib

// MARK: - URL 清洗

/// URL 构造与校验：`URL(string:)` 宽容（接受空格/中文），`URLSession` 严格
/// （直接抛 NSURLErrorUnsupportedURL "unsupported URL"）。所有外部 URL
/// （书源链接、exploreUrl、searchUrl）必须先过这里。
enum URLSanitizer {
    /// 校验并修复 URL：仅接受 http/https；非法字符自动百分号编码。
    /// 返回 nil 表示不是可请求的链接（规则串、JS、空串等）。
    static func sanitize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // legado 约定：URL 片段 #requestWithoutUA 等不属于请求目标
        if let hash = s.firstIndex(of: "#"), hash > s.startIndex {
            s = String(s[s.startIndex..<hash])
        }
        guard !s.isEmpty else { return nil }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        // 完全合法（RFC 3986 未保留+保留字符）则直接用
        let legal = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        if s.rangeOfCharacter(from: legal.inverted) == nil {
            return url
        }
        // 含非法字符（空格、中文等）→ 用 URLComponents 重建并百分号编码
        if let comps = URLComponents(string: s), let rebuilt = comps.url {
            return rebuilt
        }
        // 兜底：手工拆分后由 URLComponents 重组（自动转义非法字符）
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = url.port
        comps.path = url.path
        comps.query = url.query
        comps.fragment = url.fragment
        return comps.url
    }

    /// 判断字符串是否"看起来像链接"（用于给出针对性错误提示）
    static func looksLikeLink(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}

// MARK: - 网络错误

/// 统一的网络层错误类型，便于各调用方给出一致且友好的提示。
enum NetworkError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case emptyResponse
    case encodingFailed
    case timeout
    case cancelled
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "链接格式不正确"
        case .badStatus(let code):
            return "服务器返回 HTTP \(code)，链接可能已失效或被拦截"
        case .emptyResponse:
            return "服务器返回内容为空"
        case .encodingFailed:
            return "无法解码返回内容（非文本）"
        case .timeout:
            return "请求超时，请检查网络或稍后重试"
        case .cancelled:
            return "请求已取消"
        case .network(let message):
            return "网络错误：\(message)"
        }
    }
}

// MARK: - 网络服务

/// 全局唯一的网络入口：共享 URLSession 配置、移动端 UA、超时与编码策略。
///
/// 设计要点：
/// - 共享单例，避免为每个请求新建 URLSession 的开销；
/// - 默认 iPhone UA，规避开源站点对桌面端 UA 的拦截；
/// - `waitsForConnectivity = true`，网络恢复时自动重试，弱网更友好；
/// - 显式 `Accept-Encoding: identity`——URLSession 会替请求附加
///   `gzip, deflate, br`，而 br（Brotli）它并不解压，二进制原文会让文本
///   解码失败并误报"无法解码返回内容（非文本）"；
/// - UTF-8 优先、GB18030 / UTF-16 兜底，覆盖中文站点编码；
/// - 调用方通过 `headers` 传入书源自定义请求头（对应 legado 的 header 字段）；
/// - **证书信任委托**：legado 书源大量指向自签 / 过期 / 证书链不全的中文站点，
///   `URLSession` 默认校验会直接抛 "A TLS error caused the secure connection
///   to fail"。这里实现 `URLSessionDelegate` 信任所有服务器证书（对应 legado
///   关闭 SSL 校验的行为），使书源导入 / 搜索 / 阅读对这类站点可用。
final class NetworkService: ObservableObject {
    static let shared = NetworkService()

    /// 移动端 UA（与 BookSourceStore / BookStore 保持一致）
    static let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 默认请求超时（秒）
    static let defaultTimeout: TimeInterval = 25

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.defaultTimeout
        config.timeoutIntervalForResource = Self.defaultTimeout
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [
            "User-Agent": Self.iPhoneUA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            // 关键：不接受压缩编码，避免 br/gzip 原文直接进入文本解码
            "Accept-Encoding": "identity",
        ]
        // 信任所有证书（自签 / 过期 / 链不全的中文书源站点）
        session = URLSession(configuration: config, delegate: TrustAllDelegate(), delegateQueue: nil)
    }

    // MARK: - 证书信任委托

    /// 信任所有服务器证书。书源站点的 TLS 证书质量参差，关闭校验使导入 / 搜索
    /// / 阅读对自签、过期、证书链不全的站点可用（与 legado 一致）。
    private class TrustAllDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // 接受任意证书：用系统提供的 trust 直接构造凭据
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }

    // MARK: - 公开接口

    /// 抓取远端文本（UTF-8 / GB18030 / UTF-16 解码，自动去除 BOM 与首尾空白）
    func fetchText(from url: URL,
                   headers: [String: String]? = nil,
                   timeout: TimeInterval? = nil) async throws -> String {
        let (data, response) = try await fetchDataWithResponse(from: url, headers: headers, timeout: timeout)
        return try Self.decodeText(data, charset: response.textEncodingName)
    }

    /// 抓取远端原始 Data（含状态码校验与空内容校验）
    func fetchData(from url: URL,
                   headers: [String: String]? = nil,
                   timeout: TimeInterval? = nil) async throws -> Data {
        try await fetchDataWithResponse(from: url, headers: headers, timeout: timeout).0
    }

    /// 抓取远端数据并返回 HTTP 响应（供需要 Content-Type 判格式的调用方）
    func fetchDataWithResponse(from url: URL,
                               headers: [String: String]? = nil,
                               timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        try await performRequest(url: url, headers: headers, timeout: timeout)
    }

    /// 带请求体的抓取（支持 POST 搜索等）：method 为 "GET"/"POST"，body 为已编码的
    /// 请求体字节。用于 legado 书源 searchUrl 的 POST 形式（含 searchKey 占位符的 body）。
    func fetchTextWithBody(from url: URL,
                           method: String,
                           body: Data?,
                           headers: [String: String]? = nil,
                           timeout: TimeInterval? = nil) async throws -> String {
        let (data, response) = try await performRequestWithBody(url: url, method: method, body: body, headers: headers, timeout: timeout)
        return try Self.decodeText(data, charset: response.textEncodingName)
    }

    /// 带请求体的原始抓取（返回数据与响应），供需要状态码/编码判断的调用方
    func fetchDataWithBody(from url: URL,
                           method: String,
                           body: Data?,
                           headers: [String: String]? = nil,
                           timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        try await performRequestWithBody(url: url, method: method, body: body, headers: headers, timeout: timeout)
    }

    // MARK: - 内部

    private func performRequest(url: URL,
                                headers: [String: String]?,
                                timeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        try await performRequestWithBody(url: url, method: "GET", body: nil, headers: headers, timeout: timeout)
    }

    private func performRequestWithBody(url: URL,
                                        method: String,
                                        body: Data?,
                                        headers: [String: String]?,
                                        timeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        // scheme 前置校验：避免 URLSession 抛出难懂的 "unsupported URL"
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw NetworkError.invalidURL
        }

        var lastError: Error = NetworkError.network("请求失败")
        // 瞬时错误（连接被丢弃 / 无法连接 / 超时）最多重试 2 次，
        // 间隔 0.6s / 1.2s 指数退避。中文书源站点在弱网或反爬时
        // 偶发掉连接，多轮重试可显著减少「全部失败」。
        for attempt in 0..<3 {
            do {
                return try await attemptRequest(url: url, method: method, body: body,
                                                headers: headers, timeout: timeout)
            } catch let error as NetworkError {
                guard Self.isTransient(error) else { throw error }
                lastError = error
            } catch {
                throw NetworkError.network(error.localizedDescription)
            }
            if attempt < 2 {
                if Task.isCancelled { throw NetworkError.cancelled }
                let delay: UInt64 = attempt == 0 ? 600_000_000 : 1_200_000_000  // 0.6s / 1.2s
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError
    }

    /// 单次实际请求（不含重试逻辑）。
    private func attemptRequest(url: URL,
                                method: String,
                                body: Data?,
                                headers: [String: String]?,
                                timeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.timeoutInterval = timeout ?? Self.defaultTimeout
        request.setValue(Self.iPhoneUA, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let body {
            request.httpBody = body
            // POST 搜索常见表单编码；调用方也可通过 headers 覆盖
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.network("非 HTTP 响应")
            }
            if !(200...299).contains(http.statusCode) {
                throw NetworkError.badStatus(http.statusCode)
            }
            if data.isEmpty {
                throw NetworkError.emptyResponse
            }
            return (Self.maybeDecompress(data, response: http), http)
        } catch let error as NetworkError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw NetworkError.timeout
            case .cancelled:
                throw NetworkError.cancelled
            case .unsupportedURL:
                throw NetworkError.invalidURL
            default:
                // 附上错误码与 host，便于定位「连接被丢弃」是服务器问题还是代码问题
                throw NetworkError.network("\(urlError.code.rawValue) \(url.host ?? "")：\(urlError.localizedDescription)")
            }
        } catch {
            throw NetworkError.network(error.localizedDescription)
        }
    }

    /// 判定是否为值得重试的瞬时错误。
    ///
    /// 仅对「连接类」错误（连接被拒 / 被重置 / DNS / 无法连接等，对应 `.network`）
    /// 重试——这类错误通常瞬时且失败极快（亚秒级），重试收益高、代价低。
    ///
    /// **超时（`.timeout`）不再重试**：弱网下服务器响应慢，重试只会把单次等待
    /// 放大成 N 倍（默认 3 次 = 3× 超时），既拖垮搜索全局预算、又造成「一搜就
    /// 长时间无进展」的假死观感。超时源直接失败，交由上层（搜索预算 / 阅读重试）
    /// 决策，比盲目重试更优。
    private static func isTransient(_ error: NetworkError) -> Bool {
        switch error {
        case .network: return true
        default: return false
        }
    }

    /// 兜底解压：若服务端仍返回 gzip/deflate（URLSession 未代解），
    /// 尝试 inflate；失败则原样返回（try? 保证不影响正常路径）。
    private static func maybeDecompress(_ data: Data, response: HTTPURLResponse) -> Data {
        guard let enc = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() else {
            return data
        }
        guard enc.contains("gzip") || enc.contains("deflate") else { return data }
        guard let inflated = try? inflateRaw(data) else { return data }
        return inflated.isEmpty ? data : inflated
    }

    // MARK: - 编码 / 工具

    /// 文本解码。优先级：
    /// 1. 显式 charset（调用方传入，如 searchUrl 选项的 charset: "gbk"）；
    /// 2. UTF-8 优先——但解码成功后**再查 meta charset**，若页面声明 gb2312/gbk
    ///    而字节恰好是合法 UTF-8（GBK 中文大量落入该情形），按声明重新用 GB18030 解码；
    /// 3. GB18030 / UTF-16 兜底。
    /// - Parameter charset: 显式字符集（大小写不敏感），nil 表示自动探测
    static func decodeText(_ data: Data, charset: String? = nil) throws -> String {
        if let charset, let encoding = encoding(named: charset),
           let text = String(data: data, encoding: encoding) {
            return Self.stripBOM(text)
        }
        if let text = String(data: data, encoding: .utf8) {
            // meta charset 复核：声明 GBK 系但被 UTF-8 成功解码 → 乱码，按声明重解
            if let declared = Self.metaCharset(text),
               declared.lowercased().contains("gb"),
               let encoding = encoding(named: declared),
               let gbkText = String(data: data, encoding: encoding) {
                return Self.stripBOM(gbkText)
            }
            return Self.stripBOM(text)
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return Self.stripBOM(text)
        }
        if let text = String(data: data, encoding: .utf16) {
            return Self.stripBOM(text)
        }
        if let text = String(data: data, encoding: .utf16BigEndian) {
            return Self.stripBOM(text)
        }
        throw NetworkError.encodingFailed
    }

    /// charset 名 → String.Encoding。覆盖中文站点常见声明
    static func encoding(named charset: String) -> String.Encoding? {
        switch charset.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "") {
        case "utf-8", "utf8", "utf_8":
            return .utf8
        case "gbk", "gb2312", "gb-2312", "gb_2312", "gb18030", "gb-18030", "chinese", "zh-cn", "cp936":
            let gb = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            return String.Encoding(rawValue: gb)
        case "utf-16", "utf16", "utf_16":
            return .utf16
        case "utf-16le", "utf-16be":
            return .utf16
        case "big5", "big-5", "big5-hkscs":
            let big5 = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
            return String.Encoding(rawValue: big5)
        case "iso-8859-1", "latin1", "ascii", "us-ascii":
            return .isoLatin1
        default:
            // 未知声明交给 CFString 转换（覆盖 x- 前缀等变体）
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                return String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(cf)
                )
            }
            return nil
        }
    }

    /// 从 HTML 头部提取 meta charset 声明（`<meta charset="gbk">` 或
    /// `<meta http-equiv="Content-Type" content="text/html; charset=gbk">`）
    static func metaCharset(_ html: String) -> String? {
        let head = String(html.prefix(2048))
        // 形如 charset=xxx 的声明
        if let regex = try? NSRegularExpression(
            pattern: "charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9_\\-]+)", options: .caseInsensitive
        ) {
            let ns = head as NSString
            if let match = regex.firstMatch(
                in: head, range: NSRange(location: 0, length: ns.length)
            ) {
                return ns.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    /// 去除 UTF-8 BOM 并修剪首尾空白
    static func stripBOM(_ text: String) -> String {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// zlib inflate（输入需带 zlib/gzip 头），与 EPUBReader 的实现保持一致
    private static func inflateRaw(_ data: Data) throws -> Data {
        var zstream = z_stream()
        defer { inflateEnd(&zstream) }

        var out = Data()
        var capacity = max(data.count * 10, 4096)
        var produced = 0
        var complete = false

        try data.withUnsafeBytes { inBytes in
            guard let inBase = inBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw NetworkError.encodingFailed
            }
            zstream.next_in = UnsafeMutablePointer<UInt8>(mutating: inBase)
            zstream.avail_in = uInt(data.count)

            let version = strdup("1.3")
            defer { free(version) }
            guard inflateInit2_(&zstream, 15 + 32, version,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw NetworkError.encodingFailed
            }

            while !complete {
                var chunk = Data(count: capacity)
                let before = produced
                try chunk.withUnsafeMutableBytes { outBytes in
                    guard let outBase = outBytes.bindMemory(to: UInt8.self).baseAddress else {
                        throw NetworkError.encodingFailed
                    }
                    zstream.next_out = UnsafeMutablePointer<UInt8>(mutating: outBase)
                    zstream.avail_out = uInt(capacity)
                    let result = inflate(&zstream, Z_NO_FLUSH)
                    produced = Int(zstream.total_out)
                    if result == Z_STREAM_END {
                        complete = true
                    } else if result != Z_OK {
                        throw NetworkError.encodingFailed
                    }
                }
                out.append(chunk.prefix(produced - before))
                if !complete {
                    if zstream.avail_in == 0 && produced == before {
                        throw NetworkError.encodingFailed
                    }
                    capacity *= 2
                }
            }
        }
        guard produced > 0 else { throw NetworkError.encodingFailed }
        return out
    }
}
