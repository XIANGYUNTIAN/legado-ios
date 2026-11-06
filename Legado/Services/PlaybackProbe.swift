import Foundation
import UIKit
import WebKit

// MARK: - 详情页播放地址嗅探（v48）
//
// 公子 11-06 第五轮反馈：搜索结果点 ▶ 之后，要么落到「网页里的搜索页」，
// 要么弹出「第1集 https://api.xxx.com/m3u8/?url=」这种参数为空的解析接口，
// 都不是能直接播放的地址。根因有两层：
//   ① 结果行的 bookUrl 是搜索页 / 采集接口，不是影片详情页；
//   ② 纯 HTTP 抓详情页拿不到 JS 解密后才出现的播放地址。
//
// 这里只负责第 ② 层：把**详情页**放进隐藏 WKWebView 真实渲染，等页面脚本
// 把播放器初始化完，从三处收真实直链：
//   ① performance resource entries —— JS 动态发起的 m3u8/mp4 一定在这里，
//      即便地址被加密、只在内存里拼出来也能拿到（比解析 HTML 强得多）；
//   ② video / source / iframe 的 src 与 data-src；
//   ③ 渲染后 DOM 源码里的明文媒体地址（兼容 player_aaaa 解密后写回 DOM）。
// 再用 VodPlaylistParser.isMedia 统一过滤，排除搜索页与空参数解析接口。
//
// 机制复用 v44 漫画 / v47 站内搜索已真机验证的隐藏 WebView 方案。

final class PlaybackProbe: NSObject, WKNavigationDelegate {

    /// 强引用在途探针，避免 continuation 完成前被释放
    private static var active: [PlaybackProbe] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String], Never>?
    private var finished = false

    private static let collectJS = #"""
    (function(){
      var out = [], seen = {};
      function push(u){
        if (!u || typeof u !== 'string') return;
        try { u = new URL(u, location.href).href; } catch(e) { return; }
        if (!/^https?:/i.test(u) || seen[u]) return;
        seen[u] = 1; out.push(u);
      }
      try {
        var res = performance.getEntriesByType('resource') || [];
        for (var i = 0; i < res.length; i++) push(res[i].name);
      } catch(e) {}
      var els = document.querySelectorAll('video, source, iframe');
      for (var j = 0; j < els.length; j++) {
        var e = els[j];
        push(e.getAttribute('src'));
        push(e.getAttribute('data-src'));
        push(e.getAttribute('data-url'));
      }
      var html = document.documentElement ? document.documentElement.outerHTML : '';
      var rx = /https?:\/\/[^\s"'<>]+/g, m;
      while ((m = rx.exec(html)) !== null) { push(m[0]); }
      return out;
    })();
    """#

    /// 加载详情页，返回可直接交给播放器的绝对地址（已过滤、已去重）。
    static func mediaURLs(from pageURL: URL,
                          referer: String,
                          timeout: TimeInterval = 8) async -> [URL] {
        let raw: [String] = await withCheckedContinuation {
            (cont: CheckedContinuation<[String], Never>) in
            // WKWebView 必须在主线程创建；continuation 的同步闭包不保证线程。
            Task { @MainActor in
                let probe = PlaybackProbe()
                Self.active.append(probe)
                probe.start(pageURL: pageURL, referer: referer,
                            timeout: timeout, continuation: cont)
            }
        }
        var seen = Set<String>()
        var out: [URL] = []
        for item in raw {
            let s = item.replacingOccurrences(of: "\\/", with: "/")
            guard let u = URLSanitizer.sanitize(s), VodPlaylistParser.isMedia(u) else { continue }
            let key = u.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(u)
            if out.count >= 20 { break }
        }
        return out
    }

    private func start(pageURL: URL,
                       referer: String,
                       timeout: TimeInterval,
                       continuation: CheckedContinuation<[String], Never>) {
        self.continuation = continuation
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
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
        // 播放器常在 DOMContentLoaded 之后才发起请求，留足脚本执行时间
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.collect()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish([])
    }

    private func collect() {
        guard !finished, let wv = webView else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.finish([])
        }
        wv.evaluateJavaScript(Self.collectJS) { [weak self] result, _ in
            var values: [String] = []
            if let arr = result as? [String] {
                values = arr
            } else if let arr = result as? [Any] {
                for item in arr {
                    if let s = item as? String { values.append(s) }
                }
            }
            Task { @MainActor in self?.finish(values) }
        }
    }

    private func finish(_ values: [String]) {
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
