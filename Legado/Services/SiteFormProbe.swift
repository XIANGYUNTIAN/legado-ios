import Foundation
import UIKit
import WebKit

// MARK: - 表单驱动站内搜索（v50）
//
// 公子 11-07 第七轮反馈：v49 逐站诊断 24 站全部是「搜索页无结果（含网页渲染）」。
// 页面能渲染，说明不是网络不通；程序拼的 /index.php/vod/search.html?wd=… 等
// 7 条猜测路径根本不是这些站真实的搜索入口。而用户点「站点直达」进网页后
// 能搜到同名剧、点开就能播，走的是「站点首页 + 页面自带的搜索表单」。
//
// 这里复刻那条真实路径：隐藏 WKWebView 打开站点首页，注入脚本定位搜索
// input / form，填入关键词并提交（GET 拼参数、POST 直接 form.submit、苹果 CMS
// 伪静态把关键词写进路径），等结果页渲染后收集 a[href]。不依赖任何 CMS 路径约定。
//
// 机制沿用 v44 漫画 / v47 站内搜索已真机验证的隐藏 WebView 方案。

/// 一次表单搜索的原始产出（跨 actor 只传纯值）。
private struct FormRawOutput: Sendable {
    let pairs: [[String]]
    let note: String
}

struct FormProbeOutput: Sendable {
    let links: [DomLink]
    let note: String
}

final class SiteFormProbe: NSObject, WKNavigationDelegate {

    /// 强引用在途探针，避免 continuation 完成前被释放
    private static var active: [SiteFormProbe] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FormRawOutput, Never>?
    private var finished = false
    private var submitted = false
    private var collecting = false
    private var submitTag = "提交已发出"
    private var keyword = ""

    private static let pageTag = "__LEGADO_PAGE_URL__"

    private static let collectJS = """
    (function(){
      var out = [];
      var els = document.querySelectorAll('a[href]');
      for (var i=0;i<els.length && i<1200;i++){
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
      out.push(['__LEGADO_PAGE_URL__', location.href]);
      return out;
    })();
    """

    /// 把关键词编码成 JS 字符串字面量，避免引号 / 换行注入脚本。
    private static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let json = String(data: data, encoding: .utf8), json.count >= 2 else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }

    private static func submitScript(keyword: String) -> String {
        let kw = jsLiteral(keyword)
        return """
        (function(kw){
          var names = ['wd','keyword','searchword','q','s','key','kw','word','search','so'];
          var input = null, inpName = null;
          for (var i=0;i<names.length;i++){
            var el = document.querySelector('input[name="' + names[i] + '"]');
            if (el) { input = el; inpName = names[i]; break; }
          }
          if (!input) {
            var cands = document.querySelectorAll('input[type="text"],input[type="search"],input:not([type])');
            for (var j=0;j<cands.length;j++){
              var c = cands[j];
              var ph = (c.getAttribute('placeholder')||'') + ' ' + (c.id||'') + ' ' + (c.className||'');
              if (/搜索|关键词|影片|片名|search|keyword/i.test(ph)) { input = c; break; }
            }
            if (!input && cands.length) input = cands[0];
          }
          if (!input) return 'noform';
          if (!inpName) inpName = input.getAttribute('name') || 'wd';
          var form = input.form || (input.closest ? input.closest('form') : null);
          var action = form ? (form.getAttribute('action') || location.href) : location.href;
          var method = form ? ((form.getAttribute('method') || 'get').toLowerCase()) : 'get';
          try { action = new URL(action, location.href).href; } catch(e) { action = location.href; }
          if (/^javascript:/i.test(action)) action = location.href;
          input.value = kw;
          try { input.dispatchEvent(new Event('input', {bubbles:true})); } catch(e){}
          if (method === 'post' && form) {
            try { form.submit(); return 'post'; } catch(e){}
          }
          if (action.indexOf('-------------') >= 0) {
            action = action.replace('-------------', encodeURIComponent(kw) + '-------------');
            location.href = action;
            return 'get-path';
          }
          var sep = action.indexOf('?') >= 0 ? '&' : '?';
          location.href = action + sep + encodeURIComponent(inpName) + '=' + encodeURIComponent(kw);
          return 'get';
        })(\(kw));
        """
    }

    /// 打开站点首页 → 自动提交站内搜索表单 → 返回结果页渲染后的链接。
    static func search(home homeURL: URL, keyword: String,
                       timeout: TimeInterval = 11) async -> FormProbeOutput {
        let raw: FormRawOutput = await withCheckedContinuation {
            (cont: CheckedContinuation<FormRawOutput, Never>) in
            // WKWebView 必须在主线程创建；continuation 的同步闭包不保证线程。
            Task { @MainActor in
                let probe = SiteFormProbe()
                Self.active.append(probe)
                probe.start(home: homeURL, keyword: keyword,
                            timeout: timeout, continuation: cont)
            }
        }
        var landed = ""
        var links: [DomLink] = []
        for pair in raw.pairs {
            guard pair.count == 2 else { continue }
            if pair[0] == pageTag {
                landed = pair[1]
                continue
            }
            links.append(DomLink(title: pair[0], href: pair[1]))
        }
        var note = raw.note + " · 渲染后 " + String(links.count) + " 个链接"
        if landed.count > 8 {
            let short = landed.count > 68 ? String(landed.prefix(68)) : landed
            note += " · 落地 " + short
        }
        return FormProbeOutput(links: links, note: note)
    }

    private func start(home: URL, keyword: String, timeout: TimeInterval,
                       continuation: CheckedContinuation<FormRawOutput, Never>) {
        self.keyword = keyword
        self.continuation = continuation
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                           configuration: config)
        wv.isHidden = true
        wv.customUserAgent = NetworkService.iPhoneUA
        wv.navigationDelegate = self
        self.webView = wv

        var request = URLRequest(url: home)
        request.setValue(NetworkService.iPhoneUA, forHTTPHeaderField: "User-Agent")
        wv.load(request)

        // 硬超时必须归还 continuation，页面脚本卡死也要收口
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.collect()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !submitted else { return }
        submitted = true
        Task { @MainActor in
            // 首页脚本常异步渲染搜索框，留一点时间再找表单
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.submitAndWait()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish([], note: "首页加载失败")
    }

    private func submitAndWait() {
        guard let wv = webView else { return }
        // 提交后统一由 11s 硬超时收 DOM：结果页的搜索结果常由脚本异步渲染，
        // 过早快照只会拿到导航前的空白页。location.href 导航还会让本次
        // evaluateJavaScript 的 completion 丢失，所以不能把 collect 挂在回调里。
        let script = SiteFormProbe.submitScript(keyword: keyword)
        wv.evaluateJavaScript(script) { [weak self] result, _ in
            let tag = (result as? String) ?? "noform"
            Task { @MainActor in self?.submitTag = tag }
        }
    }

    private func collect() {
        guard !finished, !collecting, let wv = webView else { return }
        collecting = true
        wv.evaluateJavaScript(SiteFormProbe.collectJS) { [weak self] result, _ in
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
            Task { @MainActor in
                let tag = self?.submitTag ?? "提交已发出"
                self?.finish(values, note: tag)
            }
        }
    }

    private func finish(_ values: [[String]], note: String) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: FormRawOutput(pairs: values, note: note))
        continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        Self.active.removeAll { $0 === self }
    }
}
