import Foundation

// MARK: - 书源失效检测
//
// 公子 2026-11-05 需求：筛查书源是否失效，并把失效书源直接选中，由用户决定
// 一键删除还是部分删除。
//
// 边界（必须如实告知用户）：这里只探测「站点是否还能连通」，不校验规则是否
// 仍能解析。规则失效（改版 / 选择器漂移）只能靠实际搜索、目录、正文阅读确认。
// 因此：
//   - 401 / 403 / 429 表示站点活着、只是拒绝匿名访问，判为「可用」，避免误删；
//   - 书源根本没写可请求地址（采集类 bookSourceUrl 是中文名且注释无域名）判为
//     「无法检测」，默认不选中；
//   - 采集类书源 siteURLs 可能有十几个域名，只测前 3 个，任一可达即判可用。

struct SourceCheckTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let host: String
    /// 候选站点根地址（字符串形式，便于跨并发任务传递）
    let candidates: [String]
}

enum SourceCheckState: String, Sendable {
    case ok = "可用"
    case failed = "失效"
    case unknown = "无法检测"
    case cancelled = "已停止"
}

struct SourceCheckResult: Sendable {
    let id: String
    let state: SourceCheckState
    let detail: String
    let milliseconds: Int
}

enum SourceHealthChecker {
    static let maxCandidates = 3
    static let timeout: TimeInterval = 6
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 从书源生成检测目标。站点地址复用 BookSource.siteURLs（采集类会从注释提域名）。
    static func targets(from sources: [BookSource]) -> [SourceCheckTarget] {
        sources.map { source in
            let urls = Array(source.siteURLs.prefix(maxCandidates))
            let name = source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName
            let host = urls.first?.host ?? source.bookSourceURL?.host ?? "未配置地址"
            return SourceCheckTarget(
                id: source.bookSourceUrl,
                name: name,
                host: host,
                candidates: urls.map { $0.absoluteString }
            )
        }
    }

    /// 单个书源检测：候选地址逐个尝试，任一可达即成功；全部失败才判失效。
    static func check(_ target: SourceCheckTarget) async -> SourceCheckResult {
        let started = Date()
        func result(_ state: SourceCheckState, _ detail: String) -> SourceCheckResult {
            SourceCheckResult(
                id: target.id,
                state: state,
                detail: detail,
                milliseconds: Int(Date().timeIntervalSince(started) * 1000)
            )
        }

        guard !target.candidates.isEmpty else {
            return result(.unknown, "书源未配置可检测地址（地址非 URL，注释中也无域名）")
        }

        var lastFailure = ""
        for raw in target.candidates {
            if Task.isCancelled { return result(.cancelled, "检测已停止") }
            guard let url = URL(string: raw) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            // 只取首段字节，避免上百个书源把整个首页都下载一遍
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...399).contains(code) {
                    let note = (code == 200 || code == 206) ? "" : "（HTTP \(code) 跳转）"
                    return result(.ok, "站点可访问\(note)")
                }
                // 站点活着但拒绝匿名访问：403 常见于反爬 / 需登录，不能据此判失效
                if code == 401 || code == 403 || code == 429 {
                    return result(.ok, "站点可达，拒绝匿名访问（HTTP \(code)，可能需登录或反爬）")
                }
                lastFailure = "HTTP \(code)"
            } catch {
                if Task.isCancelled { return result(.cancelled, "检测已停止") }
                lastFailure = describe(error)
            }
        }
        return result(.failed, lastFailure.isEmpty ? "所有候选地址均无法访问" : lastFailure)
    }

    private static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return "连接超时"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "域名无法解析"
        case NSURLErrorCannotConnectToHost: return "无法连接服务器"
        case NSURLErrorNotConnectedToInternet: return "设备无网络连接"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot: return "证书 / SSL 校验失败"
        case NSURLErrorUnsupportedURL: return "地址格式无效"
        case NSURLErrorBadServerResponse: return "服务器响应异常"
        case NSURLErrorCancelled: return "已取消"
        default: return "网络错误（\(code)）"
        }
    }
}
