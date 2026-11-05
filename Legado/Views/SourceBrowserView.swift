import SwiftUI
import WebKit
import AVKit
import AVFoundation

// MARK: - 书源站点浏览器（对齐 legado「书源详情 → 进网站 → 点视频直接播放」）

/// 一次播放请求。headers 里带 Referer，供 HLS 防盗链代理注入。
struct BrowserMedia: Identifiable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
}

/// 浏览器内弹出的面板：候选列表 / 播放器。用同一个 sheet item 切换，避免两个 sheet 抢 presented 状态。
enum BrowserSheetState: Identifiable {
    case candidates
    case media(BrowserMedia)

    var id: String {
        switch self {
        case .candidates: return "candidates"
        case .media(let m): return m.id.uuidString
        }
    }
}

/// 可浏览的站点 WebView。
///
/// 与既有两处 WebView 的分工：
/// - `WebViewSheet` = startBrowserAwait 的登录/验证载体，用户点「完成」后关闭；
/// - `WebViewSniffer` = 隐藏 WKWebView，供 VideoReaderView 规则链路嗅探直链；
/// - 本视图 = 用户真正看得见、能点链接的站点浏览器，页面内 `<video>` 由 WKWebView
///   内联播放，指向 m3u8/mp4 的链接交给原生播放器，嗅探结果作为手动兜底。
struct SourceBrowserView: View {
    let title: String
    let initialURL: URL
    let headers: [String: String]

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var isLoading = true
    @State private var candidates: [URL] = []
    @State private var sheetState: BrowserSheetState?
    @State private var reloadTick = 0

    init(title: String, initialURL: URL, headers: [String: String] = [:]) {
        self.title = title
        self.initialURL = initialURL
        self.headers = headers
        _address = State(initialValue: initialURL.absoluteString)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BrowserWebView(initialURL: initialURL,
                               headers: headers,
                               reloadTick: reloadTick,
                               address: $address,
                               isLoading: $isLoading,
                               candidates: $candidates,
                               sheetState: $sheetState)
                if isLoading {
                    ProgressView("加载中…")
                }
                Text(address)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
            }
            .navigationTitle(title.isEmpty ? "站点浏览" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button { reloadTick += 1 } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button { sheetState = .candidates } label: {
                            Label(candidates.isEmpty ? "嗅探" : "播放 \(candidates.count)",
                                  systemImage: "play.circle")
                        }
                    }
                }
            }
            .sheet(item: $sheetState) { state in
                Group {
                    switch state {
                    case .candidates:
                        BrowserCandidateSheet(candidates: candidates, headers: headers) { url in
                            sheetState = .media(BrowserMedia(url: url, headers: headers))
                        }
                    case .media(let media):
                        BrowserPlayerSheet(media: media)
                    }
                }
            }
        }
    }
}

// MARK: - 嗅探候选面板

struct BrowserCandidateSheet: View {
    let candidates: [URL]
    let headers: [String: String]
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("尚未嗅探到媒体直链。可先在页面里点击视频，页面自带播放器会直接播放；也可刷新页面后再试。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates, id: \.absoluteString) { url in
                        Button {
                            onPick(url)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent)
                                    .font(.subheadline)
                                Text(url.absoluteString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("嗅探结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 原生播放器

/// 独立播放一个媒体直链：HLS/MP4 走 AVPlayer，DASH/FLV 走 VLC 软解。
/// 复用 VideoReaderView 的 HeaderProxyLoader 注入 HLS 防盗链头（Referer）。
struct BrowserPlayerSheet: View {
    let media: BrowserMedia

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    /// delegate 为 weak，必须强引用，否则自定义 scheme 的请求无人接管
    @State private var loader: HeaderProxyLoader?

    private var needsSoftDecoder: Bool {
        VideoPlayAsset.parse(media.url.absoluteString).needsUnsupportedEngine
    }

    var body: some View {
        NavigationStack {
            Group {
                if needsSoftDecoder {
                    SoftPlayerView(url: media.url, headers: media.headers)
                } else {
                    VideoPlayer(player: player)
                }
            }
            .background(Color.black)
            .navigationTitle(media.url.lastPathComponent.isEmpty ? "播放" : media.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { player.pause() }
    }

    private func start() {
        guard !needsSoftDecoder else { return }
        let isHLS = media.url.absoluteString.lowercased().contains("m3u8")
        // 只对 HLS 套请求头代理：MP4 走代理要整段下载后再切片，大文件极慢。
        if isHLS, !media.headers.isEmpty {
            let proxy = HeaderProxyLoader(headers: media.headers)
            loader = proxy
            if let proxied = proxy.proxiedURL(for: media.url) {
                let asset = AVURLAsset(url: proxied)
                asset.resourceLoader.setDelegate(proxy, queue: DispatchQueue(label: "legado.browser.resource"))
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            } else {
                player.replaceCurrentItem(with: AVPlayerItem(url: media.url))
            }
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: media.url))
        }
        player.play()
    }
}

// MARK: - WKWebView 封装

struct BrowserWebView: UIViewRepresentable {
    let initialURL: URL
    let headers: [String: String]
    let reloadTick: Int
    @Binding var address: String
    @Binding var isLoading: Bool
    @Binding var candidates: [URL]
    @Binding var sheetState: BrowserSheetState?

    func makeCoordinator() -> Coordinator {
        Coordinator(initialURL: initialURL,
                    headers: headers,
                    address: $address,
                    isLoading: $isLoading,
                    candidates: $candidates,
                    sheetState: $sheetState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 页面内 <video> 直接内联播放，这是「点视频就播」最可靠的一环
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let uc = WKUserContentController()
        uc.add(context.coordinator, name: "browserSniffer")
        uc.addUserScript(WKUserScript(source: BrowserWebView.sniffJS,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))
        // v29 验证过的注入：a[target=_blank] → _self、window.open → location.href，
        // 配 MutationObserver 覆盖 JS 动态渲染的影视站。
        uc.addUserScript(WKUserScript(source: BrowserWebView.linkFixJS,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: true))
        config.userContentController = uc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let ua = headers["User-Agent"] ?? headers["user-agent"] {
            webView.customUserAgent = ua
        }
        var request = URLRequest(url: initialURL)
        for (k, v) in headers where k.lowercased() != "user-agent" {
            request.setValue(v, forHTTPHeaderField: k)
        }
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let c = context.coordinator
        if c.lastInitialURL != initialURL {
            c.lastInitialURL = initialURL
            var request = URLRequest(url: initialURL)
            for (k, v) in headers where k.lowercased() != "user-agent" {
                request.setValue(v, forHTTPHeaderField: k)
            }
            uiView.load(request)
        } else if c.lastReloadTick != reloadTick {
            c.lastReloadTick = reloadTick
            uiView.reload()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "browserSniffer")
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        @Binding private var address: String
        @Binding private var isLoading: Bool
        @Binding private var candidates: [URL]
        @Binding private var sheetState: BrowserSheetState?

        private let headers: [String: String]
        private var currentPage: URL?
        var lastInitialURL: URL
        var lastReloadTick: Int

        init(initialURL: URL,
             headers: [String: String],
             address: Binding<String>,
             isLoading: Binding<Bool>,
             candidates: Binding<[URL]>,
             sheetState: Binding<BrowserSheetState?>) {
            self.headers = headers
            self.lastInitialURL = initialURL
            self.lastReloadTick = 0
            self.currentPage = initialURL
            _address = address
            _isLoading = isLoading
            _candidates = candidates
            _sheetState = sheetState
            super.init()
        }

        /// 明确的媒体后缀才拦截交给播放器；页面 URL 一律留在 WebView 里浏览。
        private static func isMediaURL(_ url: URL) -> Bool {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            let path = comps.path.lowercased()
            let query = (comps.query ?? "").lowercased()
            let exts = [".m3u8", ".mp4", ".mpd", ".flv", ".ts", ".m4v",
                        ".webm", ".mkv", ".mov", ".m4a", ".mp3"]
            return exts.contains(where: { path.hasSuffix($0) })
                || query.contains(".m3u8") || query.contains(".mp4")
        }

        private func play(_ url: URL) {
            var h = headers
            if h["Referer"] == nil && h["referer"] == nil {
                h["Referer"] = currentPage?.absoluteString ?? url.absoluteString
            }
            sheetState = .media(BrowserMedia(url: url, headers: h))
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let raw = message.body as? String,
                  let url = URLSanitizer.sanitize(raw),
                  url.scheme == "http" || url.scheme == "https" else { return }
            DispatchQueue.main.async {
                if !self.candidates.contains(url) { self.candidates.append(url) }
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if Self.isMediaURL(url) {
                DispatchQueue.main.async { self.play(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            currentPage = webView.url
            address = webView.url?.absoluteString ?? address
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }

        // MARK: WKUIDelegate

        /// 同窗口接管 target="_blank" / window.open，否则影视站常见的「点视频没反应」。
        func webView(_ webView: WKWebView,
                     createWebViewWithConfiguration configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let original = navigationAction.request.url else { return nil }
            var target = original
            let scheme = target.scheme ?? ""
            if scheme.isEmpty || (scheme != "http" && scheme != "https"),
               let fixed = URL(string: "https://" + original.absoluteString) {
                target = fixed
            }
            webView.load(URLRequest(url: target))
            return nil
        }
    }

    // MARK: 注入脚本

    private static let sniffJS = """
    (function(){
      function post(u){
        if(!u) return;
        u = String(u);
        try { u = new URL(u, location.href).href; } catch(e){}
        if(u.indexOf('http') !== 0) return;
        if(!mediaExt(u)) return;
        try { window.webkit.messageHandlers.browserSniffer.postMessage(u); } catch(e){}
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
        }
      }
      var _observer = new MutationObserver(function(muts){
        for(var m=0;m<muts.length;m++){
          var nodes = muts[m].addedNodes || [];
          for(var n=0;n<nodes.length;n++){
            var node = nodes[n];
            if(node.nodeType !== 1) continue;
            if(node.tagName === 'VIDEO' || node.tagName === 'SOURCE' || node.tagName === 'AUDIO'){
              post(node.src || node.currentSrc || node.getAttribute('src'));
            }
            if(node.querySelectorAll){
              var inner = node.querySelectorAll('video,audio,source');
              for(var k=0;k<inner.length;k++){
                post(inner[k].src || inner[k].currentSrc || inner[k].getAttribute('src'));
              }
            }
          }
        }
      });
      try { _observer.observe(document.documentElement || document, {childList:true, subtree:true}); } catch(e){}
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
      var _play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function(){
        try { post(this.currentSrc || this.src || this.getAttribute('src')); } catch(e){}
        try { return _play.apply(this, arguments); } catch(e){ return Promise.resolve(); }
      };
      scan();
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
    })();
    """

    private static let linkFixJS = """
    (function(){
      function fix(){
        document.querySelectorAll('a[target="_blank"]').forEach(function(a){ a.target='_self'; });
      }
      fix();
      try { new MutationObserver(fix).observe(document.documentElement, {childList:true, subtree:true}); } catch(e){}
      try { window.open = function(u){ if(u){ window.location.href = u; } return null; }; } catch(e){}
    })();
    """
}
