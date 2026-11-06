import Foundation
import UIKit
import WebKit

/// 漫画章节页 JS 渲染兜底（v44）。
///
/// 公子 11-06 反馈「漫画还是看不了」：实测卡拉漫画章节页
/// （/chapter/67213-2-1.html）把图片地址加密进 `player_aaaa` 的 `url` 字段
/// （encrypt=3），由 playerconfig.js 解密后才插入 <img>；服务端返回的 HTML
/// 里连一个 img 标签都没有，规则引擎与正则提取都不可能拿到图片。
///
/// 这里用一个隐藏 WKWebView 真实加载并执行页面脚本，再从渲染后的 DOM 收集
/// img / source 的 src、data-original、data-src、srcset，交给 ComicPageDetector
/// 过滤封面与噪音图。只在「规则结果 + 原始 HTML 都取不到图」时才调用，
/// 不拖慢普通小说与视频章节。
final class ComicPageProbe: NSObject, WKNavigationDelegate {

    /// 强引用在途探针，避免 continuation 完成前被释放
    private static var active: [ComicPageProbe] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String], Never>?
    private var finished = false

    /// 触发常见懒加载：把 data-original / data-src 提前写回 src，
    /// 并模拟滚动覆盖 IntersectionObserver 型图床。
    private static let triggerJS = """
    (function(){
      var els = document.querySelectorAll('img, source');
      for (var i=0;i<els.length;i++){
        var el = els[i];
        var v = el.getAttribute('data-original') || el.getAttribute('data-src')
             || el.getAttribute('data-lazy-src') || el.getAttribute('data-url');
        if (v && !el.getAttribute('src')) { try { el.setAttribute('src', v); } catch(e){} }
      }
      try { window.scrollTo(0, 900); } catch(e){}
      setTimeout(function(){ try { window.scrollTo(0, 2400); } catch(e){} }, 500);
    })();
    """

    /// 收集渲染后 DOM 里的图片地址，全部补成绝对 URL
    private static let collectJS = """
    (function(){
      var out = [];
      var keys = ['src','data-original','data-src','data-lazy-src',
                  'data-url','data-echo','srcset','data-srcset'];
      var els = document.querySelectorAll('img, source, [data-original], [data-src]');
      for (var i=0;i<els.length;i++){
        var el = els[i];
        if (el.currentSrc) out.push(el.currentSrc);
        for (var k=0;k<keys.length;k++){
          var v = el.getAttribute ? el.getAttribute(keys[k]) : null;
          if (!v) continue;
          var parts = String(v).split(',');
          for (var p=0;p<parts.length;p++){
            var piece = parts[p].replace(/^\\s+|\\s+$/g, '');
            var u = piece.split(/\\s+/)[0];
            if (!u) continue;
            try { u = new URL(u, location.href).href; } catch(e){}
            out.push(u);
          }
        }
      }
      return out;
    })();
    """

    /// 在隐藏 WebView 中加载章节页并返回候选图片地址（绝对 URL 数组）。
    static func imageURLStrings(from pageURL: URL,
                                headers: [String: String],
                                timeout: TimeInterval = 9) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            // WKWebView 必须在主线程创建；withCheckedContinuation 的同步闭包
            // 不保证线程，显式切回 MainActor。
            Task { @MainActor in
                let probe = ComicPageProbe()
                Self.active.append(probe)
                probe.start(pageURL: pageURL, headers: headers,
                            timeout: timeout, continuation: cont)
            }
        }
    }

    private func start(pageURL: URL,
                       headers: [String: String],
                       timeout: TimeInterval,
                       continuation: CheckedContinuation<[String], Never>) {
        self.continuation = continuation
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.triggerJS,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        config.userContentController = controller
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                           configuration: config)
        wv.isHidden = true
        wv.navigationDelegate = self
        let ua = headers["User-Agent"] ?? NetworkService.iPhoneUA
        wv.customUserAgent = ua
        self.webView = wv

        var request = URLRequest(url: pageURL)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers where key.lowercased() != "user-agent" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        wv.load(request)

        // 双重收口：加载完成后等 JS 解密 / 懒加载；超时也必须归还 continuation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.collect()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            self.collect()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish([])
    }

    private func collect() {
        guard !finished, let wv = webView else { return }
        // 页面脚本卡死时 evaluateJavaScript 也可能不回调，硬超时必须归还 continuation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.finish([])
        }
        wv.evaluateJavaScript(Self.collectJS) { [weak self] result, _ in
            var values: [String] = []
            if let array = result as? [String] {
                values = array
            } else if let array = result as? [Any] {
                values = array.compactMap { $0 as? String }
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
