import SwiftUI
import WebKit

// MARK: - WebView 呈现请求（startBrowserAwait）

/// 书源 JS 通过 `java.startBrowserAwait(url, title)` 请求打开 WebView
///（起点 Cookie 验证等场景）。全局单例，ContentView 挂载 sheet。
final class WebViewPresenter: ObservableObject {
    static let shared = WebViewPresenter()

    struct Request: Identifiable {
        let id = UUID()
        let url: String
        let title: String
    }

    @Published var request: Request?

    func present(url: String, title: String) {
        request = Request(url: url, title: title)
    }

    /// 用户完成（点击「完成」）后调用：同步 WebView cookie 并唤醒等待中的 JS 桥
    func finish(html: String = "") {
        request = nil
        JsJavaBridge.pendingWebViewBridge?.finishWebView(html: html)
    }

    /// 用户取消
    func cancel() {
        request = nil
        JsJavaBridge.pendingWebViewBridge?.finishWebView(html: "")
    }
}

// MARK: - WebView 页面

/// startBrowserAwait 的 WebView 载体：加载目标页 → 用户操作（登录 / 过验证）→
/// 点「完成」→ WKHTTPCookieStore 的 cookie 回写到 HTTPCookieStorage.shared，
/// 后续请求自动带上（URLSession 默认读写 shared storage）。
struct WebViewSheet: View {
    let request: WebViewPresenter.Request
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                WebViewContainer(urlString: request.url, isLoading: $isLoading)
                if isLoading {
                    ProgressView("加载中…")
                }
            }
            .navigationTitle(request.title.isEmpty ? "网页" : request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        adoptCookiesThen {
                            WebViewPresenter.shared.cancel()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        // 先把 WebView 的 cookie 回写 shared storage，再唤醒 JS 桥，
                        // 保证桥内重抓目标页时能带上新 Cookie（避免竞态）
                        adoptCookiesThen {
                            WebViewPresenter.shared.finish(html: "")
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    /// 把 WKWebView 的 cookie 同步到 HTTPCookieStorage.shared（异步完成后回调）
    private func adoptCookiesThen(_ completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            CookieStore.shared.adopt(cookies)
            DispatchQueue.main.async { completion() }
        }
    }
}

/// WKWebView 的 UIViewRepresentable 封装
struct WebViewContainer: UIViewRepresentable {
    let urlString: String
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            _isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}
