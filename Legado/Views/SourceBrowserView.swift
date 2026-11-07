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
    /// v52：原生播放失败时自动降级到详情页网页播放。必须是 var + 默认值，
    /// 否则带默认值的 let 不进 memberwise init，调用点无法传入。
    var fallbackURL: URL? = nil
}

/// 浏览器内弹出的面板：候选列表 / 播放器。用同一个 sheet item 切换，避免两个 sheet 抢 presented 状态。
enum BrowserSheetState: Identifiable {
    case candidates
    case episodes(VodEpisodeList)
    case media(BrowserMedia)

    var id: String {
        switch self {
        case .candidates: return "candidates"
        case .episodes(let list): return "episodes-" + list.id.uuidString
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
    /// v53：非空时在首次落地页自动填词并原生提交站内搜索表单。
    var autoSearchKeyword: String? = nil
    /// v53：影片详情页自动点播放入口。
    var autoPlayOnDetail: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var isLoading = true
    @State private var candidates: [URL] = []
    @State private var sheetState: BrowserSheetState?
    @State private var reloadTick = 0

    init(title: String, initialURL: URL, headers: [String: String] = [:],
         autoSearchKeyword: String? = nil, autoPlayOnDetail: Bool = false) {
        self.title = title
        self.initialURL = initialURL
        self.headers = headers
        self.autoSearchKeyword = autoSearchKeyword
        self.autoPlayOnDetail = autoPlayOnDetail
        _address = State(initialValue: initialURL.absoluteString)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BrowserWebView(initialURL: initialURL,
                               headers: headers,
                               reloadTick: reloadTick,
                               autoSearchKeyword: autoSearchKeyword,
                               autoPlayOnDetail: autoPlayOnDetail,
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
                    case .episodes(let list):
                        VodEpisodeSheet(list: list)
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
/// v52：原生播放拿不到分片时自动降级到可见网页内联播放，不再让用户对着黑屏。
struct BrowserPlayerSheet: View {
    let media: BrowserMedia

    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    /// delegate 为 weak，必须强引用，否则自定义 scheme 的请求无人接管
    @State private var loader: HeaderProxyLoader?
    @StateObject private var state = PlaybackState()
    @State private var monitor: PlaybackMonitor?

    private var needsSoftDecoder: Bool {
        VideoPlayAsset.parse(media.url.absoluteString).needsUnsupportedEngine
    }

    private func fallbackURL() -> URL? {
        if let f = media.fallbackURL { return f }
        guard let scheme = media.url.scheme, let host = media.url.host else { return nil }
        return URL(string: scheme + "://" + host + "/")
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.failed, let fallback = fallbackURL() {
                    FallbackWebView(url: fallback, headers: media.headers)
                } else if needsSoftDecoder {
                    SoftPlayerView(url: media.url, headers: media.headers)
                } else {
                    VideoPlayer(player: player)
                }
            }
            .background(Color.black)
            .navigationTitle(state.failed ? "网页播放" :
                (media.url.lastPathComponent.isEmpty ? "播放" : media.url.lastPathComponent))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear { start() }
        .onDisappear { player.pause(); monitor = nil }
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
        // 捕获列表只能捕获局部变量，不能直接捕获 self 的属性
        let box = state
        monitor = PlaybackMonitor(player: player) { [weak box] in
            box?.failed = true
        }
    }
}

/// @State 是值类型，闭包里改不动；用引用类型承接播放失败状态。
final class PlaybackState: ObservableObject {
    @Published var failed = false
}

/// v52：截图实证症状是「原生播放器黑屏、进度条 --:--」，即拿到了直链却
/// 一个分片都取不到。旧实现完全没有失败监听，用户只能手动关闭。
final class PlaybackMonitor: NSObject {
    private let player: AVPlayer
    private let onFail: () -> Void
    private var statusObs: NSKeyValueObservation?
    private var timer: Timer?
    private var fired = false
    private var elapsed = 0

    init(player: AVPlayer, onFail: @escaping () -> Void) {
        self.player = player
        self.onFail = onFail
        super.init()
        statusObs = player.observe(\.status, options: [.initial, .new]) { [weak self] p, _ in
            if p.status == .failed { Task { @MainActor in self?.fire() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit {
        timer?.invalidate()
        statusObs?.invalidate()
    }

    private func tick() {
        guard !fired else { return }
        let item = player.currentItem
        let duration = item?.duration.seconds ?? 0
        let current = player.currentTime().seconds
        if duration.isFinite, duration > 0, current > 0.15 {
            fired = true
            timer?.invalidate()
            return
        }
        elapsed += 1
        if elapsed >= 10 { fire() }
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        timer?.invalidate()
        statusObs?.invalidate()
        onFail()
    }
}

/// 降级用的可见网页：页面自己的鉴权 / Referer / JS 天然正确，
/// 注入脚本再主动点一次「开始观看 / 第1集」，复刻用户手动路径。
struct FallbackWebView: UIViewRepresentable {
    let url: URL
    let headers: [String: String]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController = WKUserContentController()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        if let ua = headers["User-Agent"] ?? headers["user-agent"] {
            wv.customUserAgent = ua
        }
        var request = URLRequest(url: url)
        for (k, v) in headers where k.lowercased() != "user-agent" {
            request.setValue(v, forHTTPHeaderField: k)
        }
        wv.load(request)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                webView.evaluateJavaScript(FallbackWebView.autoPlayJS) { _, _ in }
            }
        }
    }

    /// 用普通字符串数组拼接，避免 raw 多行字符串把 JS 花括号计入 Swift 词法自检
    fileprivate static let autoPlayJS = [
        "(function(){",
        "  var words = /开始观看|立即播放|播放正片|点击播放|马上观看|在线播放|观看正片|立即观看|^播放$|^第?0?1集?$|^1$/i;",
        "  var els = Array.from(document.querySelectorAll('a,button,span,div,li'));",
        "  for (var i=0;i<els.length;i++){",
        "    var t = (els[i].innerText||els[i].textContent||'').trim();",
        "    if (t.length<=12 && words.test(t)) {",
        "      try { els[i].click(); return 'clicked'; } catch(e){}",
        "    }",
        "  }",
        "  return 'none';",
        "})()"
    ].joined(separator: "\n")
}

// MARK: - WKWebView 封装

struct BrowserWebView: UIViewRepresentable {
    let initialURL: URL
    let headers: [String: String]
    let reloadTick: Int
    var autoSearchKeyword: String? = nil
    var autoPlayOnDetail: Bool = false
    @Binding var address: String
    @Binding var isLoading: Bool
    @Binding var candidates: [URL]
    @Binding var sheetState: BrowserSheetState?

    func makeCoordinator() -> Coordinator {
        Coordinator(initialURL: initialURL,
                    headers: headers,
                    autoSearchKeyword: autoSearchKeyword,
                    autoPlayOnDetail: autoPlayOnDetail,
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
        private let autoSearchKeyword: String?
        private let autoPlayOnDetail: Bool
        private var searchSubmitted = false
        private var currentPage: URL?
        var lastInitialURL: URL
        var lastReloadTick: Int

        init(initialURL: URL,
             headers: [String: String],
             autoSearchKeyword: String?,
             autoPlayOnDetail: Bool,
             address: Binding<String>,
             isLoading: Binding<Bool>,
             candidates: Binding<[URL]>,
             sheetState: Binding<BrowserSheetState?>) {
            self.headers = headers
            self.autoSearchKeyword = autoSearchKeyword
            self.autoPlayOnDetail = autoPlayOnDetail
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
            // v53：可见浏览器里复刻用户手动路径（首页提交表单 → 详情页点播放）
            injectAutomation(into: webView)
            // 采集站 `api.php/provide/vod/?ac=detail` 返回的是 JSON 播放列表而非网页。
            // 落到这种页面时直接解析成剧集 → 原生播放器，避免用户面对一屏 JSON
            // 或被迫回到带广告的网页里找播放按钮。
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                guard let text = result as? String,
                      VodPlaylistParser.isPlaylistPayload(text) else { return }
                let base = self.currentPage ?? self.lastInitialURL
                let list = VodPlaylistParser.episodes(from: text, base: base)
                guard !list.isEmpty else { return }
                var h = self.headers
                if h["Referer"] == nil && h["referer"] == nil {
                    h["Referer"] = base.absoluteString
                }
                let payload = VodEpisodeList(title: "选择剧集",
                                             episodes: list,
                                             headers: h,
                                             referer: base.absoluteString)
                DispatchQueue.main.async {
                    self.sheetState = .episodes(payload)
                }
            }
        }

        /// 只在「进站自动搜索」模式启用。首次落地页提交表单；此后导航到
        /// 影片详情页时主动点播放入口。找不到 form 就什么都不做，把首页
        /// 留给用户手动搜——绝不拼猜测 URL 把人带去错的搜索页。
        private func injectAutomation(into webView: WKWebView) {
            guard let kw = autoSearchKeyword, !kw.isEmpty else { return }
            if !searchSubmitted {
                searchSubmitted = true
                let script = BrowserWebView.autoSearchJS(keyword: kw)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    webView.evaluateJavaScript(script) { _, _ in }
                }
                return
            }
            guard autoPlayOnDetail else { return }
            let page = webView.url?.absoluteString.lowercased() ?? ""
            guard Self.isDetailLike(page) else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                webView.evaluateJavaScript(FallbackWebView.autoPlayJS) { _, _ in }
            }
        }

        private static func isDetailLike(_ u: String) -> Bool {
            // 表单提交后的结果页常带 /vod/ 或 /search，不能当详情页去点播放。
            let searchMarks = ["wd=", "vodsearch", "/search", "keyword=", "?q=", "&q="]
            if searchMarks.contains(where: { u.contains($0) }) { return false }
            let hints = ["/vod/", "/detail/", "/series/", "/play/", "/watch/",
                         "/bangumi/", "/drama/", "/video/", "/movie/", "/show/",
                         "ac=detail", "ids=", "/d/", "/b/"]
            return hints.contains { u.contains($0) }
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

    /// v53：可见浏览器里的「首页 → 找搜索框 → 填词 → form 原生提交」。
    /// 与隐藏探针的区别：找不到 form 不拼 ?wd= 猜测 URL，保持首页可用。
    /// 数组拼接，避免 JS 花括号干扰 Swift 词法自检。
    static func autoSearchJS(keyword: String) -> String {
        let kw = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return [
            "(function(){",
            "  var names = ['wd','keyword','searchword','q','s','key','kw','word','search','so'];",
            "  var input = null;",
            "  for (var i=0;i<names.length;i++){",
            "    var el = document.querySelector('input[name=\"' + names[i] + '\"]');",
            "    if (el) { input = el; break; }",
            "  }",
            "  if (!input) {",
            "    var cs = document.querySelectorAll('input[type=\"text\"],input[type=\"search\"],input:not([type])');",
            "    for (var j=0;j<cs.length;j++){",
            "      var c = cs[j];",
            "      var ph = (c.getAttribute('placeholder')||'') + ' ' + (c.id||'') + ' ' + (c.className||'');",
            "      if (/搜索|关键词|影片|片名|search|keyword/i.test(ph)) { input = c; break; }",
            "    }",
            "    if (!input && cs.length) input = cs[0];",
            "  }",
            "  if (!input) return 'noform';",
            "  var form = input.form || (input.closest ? input.closest('form') : null);",
            "  if (!form) return 'noform';",
            "  input.value = '" + kw + "';",
            "  try { input.dispatchEvent(new Event('input', {bubbles:true})); } catch(e){}",
            "  try { if (typeof form.requestSubmit === 'function') { form.requestSubmit(); return 'requestSubmit'; } } catch(e){}",
            "  try {",
            "    var btn = form.querySelector('button[type=\"submit\"],input[type=\"submit\"],button:not([type])');",
            "    if (btn) { btn.click(); return 'submit-click'; }",
            "  } catch(e){}",
            "  try { form.submit(); return 'submit'; } catch(e){}",
            "  return 'failed';",
            "})()"
        ].joined(separator: "\n")
    }

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
