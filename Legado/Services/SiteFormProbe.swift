import Foundation
import UIKit
import WebKit

// MARK: - 表单驱动站内搜索（v50 → v51）
//
// v50 真机逐站诊断：16 站里 12 站提交成功、6 站落地到带关键词的搜索页且
// 渲染出 25–59 个链接，但 15 站「命中 0 条」。取证发现两个层次的问题：
//   ① 过滤判据把「锚文本含完整关键词」当硬门槛，结果页剧名常被截断；
//   ② v50 的 GET 分支手动拼 action + ?wd=，丢掉 form 的 action 参数、
//      隐藏字段与站点 JS 校验，落地页看着带关键词却不是标准结果页
//      （U酷落地 ?ac=detail&wd=… 就是 action 残留参数的证据）。
//
// v51 复刻真实点击：GET 也走 form 原生提交（requestSubmit → 提交按钮 click
// → form.submit），并把落地 URL / 提交方式 / 页面是否含关键词结构化回传，
// 供过滤与逐站诊断使用。不再依赖任何 CMS 路径模板。

/// 一次表单搜索的原始产出（跨 actor 只传纯值）。
private struct FormRawOutput: Sendable {
    let pairs: [[String]]
    let note: String
}

struct FormProbeOutput: Sendable {
    let links: [DomLink]
    let note: String
    /// v51：表单提交后真正落地的页面，作为相对链接解析与自链排除的基准。
    let landedURL: String
    /// v51：结果页正文是否出现关键词，区分「有结果但抽不到」与「压根没结果」。
    let pageHasKeyword: Bool
}

final class SiteFormProbe: NSObject, WKNavigationDelegate {

    /// 强引用在途探针，避免 continuation 完成前被释放
    private static var active: [SiteFormProbe] = []

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<FormRawOutput, Never>?
    private var finished = false
    private var submitted = false
    private var collecting = false
    private var keyword = ""

    private static let pageTag = "__LEGADO_PAGE_URL__"
    private static let tagKey = "__LEGADO_SUBMIT_TAG__"
    private static let kwKey = "__LEGADO_HAS_KW__"

    /// 把关键词编码成 JS 字符串字面量，避免引号 / 换行注入脚本。
    private static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let json = String(data: data, encoding: .utf8), json.count >= 2 else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }

    private static func collectScript(keyword: String) -> String {
        let kw = jsLiteral(keyword)
        return """
        (function(kw){
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
          var tag = 'unknown';
          try {
            tag = window.__LEGADO_SUBMIT_TAG__
                  || sessionStorage.getItem('__LEGADO_SUBMIT_TAG__') || 'unknown';
          } catch(e) {}
          out.push(['__LEGADO_PAGE_URL__', location.href]);
          out.push(['__LEGADO_SUBMIT_TAG__', tag]);
          out.push(['__LEGADO_HAS_KW__',
                    (document.body && (document.body.innerText||'').indexOf(kw) >= 0) ? 'yes' : 'no']);
          return out;
        })(\(kw));
        """
    }

    /// v51：优先 form 原生提交，让浏览器带上全部隐藏字段 / action 参数 / 站点校验。
    /// 提交方式写进 window 与 sessionStorage —— location.href 导航会让
    /// evaluateJavaScript 的 completion 丢失，collect 时再从落地页读回。
    private static func submitScript(keyword: String) -> String {
        let kw = jsLiteral(keyword)
        return """
        (function(kw){
          function tag(v){
            window.__LEGADO_SUBMIT_TAG__ = v;
            try { sessionStorage.setItem('__LEGADO_SUBMIT_TAG__', v); } catch(e) {}
          }
          var names = ['wd','keyword','searchword','q','s','key','kw','word','search','so'];
          var input = null;
          for (var i=0;i<names.length;i++){
            var el = document.querySelector('input[name="' + names[i] + '"]');
            if (el) { input = el; break; }
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
          if (!input) { tag('noform'); return 'noform'; }
          input.value = kw;
          try { input.dispatchEvent(new Event('input', {bubbles:true})); } catch(e){}
          var form = input.form || (input.closest ? input.closest('form') : null);
          var action = form ? (form.getAttribute('action') || location.href) : location.href;
          try { action = new URL(action, location.href).href; } catch(e) { action = location.href; }
          if (/^javascript:/i.test(action)) action = location.href;
          // 苹果 CMS 伪静态：关键词要写进 path，不能当 query 字段提交
          if (action.indexOf('-------------') >= 0) {
            action = action.replace('-------------', encodeURIComponent(kw) + '-------------');
            tag('get-path');
            location.href = action;
            return 'get-path';
          }
          if (form) {
            try {
              if (typeof form.requestSubmit === 'function') {
                tag('requestSubmit');
                form.requestSubmit();
                return 'requestSubmit';
              }
            } catch(e) {}
            try {
              var btn = form.querySelector('button[type="submit"],input[type="submit"],button:not([type])');
              if (btn) { tag('submit-click'); btn.click(); return 'submit-click'; }
            } catch(e) {}
            try { tag('submit'); form.submit(); return 'submit'; } catch(e) {}
          }
          // 无 form 兜底：只在这种情况下才自己拼参数
          var inpName = input.getAttribute('name') || 'wd';
          var sep = action.indexOf('?') >= 0 ? '&' : '?';
          tag('get');
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
        var tag = "unknown"
        var hasKw = false
        var links: [DomLink] = []
        for pair in raw.pairs {
            guard pair.count == 2 else { continue }
            if pair[0] == pageTag {
                landed = pair[1]
            } else if pair[0] == tagKey {
                tag = pair[1]
            } else if pair[0] == kwKey {
                hasKw = (pair[1] == "yes")
            } else {
                links.append(DomLink(title: pair[0], href: pair[1]))
            }
        }
        var note = tag + " · 渲染后 " + String(links.count) + " 个链接"
        if landed.count > 8 {
            let short = landed.count > 68 ? String(landed.prefix(68)) : landed
            note += " · 落地 " + short
        }
        note += hasKw ? " · 页面含关键词" : " · 页面无关键词"
        return FormProbeOutput(links: links, note: note,
                               landedURL: landed, pageHasKeyword: hasKw)
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
        // 过早快照只会拿到导航前的空白页。location.href / form.submit 导航还会
        // 让 evaluateJavaScript 的 completion 丢失，所以不能把 collect 挂在回调里。
        wv.evaluateJavaScript(SiteFormProbe.submitScript(keyword: keyword)) { _, _ in }
    }

    private func collect() {
        guard !finished, !collecting, let wv = webView else { return }
        collecting = true
        wv.evaluateJavaScript(SiteFormProbe.collectScript(keyword: keyword)) {
            [weak self] result, _ in
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
            Task { @MainActor in self?.finish(values, note: "done") }
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
