import Foundation
import CommonCrypto
import SwiftSoup
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

// MARK: - 桥错误

enum JsBridgeError: LocalizedError {
    case invalidURL
    case timeout
    case noEngine

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "链接格式不正确"
        case .timeout: return "网络请求超时"
        case .noEngine: return "规则引擎上下文缺失"
        }
    }
}

// MARK: - 响应对象（java.connect / java.get(url, opts) 返回）

/// JS 侧 `.body() / .headers() / .code()` 链式调用（对应 legado StrResponse）
@objc protocol JsResponseExports: JSExport {
    func body() -> String
    func headers() -> [String: String]
    func code() -> Int
    func raw() -> String
    func message() -> String
}

@objc final class JsResponse: NSObject, JsResponseExports {
    private let bodyText: String
    private let headerMap: [String: String]
    private let statusCode: Int
    private let statusMessage: String

    init(body: String, headers: [String: String], code: Int, message: String = "") {
        bodyText = body
        headerMap = headers
        statusCode = code
        statusMessage = message
        super.init()
    }

    func body() -> String { bodyText }
    func headers() -> [String: String] { headerMap }
    func code() -> Int { statusCode }
    func raw() -> String { bodyText }
    func message() -> String { statusMessage }
}

// MARK: - 书源代理（source.*）

@objc protocol JsSourceExports: JSExport {
    func getKey() -> String
    func getVariable() -> String
    func setVariable(_ value: String)
    func getLoginInfoMap() -> [String: String]
    var bookSourceUrl: String { get }
    var bookSourceName: String { get }
    var bookSourceGroup: String { get }
    var bookSourceComment: String { get }
    var loginUrl: String { get }
    var header: String { get }
    var exploreUrl: String { get }
    var searchUrl: String { get }
}

@objc final class JsSource: NSObject, JsSourceExports {
    private let source: BookSource

    init(source: BookSource) {
        self.source = source
        super.init()
    }

    func getKey() -> String { source.bookSourceUrl }

    func getVariable() -> String {
        SourceVariableStore.get(source.bookSourceUrl) ?? source.variable ?? ""
    }

    func setVariable(_ value: String) {
        SourceVariableStore.set(value, for: source.bookSourceUrl)
    }

    func getLoginInfoMap() -> [String: String] { source.loginInfo ?? [:] }

    var bookSourceUrl: String { source.bookSourceUrl }
    var bookSourceName: String { source.bookSourceName }
    var bookSourceGroup: String { source.bookSourceGroup ?? "" }
    var bookSourceComment: String { source.bookSourceComment }
    var loginUrl: String { source.loginUrl ?? "" }
    var header: String { source.header ?? "" }
    var exploreUrl: String { source.exploreUrl ?? "" }
    var searchUrl: String { source.searchUrl ?? "" }
}

// MARK: - 书籍代理（book.*）

@objc protocol JsBookExports: JSExport {
    var bookUrl: String { get }
    var origin: String { get }
    var name: String { get }
    var author: String { get }
    var originName: String { get }
}

@objc final class JsBook: NSObject, JsBookExports {
    private let book: Book

    init(book: Book) {
        self.book = book
        super.init()
    }

    var bookUrl: String { book.bookUrl ?? "" }
    /// legado Book.origin = 书籍在书源上的地址（与 bookUrl 同源）
    var origin: String { book.bookUrl ?? "" }
    var name: String { book.title }
    var author: String { book.author }
    var originName: String { book.originName ?? "" }
}

// MARK: - java.* 桥（对应 legado JsExtensions 常用子集）

/// 注入 JavaScriptCore 的 `java` 对象。
///
/// 与 legado JsExtensions 对齐的常用方法：
/// - 变量：put / get（get 单参为变量读取，带 options 为网络 GET——legado 同名重载的兼容实现）
/// - 网络：ajax / connect / get(url, opts) / post（同步 URLSession + 信号量，JS 无 async）
/// - 规则：getString / getStringList / getElement / setContent
/// - UI：toast / longToast / startBrowserAwait（WebView + cookie 回写）
/// - 编码：base64 / hex / md5 / encodeURI / timeFormat
/// - 其他：androidId / getCookie / setCookie / removeCookie / getVerificationCode / log
@objc protocol JsJavaBridgeExports: JSExport {
    // 变量（单参 get 为变量读取）
    func put(_ key: String, _ value: JSValue?)
    func get(_ keyOrUrl: String, _ options: JSValue?) -> NSObject?
    // 网络
    func ajax(_ url: String, _ headers: JSValue?) -> String
    func connect(_ url: String, _ headers: JSValue?) -> JsResponse
    func post(_ url: String, _ body: JSValue?, _ headers: JSValue?) -> JsResponse
    // 规则
    func getString(_ rule: String, _ isUrl: JSValue?) -> String
    func getStringList(_ rule: String, _ isUrl: JSValue?) -> [String]
    func getElement(_ rule: String) -> [String]
    func getElements(_ rule: String) -> [String]
    func setContent(_ content: JSValue?, _ baseUrl: JSValue?)
    // UI
    func toast(_ message: String)
    func longToast(_ message: String)
    func startBrowserAwait(_ url: String, _ title: String) -> String
    // 编码
    func base64Encode(_ text: String) -> String
    func base64Decode(_ text: String) -> String
    func hexEncode(_ text: String) -> String
    func hexDecode(_ text: String) -> String
    func hexDecodeToString(_ text: String) -> String
    func md5Encode(_ text: String) -> String
    func md5Encode16(_ text: String) -> String
    func encodeURI(_ text: String) -> String
    func decodeURI(_ text: String) -> String
    func timeFormat(_ timestamp: JSValue?) -> String
    // 其他
    func androidId() -> String
    func getCookie(_ url: String) -> String
    func setCookie(_ url: String, _ cookie: String)
    func removeCookie(_ url: String)
    func getVerificationCode(_ hint: String) -> String
    func log(_ message: String)
    func getSource() -> JsSource?
}

@objc final class JsJavaBridge: NSObject, JsJavaBridgeExports {

    // MARK: - 上下文

    weak var engine: RuleEngine?
    weak var jsContext: JSContext?

    var source: BookSource? {
        didSet { sourceProxy = source.map { JsSource(source: $0) } }
    }
    var book: Book? {
        didSet { bookProxy = book.map { JsBook(book: $0) } }
    }
    var baseUrl: String = ""
    var chapterTitle: String = ""
    var nextChapterUrl: String = ""

    /// toast 回调（UI 层注入）
    var toastHandler: ((String) -> Void)?

    private var sourceProxy: JsSource?
    private var bookProxy: JsBook?
    private lazy var cookieProxy: JsCookie = CookieStore.shared.jsProxy

    /// java.getElement 最近一次命中缓存的元素（legado 起点等书源的 bookList <js>
    /// 不返回元素、依赖 getElement 的副作用，此处供 BookListAnalyzer 兜底读取）
    private(set) var lastGetElementResult: [Element] = []

    /// evalJS 绑定用（RuleEngine 读取）
    var sourceProxyForJS: JsSource? { sourceProxy }
    var bookProxyForJS: JsBook? { bookProxy }
    var cookieProxyForJS: JsCookie { cookieProxy }
    var lastGetElementResultForJS: [Element] { lastGetElementResult }

    // MARK: - WebView（startBrowserAwait）

    /// 全局 WebView 呈现回调（App 启动时注入；nil 时降级为直接抓取）
    static var webViewPresenter: ((String, String) -> Void)?
    /// 正在等待 WebView 完成的桥实例（finishWebView 路由用）
    static weak var pendingWebViewBridge: JsJavaBridge?

    private let webViewLock = NSLock()
    private var webViewSemaphore: DispatchSemaphore?
    private var webViewHTML: String = ""

    // MARK: - 同步网络（JavaScriptCore 无 Continuation，用信号量等待 async 请求）

    private final class Box {
        var result: Result<(String, [String: String], Int), Error>?
    }

    /// 同步执行 async 网络请求。Task.detached 避免继承调用方 actor 上下文导致死锁；
    /// 桥内统一入口、统一超时，禁止在桥内再嵌套 async 回调。
    private func runSyncNetwork(timeout: TimeInterval = 20,
                                _ body: @escaping () async throws -> (String, [String: String], Int)) throws -> (String, [String: String], Int) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        let task = Task.detached {
            do {
                box.result = .success(try await body())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw JsBridgeError.timeout
        }
        return try box.result!.get()
    }

    private func performSyncRequest(urlString: String,
                                    method: String,
                                    body: Data?,
                                    headers: [String: String]) throws -> (String, [String: String], Int) {
        guard let url = URLSanitizer.sanitize(urlString) ?? URL(string: urlString) else {
            throw JsBridgeError.invalidURL
        }
        let (data, response) = try runSyncNetwork {
            if method == "POST" || body != nil {
                return try await NetworkService.shared.fetchDataWithBody(
                    from: url, method: method, body: body, headers: headers
                )
            }
            return try await NetworkService.shared.fetchData(from: url, headers: headers)
        }
        let text = (try? NetworkService.decodeText(data)) ?? ""
        var headerMap: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String {
                headerMap[key] = String(describing: value)
            }
        }
        return (text, headerMap, response.statusCode)
    }

    /// 在 JS 上下文抛出异常（桥内禁止 throws，统一转 JS 异常）
    private func raise(_ message: String) {
        #if canImport(JavaScriptCore)
        guard let context = jsContext else { return }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
        #endif
    }

    // MARK: - 选项解析

    private struct RequestOptions {
        var method: String?
        var body: String?
        var headers: [String: String] = [:]
    }

    /// JS 选项对象 → 请求参数。
    /// 兼容两种形态：`{headers:{...}, method:...}` 与直接把键当请求头（legado java.get(url, headerMap)）。
    private func parseOptions(_ options: JSValue?) -> RequestOptions {
        guard let options, !options.isUndefined, !options.isNull,
              let dict = options.toObject() as? [String: Any] else {
            return RequestOptions()
        }
        var result = RequestOptions()
        if let method = dict["method"] as? String { result.method = method.uppercased() }
        if let body = dict["body"] { result.body = String(describing: body) }
        if let headers = dict["headers"] as? [String: Any] {
            for (key, value) in headers { result.headers[key] = String(describing: value) }
        } else {
            for (key, value) in dict where key != "method" && key != "body" {
                result.headers[key] = String(describing: value)
            }
        }
        return result
    }

    /// body 参数编码：字符串原样；字典按表单编码
    private func encodeBody(_ body: JSValue?, fallback: String?) -> Data? {
        if let body, !body.isUndefined, !body.isNull {
            if let text = body.toString() { return text.data(using: .utf8) }
            if let dict = body.toObject() as? [String: Any] {
                let form = dict.map { "\($0.key)=\(String(describing: $0.value))" }.joined(separator: "&")
                return form.data(using: .utf8)
            }
        }
        return fallback?.data(using: .utf8)
    }

    private func isURLLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || text.contains("://")
    }

    // MARK: - 变量

    func put(_ key: String, _ value: JSValue?) {
        engine?.put(key, value?.toString() ?? "")
    }

    /// 单参 = 变量读取（legado java.get(key)）；带 options 或 URL 形态 = 网络 GET
    func get(_ keyOrUrl: String, _ options: JSValue?) -> NSObject? {
        let hasOptions = options.map { !$0.isUndefined && !$0.isNull } ?? false
        if !hasOptions && !isURLLike(keyOrUrl) {
            return engine?.get(keyOrUrl) ?? ""
        }
        let parsed = parseOptions(options)
        do {
            let (text, headers, code) = try performSyncRequest(
                urlString: keyOrUrl, method: parsed.method ?? "GET", body: nil, headers: parsed.headers
            )
            return JsResponse(body: text, headers: headers, code: code)
        } catch {
            raise(error.localizedDescription)
            return nil
        }
    }

    // MARK: - 网络

    func ajax(_ url: String, _ headers: JSValue?) -> String {
        let parsed = parseOptions(headers)
        do {
            let (text, _, _) = try performSyncRequest(
                urlString: url, method: parsed.method ?? "GET", body: nil, headers: parsed.headers
            )
            return text
        } catch {
            raise(error.localizedDescription)
            return ""
        }
    }

    func connect(_ url: String, _ headers: JSValue?) -> JsResponse {
        let parsed = parseOptions(headers)
        do {
            let (text, headerMap, code) = try performSyncRequest(
                urlString: url, method: parsed.method ?? "GET", body: nil, headers: parsed.headers
            )
            return JsResponse(body: text, headers: headerMap, code: code)
        } catch {
            raise(error.localizedDescription)
            return JsResponse(body: "", headers: [:], code: 0)
        }
    }

    func post(_ url: String, _ body: JSValue?, _ headers: JSValue?) -> JsResponse {
        let parsed = parseOptions(headers)
        let bodyData = encodeBody(body, fallback: parsed.body)
        do {
            let (text, headerMap, code) = try performSyncRequest(
                urlString: url, method: "POST", body: bodyData, headers: parsed.headers
            )
            return JsResponse(body: text, headers: headerMap, code: code)
        } catch {
            raise(error.localizedDescription)
            return JsResponse(body: "", headers: [:], code: 0)
        }
    }

    // MARK: - 规则

    func getString(_ rule: String, _ isUrl: JSValue?) -> String {
        guard let engine else {
            raise(JsBridgeError.noEngine.localizedDescription)
            return ""
        }
        return (try? engine.getString(rule, content: engine.currentContent())) ?? ""
    }

    func getStringList(_ rule: String, _ isUrl: JSValue?) -> [String] {
        guard let engine else {
            raise(JsBridgeError.noEngine.localizedDescription)
            return []
        }
        return (try? engine.getStringList(rule, content: engine.currentContent())) ?? []
    }

    func getElement(_ rule: String) -> [String] {
        guard let engine else { return [] }
        guard let elements = try? HtmlRuleEngine.shared.elements(rule, rootHTML: engine.currentContent()) else {
            lastGetElementResult = []
            return []
        }
        lastGetElementResult = elements
        return elements.map { (try? $0.outerHtml()) ?? "" }
    }

    func getElements(_ rule: String) -> [String] {
        getElement(rule)
    }

    /// 替换当前解析内容与 baseUrl（对应 legado java.setContent）
    func setContent(_ content: JSValue?, _ baseUrl: JSValue?) {
        if let text = content?.toString() {
            engine?.jsContent = text
        }
        if let base = baseUrl?.toString(), !base.isEmpty {
            self.baseUrl = base
        }
    }

    // MARK: - UI

    func toast(_ message: String) {
        print("[js-toast] \(message)")
        toastHandler?(message)
    }

    func longToast(_ message: String) {
        toast(message)
    }

    /// 打开 WebView 等待用户完成操作（起点 Cookie 验证流），
    /// 完成后带回 Cookie 重新抓取目标页并返回 HTML。
    /// 同步等待上限 120s；无 UI 附着时降级为直接抓取。
    func startBrowserAwait(_ url: String, _ title: String) -> String {
        guard let presenter = Self.webViewPresenter else {
            return (try? performSyncRequest(urlString: url, method: "GET", body: nil, headers: [:]).0) ?? ""
        }
        let semaphore = DispatchSemaphore(value: 0)
        webViewLock.lock()
        webViewSemaphore = semaphore
        webViewHTML = ""
        webViewLock.unlock()

        Self.pendingWebViewBridge = self
        DispatchQueue.main.async {
            presenter(url, title)
        }

        guard semaphore.wait(timeout: .now() + 120) == .success else {
            webViewLock.lock()
            webViewSemaphore = nil
            webViewLock.unlock()
            if Self.pendingWebViewBridge === self { Self.pendingWebViewBridge = nil }
            return ""
        }
        let html = webViewHTML
        if !html.isEmpty { return html }
        // WebView 未返回 HTML 时，用新 Cookie 重抓目标页
        return (try? performSyncRequest(urlString: url, method: "GET", body: nil, headers: [:]).0) ?? ""
    }

    /// WebView 完成时调用（UI 层），唤醒等待中的 JS
    func finishWebView(html: String) {
        webViewLock.lock()
        webViewHTML = html
        let semaphore = webViewSemaphore
        webViewSemaphore = nil
        webViewLock.unlock()
        semaphore?.signal()
    }

    // MARK: - 编码

    func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    func base64Decode(_ text: String) -> String {
        guard let data = Data(base64Encoded: text) else { return "" }
        if let value = String(data: data, encoding: .utf8) { return value }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: gb)) ?? ""
    }

    func hexEncode(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    func hexDecode(_ text: String) -> String {
        let characters = Array(text)
        var bytes: [UInt8] = []
        var index = 0
        while index + 1 < characters.count {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return ""
            }
            bytes.append(byte)
            index += 2
        }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    func hexDecodeToString(_ text: String) -> String {
        hexDecode(text)
    }

    func md5Encode(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// legado md5Encode16 = md5 十六进制串的 [8, 24) 段
    func md5Encode16(_ text: String) -> String {
        let full = md5Encode(text)
        guard full.count >= 24 else { return full }
        return String(full[full.index(full.startIndex, offsetBy: 8)..<full.index(full.startIndex, offsetBy: 24)])
    }

    func encodeURI(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    func decodeURI(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// 时间戳格式化（秒 / 毫秒自动识别）
    func timeFormat(_ timestamp: JSValue?) -> String {
        guard let value = timestamp?.toDouble(), value > 0 else { return "" }
        let interval = value > 1e11 ? value / 1000 : value
        let date = Date(timeIntervalSince1970: interval)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    // MARK: - 其他

    func androidId() -> String {
        let key = "legado.androidId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    func getCookie(_ url: String) -> String {
        CookieStore.shared.getCookie(url)
    }

    func setCookie(_ url: String, _ cookie: String) {
        CookieStore.shared.setCookie(url, cookie)
    }

    func removeCookie(_ url: String) {
        CookieStore.shared.removeCookie(url)
    }

    /// 短信验证码（需用户输入，iOS 版暂不支持，返回空并提示）
    func getVerificationCode(_ hint: String) -> String {
        toast(hint.isEmpty ? "当前书源需要验证码，iOS 版暂不支持自动获取" : hint)
        return ""
    }

    func log(_ message: String) {
        print("[rule-js] \(message)")
    }

    func getSource() -> JsSource? {
        sourceProxy
    }
}
