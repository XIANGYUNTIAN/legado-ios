import Foundation
import UIKit
import WebKit

/// 影视站点搜索页的「浏览器渲染兜底」（v47）。
///
/// 公子 11-06 第四轮反馈：v46 用纯 HTTP 抓站内搜索页仍是 0 结果，但点
/// 「站点直达」在网页里能搜到同名剧、点开就能播。两者请求的是同一个 URL，
/// 差别只在「有没有浏览器环境」——搜索结果由页面 JS 渲染，或站点对非
/// WebView 请求返回拦截页。规则解析、正则、JSONPath 都拿不到 DOM 后的内容。
///
/// 复用 v44 漫画已真机验证的机制：隐藏 WKWebView 真实加载并执行页面脚本，
/// 从渲染后的 DOM 收集 a[href] 的文本与绝对地址，交给 SiteSearchService
/// 按关键词 + 详情路径特征过滤。只在 HTTP 抽取 0 命中时才串行调用。
struct DomLink: Sendable {
    let title: String
    let href: String
}

final class SiteDomProbe: NSObject, WKNavigationDelegate {

    /// 强引用在途探针，避免 continuation 完成前被释放
    private static var active: [SiteDomProbe] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[[String]], Never>?
    private var finished = false

    private static let collectJS = """
    (function(){
      var out = [];
      var els = document.querySelectorAll('a[href]');
      for (var i=0;i<els.length && i<900;i++){
        var el = els[i];
        var t = (el.innerText || el.textContent || '').replace(/\\s+/g,' ').trim();
        if (!t) { t = el.getAttribute('title') || ''; }
        if (!t) {
          var img = el.querySelector('img');
          if (img) { t = img.getAttribute('alt') || img.getAttribute('title') || ''; }
        }
        t = (t || '').replace(/\\s+/g,' ').trim().substring(0,80);
        var h = el.getAttribute('href') || '';
        if (!h || !t) continue;
        try { h = new URL(h, location.href).href; } catch(e){}
        out.push([t, h]);
      }
      return out;
    })();
    """

    /// 隐藏 WebView 加载搜索页，返回渲染后的 (锚文本, 绝对链接) 对。
    static func links(from pageURL: URL,
                      referer: String,
                      timeout: TimeInterval = 7) async -> [DomLink] {
        let pairs: [[String]] = await withCheckedContinuation {
            (cont: CheckedContinuation<[[String]], Never>) in
            // WKWebView 必须在主线程创建；continuation 的同步闭包不保证线程。
            Task { @MainActor in
                let probe = SiteDomProbe()
                Self.active.append(probe)
                probe.start(pageURL: pageURL, referer: referer,
                            timeout: timeout, continuation: cont)
            }
        }
        return pairs.compactMap { pair -> DomLink? in
            guard pair.count == 2 else { return nil }
            return DomLink(title: pair[0], href: pair[1])
        }
    }

    private func start(pageURL: URL,
                       referer: String,
                       timeout: TimeInterval,
                       continuation: CheckedContinuation<[[String]], Never>) {
        self.continuation = continuation
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                           configuration: config)
        wv.isHidden = true
        wv.customUserAgent = NetworkService.iPhoneUA
        wv.navigationDelegate = self
        self.webView = wv

        var request = URLRequest(url: pageURL)
        request.setValue(NetworkService.iPhoneUA, forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        wv.load(request)

        // 硬超时必须归还 continuation，页面脚本卡死也要收口
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.collect()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self.collect()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish([])
    }

    private func collect() {
        guard !finished, let wv = webView else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.finish([])
        }
        wv.evaluateJavaScript(Self.collectJS) { [weak self] result, _ in
            var values: [[String]] = []
            if let arr = result as? [[String]] {
                values = arr
            } else if let arr = result as? [Any] {
                for item in arr {
                    if let pair = item as? [String], pair.count == 2 {
                        values.append(pair)
                    }
                }
            }
            Task { @MainActor in self?.finish(values) }
        }
    }

    private func finish(_ values: [[String]]) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: values)
        continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        Self.active.removeAll { $0 === self }
    }
}
