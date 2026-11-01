import Foundation
import WebKit

/// 视频书源嗅探器（对应 legado 的 sourceRegex / webJs 嗅探链路）。
///
/// iOS 没有 Android WebView 的 shouldInterceptRequest 透明拦截能力，只能用 WKWebView
/// 加载章节页后注入 JS，hook video/source 元素与 fetch/XHR 请求，收集媒体直链，
/// 再用 sourceRegex 过滤取首个候选。
///
/// webJs 仅在它是「纯 JS、返回 URL 或 URL 数组」时执行并优先采用；复杂 DSL（依赖 legado
/// 注入的 java 全局对象）暂不复刻——这类源将退回标签扫描结果。
final class WebViewSniffer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    private var webView: WKWebView?
    private var completion: (([URL]) -> Void)?
    private var candidates: [URL] = []
    private var seen = Set<String>()
    private var timer: Timer?
    private var sourceRegex: NSRegularExpression?
    private var webJs: String?

    private static let sniffScript = """
    (function(){
      function post(u){
        if(!u) return;
        u = String(u);
        if(u.indexOf('http') !== 0) return;
        window.webkit.messageHandlers.sniffer.postMessage(u);
      }
      function mediaExt(u){
        try { var p = new URL(u).pathname.toLowerCase(); }
        catch(e){ return true; }
        return /\\.(mp4|m3u8|mpd|flv|ts|mkv|webm|mov|avi|m4v)(\\?|$)/.test(p)
            || /(m3u8|mpd|flv|\\.ts|play|media|video)/.test(u.toLowerCase());
      }
      function scan(){
        var els = document.querySelectorAll('video,audio,source');
        for(var i=0;i<els.length;i++){
          var el = els[i];
          var s = el.src || el.currentSrc || el.getAttribute('src') || el.getAttribute('data-src');
          if(s) post(s);
          if(el.currentSrc) post(el.currentSrc);
        }
      }
      var _fetch = window.fetch;
      window.fetch = function(input, init){
        var u = (typeof input === 'string') ? input : (input && input.url);
        if(u && mediaExt(u)) post(u);
        return _fetch.apply(this, arguments);
      };
      var _open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; return _open.apply(this, arguments); };
      var _send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(){
        if(this.__u && mediaExt(this.__u)) post(this.__u);
        return _send.apply(this, arguments);
      };
      scan();
      setInterval(scan, 800);
      window.addEventListener('load', function(){ setTimeout(scan, 400); });
    })();
    """

    func sniff(pageURL: URL,
               headers: [String: String]?,
               sourceRegexPattern: String?,
               webJs: String?,
               timeout: TimeInterval = 15,
               completion: @escaping ([URL]) -> Void) {
        self.completion = completion
        self.candidates = []
        self.seen.removeAll()
        self.webJs = webJs
        if let p = sourceRegexPattern, !p.isEmpty {
            self.sourceRegex = try? NSRegularExpression(pattern: p)
        }

        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(self, name: "sniffer")
        let script = WKUserScript(source: WebViewSniffer.sniffScript,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        uc.addUserScript(script)
        config.userContentController = uc
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true
        wv.navigationDelegate = self
        let ua = headers?["User-Agent"]
            ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.customUserAgent = ua
        self.webView = wv

        var req = URLRequest(url: pageURL)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        headers?.forEach { k, v in
            if k.lowercased() != "user-agent" { req.setValue(v, forHTTPHeaderField: k) }
        }
        wv.load(req)

        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.finish()
        }
    }

    private func addCandidate(_ url: URL) {
        let key = url.absoluteString
        guard !seen.contains(key) else { return }
        if let rx = sourceRegex {
            let range = NSRange(key.startIndex..., in: key)
            if rx.firstMatch(in: key, range: range) == nil { return }
        } else {
            let lower = key.lowercased()
            let isMedia = lower.contains(".mp4") || lower.contains(".m3u8")
                || lower.contains(".mpd") || lower.contains(".flv") || lower.contains(".ts")
                || lower.contains(".webm") || lower.contains(".mkv")
                || lower.contains("m3u8") || lower.contains("mpd")
            if !isMedia { return }
        }
        seen.insert(key)
        candidates.append(url)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let u = URLSanitizer.sanitize(message.body as? String ?? ""),
           u.scheme == "http" || u.scheme == "https" {
            addCandidate(u)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let js = webJs, !js.isEmpty {
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                self?.collectWebJsResult(result)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.finish() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.finish()
            }
        }
    }

    private func collectWebJsResult(_ result: Any?) {
        guard let result else { return }
        let urls: [String]
        if let s = result as? String { urls = [s] }
        else if let arr = result as? [String] { urls = arr }
        else if let dict = result as? [String: Any], let s = dict["url"] as? String { urls = [s] }
        else { return }
        for s in urls {
            if let u = URLSanitizer.sanitize(s), u.scheme == "http" || u.scheme == "https" {
                addCandidate(u)
            }
        }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        let result = candidates
        completion?(result)
        completion = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
        webView = nil
    }
}
