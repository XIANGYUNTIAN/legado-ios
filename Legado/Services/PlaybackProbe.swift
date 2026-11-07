import Foundation
import UIKit
import WebKit

// MARK: - 详情页播放地址嗅探（v48 → v51）
//
// v50 真机第八轮反馈：点 ▶ 落到详情页网页（huangguoai.fit/series/pb807qyz），
// 页面里有「开始观看」和 1–10 集按钮，却不是原生播放器。根因是 v48/v50 的
// 探针只「加载详情页就收 performance」，而这些站的播放器要点开始观看 /
// 选集才初始化并发起 m3u8 —— 加载阶段必然 0 命中，于是降级打开网页。
//
// v51 复刻用户点击路径：详情页渲染完主动点「开始播放 / 第1集」或导航到
// 播放页，等最后一次导航稳定后再收真实直链；超时 8 → 13s。collectJS 增扫
// 全元素 data-url / data-src / onclick 里被 JS 拼出来的地址。
// 仍用 VodPlaylistParser.isMedia 统一过滤，排除搜索页与空参数解析接口。

final class PlaybackProbe: NSObject, WKNavigationDelegate {

    /// 强引用在途探针，避免 continuation 完成前被释放
    private static var active: [PlaybackProbe] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String], Never>?
    private var finished = false
    private var collecting = false
    private var navCount = 0
    private var collectGeneration = 0

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
      var attrs = ['src','data-src','data-url','data-play','data-m3u8',
                   'href','onclick','data-clipboard-text'];
      var els = document.querySelectorAll('*');
      for (var j = 0; j < els.length && j < 3000; j++) {
        var e = els[j];
        for (var k = 0; k < attrs.length; k++) {
          var v = e.getAttribute(attrs[k]);
          if (!v) continue;
          if (k >= 6) {
            var rx = /https?:\/\/[^\s"'<>()]+/g, m;
            while ((m = rx.exec(v)) !== null) push(m[0]);
          } else {
            push(v);
          }
        }
      }
      var html = document.documentElement ? document.documentElement.outerHTML : '';
      var rx2 = /https?:\/\/[^\s"'<>]+/g, m2;
      while ((m2 = rx2.exec(html)) !== null) { push(m2[0]); }
      return out;
    })();
    """#

    /// v51：主动触发播放入口，复刻用户在详情页里点的那一下。
    /// 优先文本明确的「开始观看 / 立即播放 / 第1集」，再兜底导航到播放页链接。
    private static let clickJS = #"""
    (function(){
      var els = document.querySelectorAll(
        'a,button,[role="button"],[onclick],[data-url],div,span,li');
      for (var j = 0; j < els.length && j < 800; j++) {
        var e = els[j];
        var t = (e.innerText || e.textContent || '').replace(/\s+/g,'').trim();
        if (!t || t.length > 12) continue;
        if (/开始观看|立即播放|播放正片|点击播放|马上观看|在线播放|观看正片|立即观看|^播放$|^第?0?1集?$|^1$/i.test(t)) {
          try { e.click(); return 'click:' + t; } catch(err) {}
        }
      }
      var as = document.querySelectorAll('a[href]');
      for (var i = 0; i < as.length && i < 600; i++) {
        var h = as[i].getAttribute('href') || '';
        if (!h || h.indexOf('javascript') === 0) continue;
        if (/[?&](ep|eid|play|playid)=/i.test(h)
            || /\/(watch|play|episode|player)\//i.test(h)) {
          try { location.href = new URL(h, location.href).href; return 'nav-play-link'; }
          catch(e) {}
        }
      }
      return 'noentry';
    })();
    """#

    /// 加载详情页，返回可直接交给播放器的绝对地址（已过滤、已去重）。
    static func mediaURLs(from pageURL: URL,
                          referer: String,
                          timeout: TimeInterval = 13) async -> [URL] {
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
            // v54：解析页 URL 要解包成内层真实媒体地址再交给播放器。
            guard let u = URLSanitizer.sanitize(s),
                  let play = VodPlaylistParser.normalizedMediaURL(u) else { continue }
            let key = play.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(play)
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
        navCount += 1
        if navCount == 1 {
            // 详情页渲染完，等脚本把播放按钮画出来再主动点
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self.triggerPlayback()
            }
        } else {
            // 点击引发的导航：每次新页面都重置计时，只在最后一次稳定后收资源
            scheduleCollect(delay: 3_500_000_000)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 只有首页加载失败才立即收口；点击后的子资源失败交给硬超时
        if navCount == 0 { finish([]) }
    }

    private func scheduleCollect(delay: UInt64) {
        collectGeneration += 1
        let gen = collectGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            if gen == self.collectGeneration { self.collect() }
        }
    }

    private func triggerPlayback() {
        guard !finished, let wv = webView else { return }
        // location.href 导航会让 evaluateJavaScript 的 completion 丢失，不依赖回调
        wv.evaluateJavaScript(Self.clickJS) { _, _ in }
    }

    private func collect() {
        guard !finished, !collecting, let wv = webView else { return }
        collecting = true
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
