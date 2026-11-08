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
    /// v56：非空 = 自动找片，按队列串行试站。
    var siteQueue: [SiteCandidate] = []
    var onVerdict: ((String, Bool) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var isLoading = true
    @State private var candidates: [URL] = []
    @State private var sheetState: BrowserSheetState?
    @State private var reloadTick = 0
    @State private var queueIndex = 0
    @State private var activeURL: URL
    @State private var activeTitle: String
    @State private var autoFindNote: String

    init(title: String, initialURL: URL, headers: [String: String] = [:],
         autoSearchKeyword: String? = nil, autoPlayOnDetail: Bool = false,
         siteQueue: [SiteCandidate] = [], onVerdict: ((String, Bool) -> Void)? = nil) {
        self.title = title
        self.initialURL = initialURL
        self.headers = headers
        self.autoSearchKeyword = autoSearchKeyword
        self.autoPlayOnDetail = autoPlayOnDetail
        self.siteQueue = siteQueue
        self.onVerdict = onVerdict
        _address = State(initialValue: initialURL.absoluteString)
        _activeURL = State(initialValue: initialURL)
        _activeTitle = State(initialValue: title)
        _autoFindNote = State(initialValue: siteQueue.isEmpty ? "" :
            "自动找片 · 第 1/\(siteQueue.count) 站 · \(siteQueue[0].name)")
    }

    /// v56：命中即停；明确空结果 / 超时则回写未命中并切下一站。
    private func handleVerdict(_ hit: Bool) {
        guard queueIndex < siteQueue.count else { return }
        let item = siteQueue[queueIndex]
        onVerdict?(item.id, hit)
        if hit {
            autoFindNote = "✓ 已在 \(item.name) 搜到并播放"
            return
        }
        let next = queueIndex + 1
        guard next < siteQueue.count else {
            autoFindNote = "已试完 \(siteQueue.count) 个站点，均未搜到；可返回列表手动进站"
            return
        }
        queueIndex = next
        let upcoming = siteQueue[next]
        activeTitle = upcoming.name
        activeURL = upcoming.url
        address = upcoming.url.absoluteString
        autoFindNote = "自动找片 · 第 \(next + 1)/\(siteQueue.count) 站 · \(upcoming.name)"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BrowserWebView(initialURL: activeURL,
                               headers: headers,
                               reloadTick: reloadTick,
                               autoSearchKeyword: autoSearchKeyword,
                               autoPlayOnDetail: autoPlayOnDetail,
                               autoFind: !siteQueue.isEmpty,
                               onSiteVerdict: { hit in self.handleVerdict(hit) },
                               address: $address,
                               isLoading: $isLoading,
                               candidates: $candidates,
                               sheetState: $sheetState)
                if isLoading {
                    ProgressView("加载中…")
                }
                VStack(spacing: 0) {
                    if !autoFindNote.isEmpty {
                        Text(autoFindNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .background(.ultraThinMaterial)
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
            }
            .navigationTitle(activeTitle.isEmpty ? "站点浏览" : activeTitle)
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
                            let media = VodPlaylistParser.normalizedMediaURL(url) ?? url
                            sheetState = .media(BrowserMedia(url: media, headers: headers))
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
    /// v59：首播（请求头代理）失败时先重试一次「无代理纯净直连」，再降级网页。
    @State private var proxyUsed = false
    @State private var retryNote = ""

    private var needsSoftDecoder: Bool {
        VideoPlayAsset.parse(media.url.absoluteString).needsUnsupportedEngine
    }

    private func fallbackURL() -> URL? {
        // v59：采集接口 URL 不是网页，降级加载它只会甩出一屏原始 JSON（图 3）。
        let raw = media.fallbackURL?.absoluteString.lowercased() ?? ""
        let isAPI = raw.contains("api.php") || raw.contains("/provide/vod")
            || raw.contains("ac=detail") || raw.contains("ac=list")
            || raw.contains("ac=videolist")
        if let f = media.fallbackURL, !isAPI { return f }
        guard let scheme = media.url.scheme, let host = media.url.host else { return nil }
        return URL(string: scheme + "://" + host + "/")
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.failed, let fallback = fallbackURL() {
                    ZStack(alignment: .top) {
                        FallbackWebView(url: fallback, headers: media.headers)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("原生播放未成功 · 已切换网页播放")
                                .font(.subheadline.weight(.semibold))
                            Text("直链：" + media.url.absoluteString)
                                .font(.caption2)
                                .lineLimit(2)
                            Text("路径：" + (proxyUsed ? "请求头代理" : "纯净直连")
                                 + " · " + (retryNote.isEmpty ? "未重试" : retryNote))
                                .font(.caption2)
                            HStack {
                                Button("重试原生播放") {
                                    state.failed = false
                                    state.cleanRetried = false
                                    retryNote = ""
                                    start(clean: false)
                                }
                                .buttonStyle(.bordered)
                                Button("纯净直连重试") {
                                    state.failed = false
                                    state.cleanRetried = true
                                    retryNote = "手动纯净直连"
                                    start(clean: true)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(10)
                        .background(.regularMaterial)
                        .cornerRadius(10)
                        .padding(8)
                    }
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
        .onAppear { start(clean: false) }
        .onChange(of: state.cleanRetryRequest) { _, _ in
            guard state.cleanRetryRequest > 0 else { return }
            start(clean: true)
        }
        .onDisappear { player.pause(); monitor = nil }
    }

    /// v59：clean = true 表示「无代理纯净直连」——不套自定义 scheme、不注入
    /// 额外请求头，整条流交给 iOS 原生 HLS 栈。首播失败先这样重试一次，
    /// 覆盖代理改写 / 206 语义 / 起播超时误判；再失败才降级网页。
    private func start(clean: Bool) {
        guard !needsSoftDecoder else { return }
        let isHLS = media.url.absoluteString.lowercased().contains("m3u8")
        // 只对 HLS 套请求头代理：MP4 走代理要整段下载后再切片，大文件极慢。
        let useProxy = !clean && isHLS && !media.headers.isEmpty
        proxyUsed = useProxy
        if useProxy {
            let proxy = HeaderProxyLoader(headers: media.headers)
            loader = proxy
            if let proxied = proxy.proxiedURL(for: media.url) {
                let asset = AVURLAsset(url: proxied)
                asset.resourceLoader.setDelegate(proxy, queue: DispatchQueue(label: "legado.browser.resource"))
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            } else {
                loader = nil
                proxyUsed = false
                player.replaceCurrentItem(with: AVPlayerItem(url: media.url))
            }
        } else {
            loader = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: media.url))
        }
        player.play()
        // 捕获列表只能捕获局部变量，不能直接捕获 self 的属性
        let box = state
        let shouldRetry = !clean
        // 纯净直连重试给 18s：master -> variant -> 首个 ts 三级加载比代理慢
        let timeout = clean ? 18 : 10
        monitor = PlaybackMonitor(player: player, timeout: timeout) { [weak box] in
            guard let box else { return }
            if shouldRetry && !box.cleanRetried {
                box.cleanRetried = true
                box.cleanRetryRequest += 1
            } else {
                box.failed = true
            }
        }
        if clean {
            retryNote = "已自动重试无代理直连"
        }
    }
}

/// @State 是值类型，闭包里改不动；用引用类型承接播放失败状态。
final class PlaybackState: ObservableObject {
    @Published var failed = false
    /// v59：是否已做过一次「无代理纯净直连」重试（只由失败回调写）。
    var cleanRetried = false
    /// v59：失败回调不捕获 View struct，只累加计数；由 onChange 触发重试。
    @Published var cleanRetryRequest = 0
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
    /// v59：纯净直连重试走更长超时，避免 master/variant/ts 慢加载被误判失败。
    private let timeout: Int

    init(player: AVPlayer, timeout: Int = 10, onFail: @escaping () -> Void) {
        self.player = player
        self.timeout = timeout
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
        if elapsed >= timeout { fire() }
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
        let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(source: BrowserWebView.fullscreenFixJS,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))
        config.userContentController = uc
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
                let delays: [UInt64] = [1_500_000_000, 3_500_000_000, 6_000_000_000]
                for delay in delays {
                    try? await Task.sleep(nanoseconds: delay)
                    webView.evaluateJavaScript(FallbackWebView.autoPlayJS) { _, _ in }
                }
            }
        }
    }

    /// 用普通字符串数组拼接，避免 raw 多行字符串把 JS 花括号计入 Swift 词法自检
    /// v54：先关「我记住啦 / 知道了 / 关闭公告」这类模态层，再点播放入口；
    /// 播放器常异步初始化，故延时 400ms 且由调用方在 1.5/3.5/6s 重复注入，
    /// 用 window 标记保证同一页面只真正点一次。
    fileprivate static let autoPlayJS = [
        "(function(){",
        "  var closeWords = /我记住啦|我知道了|知道了|关闭公告|关闭弹窗|不再提示|同意并关闭/i;",
        "  var all = Array.from(document.querySelectorAll('a,button,span,div,li,input'));",
        "  for (var j=0;j<all.length;j++){",
        "    var c = (all[j].innerText||all[j].textContent||all[j].value||'').trim();",
        "    if (c.length>0 && c.length<=12 && closeWords.test(c)) {",
        "      try { all[j].click(); } catch(e){}",
        "    }",
        "  }",
        "  if (window.__legadoAutoPlayDone) return 'done';",
        "  setTimeout(function(){",
        "    if (window.__legadoAutoPlayDone) return;",
        "    var words = /开始观看|立即播放|播放正片|点击播放|马上观看|在线播放|观看正片|立即观看|^播放$|^第?0?1集?$|^1$/i;",
        "    var els = Array.from(document.querySelectorAll('a,button,span,div,li'));",
        "    for (var i=0;i<els.length;i++){",
        "      var t = (els[i].innerText||els[i].textContent||'').trim();",
        "      if (t.length<=12 && words.test(t)) {",
        "        try { els[i].click(); window.__legadoAutoPlayDone=1; } catch(e){}",
        "        break;",
        "      }",
        "    }",
        "  }, 400);",
        "  return 'scheduled';",
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
    /// v56：自动找片模式下启用逐站实测判定。
    var autoFind: Bool = false
    var onSiteVerdict: ((Bool) -> Void)? = nil
    @Binding var address: String
    @Binding var isLoading: Bool
    @Binding var candidates: [URL]
    @Binding var sheetState: BrowserSheetState?

    func makeCoordinator() -> Coordinator {
        Coordinator(initialURL: initialURL,
                    headers: headers,
                    autoSearchKeyword: autoSearchKeyword,
                    autoPlayOnDetail: autoPlayOnDetail,
                    autoFind: autoFind,
                    onSiteVerdict: onSiteVerdict,
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
        // v56：把 H5 播放器的伪全屏改走系统原生视频全屏。
        uc.addUserScript(WKUserScript(source: BrowserWebView.fullscreenFixJS,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))
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
            c.resetForNewSite()
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
        private let autoFind: Bool
        private let onSiteVerdict: ((Bool) -> Void)?
        private var searchSubmitted = false
        private var currentPage: URL?
        private var verdictReported = false
        private var siteGeneration = 0
        var lastInitialURL: URL
        var lastReloadTick: Int

        init(initialURL: URL,
             headers: [String: String],
             autoSearchKeyword: String?,
             autoPlayOnDetail: Bool,
             autoFind: Bool,
             onSiteVerdict: ((Bool) -> Void)?,
             address: Binding<String>,
             isLoading: Binding<Bool>,
             candidates: Binding<[URL]>,
             sheetState: Binding<BrowserSheetState?>) {
            self.headers = headers
            self.autoSearchKeyword = autoSearchKeyword
            self.autoPlayOnDetail = autoPlayOnDetail
            self.autoFind = autoFind
            self.onSiteVerdict = onSiteVerdict
            self.lastInitialURL = initialURL
            self.lastReloadTick = 0
            self.currentPage = initialURL
            _address = address
            _isLoading = isLoading
            _candidates = candidates
            _sheetState = sheetState
            super.init()
        }

        /// v56：换站时清掉上一站的提交 / 判定标记，旧延时任务用 generation 作废。
        func resetForNewSite() {
            searchSubmitted = false
            verdictReported = false
            siteGeneration += 1
        }

        private func reportVerdict(_ hit: Bool) {
            guard autoFind, !verdictReported else { return }
            verdictReported = true
            DispatchQueue.main.async { self.onSiteVerdict?(hit) }
        }

        /// v56：只用强信号判定。详情页出现选集 / 播放控件 = 命中；
        /// 结果页出现明确空结果 / 验证码文案 = 未命中；其余等 14s 硬超时。
        /// 定时器独立于任何 evaluateJavaScript 回调（导航会吞 completion）。
        private func scheduleVerdictChecks(on webView: WKWebView, page: String) {
            guard autoFind, !verdictReported else { return }
            let gen = siteGeneration
            let detail = Self.isDetailLike(page)
            let results = Self.isResultsPage(page)
            let delays: [UInt64] = [2_000_000_000, 5_000_000_000]
            for delay in delays {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: delay)
                    guard self.siteGeneration == gen, !self.verdictReported else { return }
                    webView.evaluateJavaScript(BrowserWebView.verdictJS) { res, _ in
                        guard self.siteGeneration == gen, !self.verdictReported else { return }
                        let s = res as? String ?? ""
                        if detail && s == "hit" { self.reportVerdict(true) }
                        else if results && s == "miss" { self.reportVerdict(false) }
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 14_000_000_000)
                guard self.siteGeneration == gen, !self.verdictReported else { return }
                self.reportVerdict(false)
            }
        }

        /// 明确的媒体后缀才拦截交给播放器；页面 URL 一律留在 WebView 里浏览。
        private static func isMediaURL(_ url: URL) -> Bool {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            let path = comps.path.lowercased()
            let exts = [".m3u8", ".mp4", ".mpd", ".flv", ".ts", ".m4v",
                        ".webm", ".mkv", ".mov", ".m4a", ".mp3"]
            if exts.contains(where: { path.hasSuffix($0) }) { return true }
            // v54：?url= 里含 .mp4 的解析页本身不是媒体；只有能解包出
            // 内层显式媒体地址时才算，play() 会再做一次归一化。
            return VodPlaylistParser.normalizedMediaURL(url) != nil
        }

        private func play(_ url: URL) {
            // v54：解析页 URL 先解包成内层真实媒体地址。
            let media = VodPlaylistParser.normalizedMediaURL(url) ?? url
            var h = headers
            if h["Referer"] == nil && h["referer"] == nil {
                h["Referer"] = currentPage?.absoluteString ?? url.absoluteString
            }
            sheetState = .media(BrowserMedia(url: media, headers: h))
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
            scheduleVerdictChecks(on: webView,
                                  page: webView.url?.absoluteString.lowercased() ?? "")
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

        /// v55：进站一条龙。按「首页 / 搜索结果页 / 详情页」三阶段分派注入，
        /// 不再用 isDetailLike 二分（v53/v54 结果页零注入，黄果懒加载卡片
        /// 没人点，U酷提交后回首页也没人补）。全程只点页面自带元素，
        /// 绝不拼猜测 URL；每个脚本自身幂等，导航后 window 重置可再跑一次。
        private func injectAutomation(into webView: WKWebView) {
            guard let kw = autoSearchKeyword, !kw.isEmpty else { return }
            let page = webView.url?.absoluteString.lowercased() ?? ""
            if Self.isResultsPage(page) {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    webView.evaluateJavaScript(
                        BrowserWebView.resultPageJS(keyword: kw)) { _, _ in }
                }
                return
            }
            if Self.isDetailLike(page) {
                guard autoPlayOnDetail else { return }
                Task { @MainActor in
                    let delays: [UInt64] = [1_500_000_000, 3_500_000_000, 6_000_000_000]
                    for delay in delays {
                        try? await Task.sleep(nanoseconds: delay)
                        webView.evaluateJavaScript(FallbackWebView.autoPlayJS) { _, _ in }
                    }
                }
                return
            }
            // 首页：首次填词 + form 原生提交。searchSubmitted 只防重复填词，
            // 提交后回首页时仍会走看门狗（点搜索按钮 / 派发 Enter）。
            if !searchSubmitted {
                searchSubmitted = true
                let script = BrowserWebView.autoSearchJS(keyword: kw)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    webView.evaluateJavaScript(script) { _, _ in }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                webView.evaluateJavaScript(BrowserWebView.watchdogJS()) { _, _ in }
            }
        }

        private static func isResultsPage(_ u: String) -> Bool {
            let marks = ["wd=", "vodsearch", "/search", "keyword=", "?q=", "&q=",
                         "?key=", "&key=", "?s=", "&s=", "/so/", "searchword="]
            return marks.contains(where: { u.contains($0) })
        }

        private static func isDetailLike(_ u: String) -> Bool {
            let hints = ["/vod/", "/detail/", "/series/", "/play/", "/watch/",
                         "/bangumi/", "/drama/", "/video/", "/movie/", "/show/",
                         "ac=detail", "ids=", "/d/", "/b/"]
            return hints.contains(where: { u.contains($0) })
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
    /// v55：表单提交后没导航时的补点（U酷 requestSubmit 后回首页，
    /// 关键词还留在搜索框里）。只点页面自带的搜索按钮 / 派发 Enter，
    /// 绝不拼 ?wd= 猜测 URL。同页幂等，跨导航最多补两次。
    static func watchdogJS() -> String {
        return [
            "(function(){",
            "  if (window.__legadoWatchdogDone) return 'done';",
            "  window.__legadoWatchdogDone = 1;",
            "  var low = (location.href || '').toLowerCase();",
            "  if (low.indexOf('vodsearch') >= 0 || low.indexOf('/search') >= 0",
            "      || low.indexOf('wd=') >= 0 || low.indexOf('key=') >= 0",
            "      || low.indexOf('keyword=') >= 0 || low.indexOf('?q=') >= 0) return 'already';",
            "  var n = 0;",
            "  try { n = parseInt(sessionStorage.getItem('__legadoWatchdogCount') || '0', 10); } catch(e){}",
            "  if (n >= 2) return 'limit';",
            "  try { sessionStorage.setItem('__legadoWatchdogCount', String(n + 1)); } catch(e){}",
            "  var words = /搜索|搜片|搜一下|立即搜索|开始搜索|search/i;",
            "  var els = document.querySelectorAll('button,a,div,span,input');",
            "  for (var i=0;i<els.length;i++){",
            "    var e = els[i];",
            "    var t = (e.innerText || e.value || e.getAttribute('title') || '').trim();",
            "    if (!t || t.length > 12) continue;",
            "    if (!words.test(t)) continue;",
            "    if (e.tagName === 'A' && !(e.getAttribute('href') || '').trim()) continue;",
            "    try { e.click(); return 'clicked'; } catch(err){}",
            "  }",
            "  var inputs = document.querySelectorAll('input');",
            "  for (var j=0;j<inputs.length;j++){",
            "    var ip = inputs[j];",
            "    if (!ip.value || !ip.value.trim()) continue;",
            "    try {",
            "      ['keydown','keypress','keyup'].forEach(function(ev){",
            "        ip.dispatchEvent(new KeyboardEvent(ev, {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true}));",
            "      });",
            "      return 'enter';",
            "    } catch(err){}",
            "  }",
            "  return 'none';",
            "})()"
        ].joined(separator: "\n")
    }

    /// v55：搜索结果页（黄果 /search?q=、苹果 CMS /vod/search.html?wd=）。
    /// 轻滚动触发懒加载，再点第一个「锚文本含关键词 + 详情形态」的链接；
    /// 卡片把标题放在子 div 时，从含关键词的元素向上/向下找 a[href]。
    /// 同页幂等；点不到就留在结果页由用户手动点，绝不拼 URL。
    static func resultPageJS(keyword: String) -> String {
        let kw = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        return [
            "(function(){",
            "  if (window.__legadoResultDone) return 'done';",
            "  window.__legadoResultDone = 1;",
            "  var kw = '" + kw + "';",
            "  var nav = /首页|分类|排行|最新|登录|注册|更多|下一页|上一页|下载|会员|关于|帮助|联系|返回|列表|公告|域名|替换|电报|频道|电影|电视剧|综艺|动漫/;",
            "  var marks = ['/vod/','/detail/','/series/','/play/','/watch/','/bangumi/','/drama/','/video/','/movie/','/show/','ac=detail','ids=','.html'];",
            "  function isDetail(h){",
            "    for (var i=0;i<marks.length;i++){ if (h.indexOf(marks[i]) >= 0) return true; }",
            "    return false;",
            "  }",
            "  function text(a){ return (a.innerText || a.textContent || a.getAttribute('title') || '').trim(); }",
            "  function pick(){",
            "    var links = document.querySelectorAll('a[href]');",
            "    for (var i=0;i<links.length;i++){",
            "      var a = links[i];",
            "      var h = (a.getAttribute('href') || '').trim();",
            "      var t = text(a);",
            "      if (!h || h === '#' || h.indexOf('javascript:') === 0) continue;",
            "      if (nav.test(t) || t.length > 40 || t.length < 2) continue;",
            "      if (!isDetail(h) || t.indexOf(kw) < 0) continue;",
            "      try { a.click(); return 'clicked'; } catch(e){}",
            "    }",
            "    var nodes = document.querySelectorAll('h1,h2,h3,h4,div,span,p');",
            "    for (var k=0;k<nodes.length;k++){",
            "      var nd = nodes[k];",
            "      var tx = (nd.innerText || nd.textContent || '').trim();",
            "      if (!tx || tx.length > 40 || tx.indexOf(kw) < 0) continue;",
            "      var c = nd.closest ? nd.closest('a[href]') : null;",
            "      if (!c && nd.querySelector) c = nd.querySelector('a[href]');",
            "      if (c && isDetail((c.getAttribute('href') || '').trim())) {",
            "        try { c.click(); return 'clicked'; } catch(e){}",
            "      }",
            "    }",
            "    return 'none';",
            "  }",
            "  try { window.scrollTo(0, 260); } catch(e){}",
            "  setTimeout(function(){ try { window.scrollTo(0, 0); } catch(e){} }, 500);",
            "  var tries = 0;",
            "  var timer = setInterval(function(){",
            "    tries++;",
            "    if (pick() === 'clicked' || tries >= 4) clearInterval(timer);",
            "  }, 900);",
            "  return 'scheduled';",
            "})()"
        ].joined(separator: "\n")
    }

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

    /// v56：把 H5 播放器的「全屏」按钮改走 iOS 原生视频全屏。
    /// WKWebView 里网页自定义全屏通常是「撑满容器 + CSS 旋转 90 度」，
    /// App 没真转横屏、sheet 的导航栏也没让位，于是画面被转竖、观感崩坏。
    /// 这里在捕获阶段接管全屏点击，直接调 webkitEnterFullscreen()，
    /// 由系统播放器负责横屏与铺满；同时禁掉 video 自身的旋转。
    static let fullscreenFixJS = [
        "(function(){",
        "  function nativeFull(){",
        "    var v = document.querySelector('video');",
        "    if (v && v.webkitEnterFullscreen) { try { v.webkitEnterFullscreen(); return true; } catch(e){} }",
        "    return false;",
        "  }",
        "  var p = window.Element && window.Element.prototype;",
        "  if (p) {",
        "    var orig = p.requestFullscreen;",
        "    p.requestFullscreen = function(){",
        "      if (nativeFull()) return Promise.resolve();",
        "      try { return orig ? orig.apply(this, arguments) : Promise.resolve(); } catch(e){ return Promise.resolve(); }",
        "    };",
        "    if (p.webkitRequestFullscreen) p.webkitRequestFullscreen = p.requestFullscreen;",
        "  }",
        "  function hook(e){",
        "    var n = e.target;",
        "    for (var i=0;i<4 && n;i++,n=n.parentElement){",
        "      var c = (n.className && n.className.baseVal !== undefined) ? n.className.baseVal : (n.className || '');",
        "      var sig = String(c) + ' ' + (n.id||'') + ' ' + ((n.getAttribute && (n.getAttribute('title')||n.getAttribute('aria-label')))||'');",
        "      if (/fullscreen|full-screen|full_screen|quanping|全屏/i.test(sig)) {",
        "        if (nativeFull()) { try { e.preventDefault(); e.stopPropagation(); } catch(err){} }",
        "        return;",
        "      }",
        "    }",
        "  }",
        "  document.addEventListener('click', hook, true);",
        "  document.addEventListener('touchend', hook, true);",
        "  try {",
        "    var st = document.createElement('style');",
        "    st.appendChild(document.createTextNode('video{object-fit:contain !important;transform:none !important;}'));",
        "    (document.head || document.documentElement).appendChild(st);",
        "  } catch(e){}",
        "  return 'ok';",
        "})()"
    ].joined(separator: "\n")

    /// v56：逐站实测判定，只认强信号。
    static let verdictJS = [
        "(function(){",
        "  var t = (document.body ? document.body.innerText : '') || '';",
        "  var good = /第\\s*\\d+\\s*集|剧集主页|选集|立即播放|开始观看|播放正片|在线播放|上一集|下一集/;",
        "  var bad = /没有找到匹配数据|没有找到您想要的结果|找到\\s*0\\s*部|暂无相关|暂无数据|没有匹配|无搜索结果|未找到相关|安全验证|请输入验证码|访问验证|人机验证|404 Not Found|搜索\\s*[\"“”'']{2}/;",
        "  if (good.test(t)) return 'hit';",
        "  if (bad.test(t)) return 'miss';",
        "  return 'unknown';",
        "})()"
    ].joined(separator: "\n")

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
