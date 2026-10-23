import Foundation
import CoreFoundation

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
            return "无法解码返回内容（非文本编码）"
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
/// - UTF-8 优先、GB18030 兜底，覆盖中文站点编码；
/// - 调用方通过 `headers` 传入书源自定义请求头（对应 legado 的 header 字段）。
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
        ]
        session = URLSession(configuration: config)
    }

    // MARK: - 公开接口

    /// 抓取远端文本（UTF-8 / GB18030 解码，自动去除 BOM 与首尾空白）
    func fetchText(from url: URL,
                   headers: [String: String]? = nil,
                   timeout: TimeInterval? = nil) async throws -> String {
        let data = try await fetchDataWithResponse(from: url, headers: headers, timeout: timeout).0
        return try Self.decodeText(data)
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
        let data = try await performRequest(url: url, headers: headers, timeout: timeout)
        return data
    }

    // MARK: - 内部

    private func performRequest(url: URL,
                                headers: [String: String]?,
                                timeout: TimeInterval?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout ?? Self.defaultTimeout
        request.setValue(Self.iPhoneUA, forHTTPHeaderField: "User-Agent")
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
            return (data, http)
        } catch let error as NetworkError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw NetworkError.timeout
            case .cancelled:
                throw NetworkError.cancelled
            default:
                throw NetworkError.network(urlError.localizedDescription)
            }
        } catch {
            throw NetworkError.network(error.localizedDescription)
        }
    }

    // MARK: - 编码 / 工具

    /// 文本解码：UTF-8 优先，GB18030 兜底（覆盖中文站点），并去除 BOM 与首尾空白
    static func decodeText(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) {
            return Self.stripBOM(text)
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return Self.stripBOM(text)
        }
        throw NetworkError.encodingFailed
    }

    /// 去除 UTF-8 BOM 并修剪首尾空白
    static func stripBOM(_ text: String) -> String {
        var s = text
        if s.hasPrefix("\u{FEFF}") {
            s.removeFirst()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}