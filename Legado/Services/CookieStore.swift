import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

// MARK: - JS 代理对象（cookie.*）

/// 注入 JS 的 `cookie` 对象（对应 legado CookieStore 的常用方法）
@objc protocol JsCookieExports: JSExport {
    func getCookie(_ url: String) -> String
    func setCookie(_ url: String, _ cookie: String)
    func removeCookie(_ url: String)
    func cookie(_ url: String) -> String
}

@objc final class JsCookie: NSObject, JsCookieExports {
    private let store = CookieStore.shared

    func getCookie(_ url: String) -> String { store.getCookie(url) }
    func setCookie(_ url: String, _ cookie: String) { store.setCookie(url, cookie) }
    func removeCookie(_ url: String) { store.removeCookie(url) }
    func cookie(_ url: String) -> String { store.getCookie(url) }
}

// MARK: - Cookie 存储

/// 按域管理的 Cookie 存储（对接系统 HTTPCookieStorage.shared）。
///
/// URLSession 默认自动读写 shared storage（请求自动携带、响应自动落盘）；
/// 本类提供书源级的显式操作：
/// - JS 侧 `cookie.getCookie / setCookie / removeCookie`（起点等验证流依赖）；
/// - startBrowserAwait 的 WKWebView cookie 回写（WKHTTPCookieStore 与 shared 隔离）。
///
/// 注意：JS 代理 `JsCookie` **每引擎实例新建**（不在此类共享）——
/// JSCore 对同一 ObjC 对象在多个 JSContext 的并发导出非线程安全。
final class CookieStore {
    static let shared = CookieStore()

    private let storage = HTTPCookieStorage.shared

    /// 取某 URL 域下的 Cookie，返回 "k=v; k2=v2"
    func getCookie(_ url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        let cookies = storage.cookies(for: u) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 设置 Cookie（支持 "k=v; k2=v2" 批量）
    func setCookie(_ url: String, _ cookie: String) {
        guard let u = URL(string: url), let host = u.host else { return }
        for pair in cookie.components(separatedBy: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/",
            ]
            if u.scheme?.lowercased() == "https" {
                properties[.secure] = "YES"
            }
            if let httpCookie = HTTPCookie(properties: properties) {
                storage.setCookie(httpCookie)
            }
        }
    }

    /// 删除某 URL 域下的所有 Cookie
    func removeCookie(_ url: String) {
        guard let u = URL(string: url), let host = u.host else { return }
        for cookie in storage.cookies ?? []
        where cookie.domain == host || host.hasSuffix(cookie.domain) {
            storage.deleteCookie(cookie)
        }
    }

    /// 从 WKWebView 加载产生的 cookie 列表回写到 shared storage
    ///（startBrowserAwait 完成后调用，使后续请求带上 WebView 获得的 Cookie）
    func adopt(_ webViewCookies: [HTTPCookie]) {
        for cookie in webViewCookies {
            storage.setCookie(cookie)
        }
    }
}

// MARK: - 书源级变量存储

/// `source.getVariable() / setVariable()` 的持久化（UserDefaults，按书源 URL 隔离）。
/// 对应 legado BaseSource.variable（明文存储于书源表）。
enum SourceVariableStore {
    private static let prefix = "legado.sourceVariable."

    static func get(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + key)
    }

    static func set(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: prefix + key)
    }
}
