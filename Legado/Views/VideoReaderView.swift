import SwiftUI
import AVKit
import AVFoundation

/// 视频书源阅读器（对应 legado 的 VideoPlayerActivity 主链路 MVP）。
///
/// 与文本阅读器完全独立：书籍为视频源时由 BookReaderView 直接路由到本视图，
/// 不触碰文本引擎。负责：抓取目录（复用规则引擎）→ 抓取并解析章节播放地址
/// （纯 URL / JSON / 内联 m3u8）→ 用原生 AVPlayer 播放（HLS/MP4），并对需要
/// 防盗链头的 HLS 通过 AVAssetResourceLoader 代理注入请求头。
///
/// 已知限制（MVP，已在方案中与公子确认）：
/// - 原生 AVPlayer 不支持 DASH(.mpd) / FLV(.flv)，遇此类型给出明确提示而非崩溃；
/// - WebView 嗅探（sourceRegex / webJs）与弹幕未实现，留待后续完整链路；
/// - 外挂字幕已解析进模型，但本 MVP 暂不渲染（AVPlayer 外挂字幕需额外胶水代码）。
struct VideoReaderView: View {
    let book: Book
    let source: BookSource

    @EnvironmentObject private var sourceStore: BookSourceStore
    @EnvironmentObject private var bookStore: BookStore

    @State private var chapters: [ReaderChapter] = []
    @State private var currentIndex = 0
    @State private var asset: VideoPlayAsset?
    @State private var isLoading = true
    @State private var isLoadingContent = false
    @State private var errorMessage: String?
    @State private var showChapterList = false
    @State private var selectedQuality: Int?
    @State private var player: AVPlayer?
    /// 持有 resourceLoader 代理（delegate 为 weak，必须强引用，否则请求无人接管）
    @State private var activeLoaders: [ObjectIdentifier: HeaderProxyLoader] = [:]
    /// 视频嗅探器（sourceRegex / webJs 链路）
    @State private var sniffer = WebViewSniffer()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在加载目录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "exclamation.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let asset {
                    if asset.isPlayable {
                        videoStage(asset: asset)
                    } else {
                        ContentUnavailableView {
                            Label("无可用播放地址", systemImage: "link.badge.plus")
                        } description: {
                            Text("正文规则未解析出可播放的地址（直链 / m3u8 / 嗅探结果）。原始返回：\n\(asset.raw.prefix(200))")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ProgressView("正在解析播放地址…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(chapters[safe: currentIndex]?.title ?? book.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showChapterList = true } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(chapters.isEmpty)
                }
            }
            .sheet(isPresented: $showChapterList) { chapterListSheet }
            .onDisappear { player?.pause() }
        }
        .onAppear {
            if chapters.isEmpty { Task { await loadToc() } }
        }
    }

    // MARK: - 播放舞台

    @ViewBuilder
    private func videoStage(asset: VideoPlayAsset) -> some View {
        VStack(spacing: 0) {
            ZStack {
                if asset.needsUnsupportedEngine {
                    // DASH / FLV 等原生不支持的格式 → libVLC 软解
                    if let url = effectiveURL(for: asset) {
                        SoftPlayerView(url: url, headers: asset.headers)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    } else {
                        ProgressView("正在准备软解播放…")
                    }
                } else {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .onAppear { buildAndPlay(asset) }
                        .onChange(of: selectedQuality) { _, _ in buildAndPlay(asset) }
                }
            }

            // 清晰度选择（多清晰度书源）
            if !asset.qualities.isEmpty {
                Picker("清晰度", selection: $selectedQuality) {
                    Text("默认").tag(nil as Int?)
                    ForEach(Array(asset.qualities.enumerated()), id: \.offset) { i, q in
                        Text(q.label).tag(i as Int?)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            // 选集（上一集 / 下一集）
            HStack(spacing: 24) {
                Button { previous() } label: {
                    Label("上一集", systemImage: "backward.fill")
                }
                .disabled(currentIndex <= 0)
                Text("\(currentIndex + 1) / \(chapters.count)")
                    .foregroundStyle(.secondary)
                Button { next() } label: {
                    Label("下一集", systemImage: "forward.fill")
                }
                .disabled(currentIndex >= chapters.count - 1)
                Spacer()
            }
            .padding()
        }
    }

    /// 当前应播放的地址：多清晰度优先选中项，否则主地址
    private func effectiveURL(for asset: VideoPlayAsset) -> URL? {
        if let q = selectedQuality, asset.qualities.indices.contains(q) {
            return asset.qualities[q].url
        }
        return asset.activeURL
    }

    private func unsupportedReason(_ asset: VideoPlayAsset) -> String {
        switch asset.type {
        case .dash:
            return "当前播放内核（原生 AVPlayer）不支持 DASH(.mpd)。需后续接入软解播放器（如 ffmpeg/ijkplayer）才能播放。"
        case .flv:
            return "当前播放内核（原生 AVPlayer）不支持 FLV(.flv)。需后续接入软解播放器才能播放。"
        default:
            return "当前版本暂不支持该播放格式。"
        }
    }

    // MARK: - 目录与正文抓取

    private func loadToc() async {
        guard let rules = source.ruleToc, !rules.isEmpty else {
            await MainActor.run {
                errorMessage = "书源「\(source.bookSourceName)」缺少目录规则（ruleToc 为空），无法阅读"
                isLoading = false
            }
            return
        }
        guard let bookUrlStr = book.bookUrl,
              let bookURL = resolveURL(bookUrlStr, base: source.bookSourceURL) else {
            await MainActor.run {
                errorMessage = "书籍缺少有效的 bookUrl"
                isLoading = false
            }
            return
        }
        var headers = sourceHeaders
        if headers["Referer"] == nil && headers["referer"] == nil {
            headers["Referer"] = bookURL.absoluteString
        }
        do {
            let html = try await NetworkService.shared.fetchText(from: bookURL, headers: headers)
            let toc = try extractToc(html: html, rules: rules, base: bookURL)
            guard !toc.isEmpty else {
                await MainActor.run {
                    errorMessage = "未解析到目录（章节列表为空，可能站点结构已改版或被反爬拦截）"
                    isLoading = false
                }
                return
            }
            await MainActor.run {
                chapters = toc
                isLoading = false
            }
            await loadContent(index: 0)
        } catch {
            await MainActor.run {
                errorMessage = "目录加载失败：\(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    /// 抓取指定章节的播放地址（对应 legado WebBook.getContentAwait → BookContent.analyzeContent：
    /// 视频源的 content 规则产出的是播放地址，而非文本）。
    private func loadContent(index: Int) async {
        guard chapters.indices.contains(index) else { return }
        let chapter = chapters[index]
        guard let urlRel = chapter.url,
              let u = resolveURL(urlRel, base: book.bookUrl.flatMap { URLSanitizer.sanitize($0) } ?? source.bookSourceURL) else {
            await MainActor.run {
                errorMessage = "章节地址无效：\(chapter.url ?? "")"
            }
            return
        }
        await MainActor.run {
            isLoadingContent = true
            selectedQuality = nil
            errorMessage = nil
        }
        do {
            var headers = sourceHeaders
            if headers["Referer"] == nil && headers["referer"] == nil,
               let ref = book.bookUrl.flatMap({ URLSanitizer.sanitize($0) })?.absoluteString {
                headers["Referer"] = ref
            }
            let html = try await NetworkService.shared.fetchText(from: u, headers: headers)
            let engine = RuleEngine()
            engine.setSource(source)
            engine.setBook(book)
            engine.setBaseUrl(source.bookSourceUrl)
            let contentRule = source.ruleContent?.content ?? ""
            let raw = (try? engine.getString(contentRule, content: html)) ?? ""
            let parsed = VideoPlayAsset.parse(raw, base: u)
            if parsed.isPlayable {
                await setAsset(parsed)
            } else if let sniffRule = source.ruleContent,
                      (sniffRule.sourceRegex?.isEmpty == false || sniffRule.webJs?.isEmpty == false) {
                await sniffAndResolve(chapterURL: u)
            } else {
                await setAsset(parsed)
            }
        } catch {
            await MainActor.run {
                asset = nil
                errorMessage = "解析播放地址失败：\(error.localizedDescription)"
                isLoadingContent = false
            }
        }
    }

    /// 目录解析（逐元素求值 chapterList → chapterName / chapterUrl）
    private func extractToc(html: String, rules: SourceRuleSet, base: URL) throws -> [ReaderChapter] {
        let listRule = rules.chapterList ?? ""
        let nameRule = rules.chapterName ?? ""
        let urlRule = rules.chapterUrl ?? ""

        let engine = RuleEngine()
        engine.setSource(source)
        engine.setBook(book)
        engine.setBaseUrl(base.absoluteString)

        var ruleError: String?
        let items = BookListAnalyzer.items(rule: listRule, html: html, engine: engine, ruleError: &ruleError)
        guard !items.isEmpty else {
            if let ruleError { throw RuleError.ruleFailed(ruleError) }
            return []
        }

        var result: [ReaderChapter] = []
        for item in items {
            let name = BookListAnalyzer.field(nameRule, item: item, engine: engine)
            guard !name.isEmpty else { continue }
            let urlRel = BookListAnalyzer.field(urlRule, item: item, engine: engine)
            let resolved = resolveURL(urlRel, base: base)
                ?? resolveURL(urlRel, base: source.bookSourceURL)
                ?? URLSanitizer.sanitize(urlRel)
            let isVolumeText = BookListAnalyzer.field(rules.isVolume, item: item, engine: engine)
            result.append(ReaderChapter(
                title: name,
                text: nil,
                url: resolved?.absoluteString,
                isVolume: isVolumeText == "true" || isVolumeText == "1"
            ))
        }
        return result
    }

    // MARK: - 播放控制

    private func buildAndPlay(_ a: VideoPlayAsset) {
        guard !a.needsUnsupportedEngine else { return } // DASH/FLV 由 SoftPlayerView 软解
        let effectiveURL: URL?
        if let q = selectedQuality, a.qualities.indices.contains(q) {
            effectiveURL = a.qualities[q].url
        } else {
            effectiveURL = a.activeURL
        }
        guard let url = effectiveURL else { return }
        let item = makePlayerItem(url: url, headers: a.headers)
        if player == nil { player = AVPlayer() }
        player?.replaceCurrentItem(with: item)
        player?.play()
    }

    /// 设置播放资产并触发原生 AVPlayer 播放（软解格式由 SwiftUI 视图负责，此处跳过）
    private func setAsset(_ a: VideoPlayAsset) async {
        await MainActor.run {
            asset = a
            isLoadingContent = false
            buildAndPlay(a)
        }
    }

    /// 正文规则未解析出直链、但书源配置了嗅探规则时，启动 WebView 嗅探章节页获取媒体直链
    private func sniffAndResolve(chapterURL: URL) async {
        await MainActor.run { isLoadingContent = true; errorMessage = nil }
        let candidates = await withCheckedContinuation { cont in
            sniffer.sniff(pageURL: chapterURL,
                          headers: sourceHeaders,
                          sourceRegexPattern: source.ruleContent?.sourceRegex,
                          webJs: source.ruleContent?.webJs,
                          timeout: 15) { cont.resume(returning: $0) }
        }
        guard let first = candidates.first else {
            await MainActor.run {
                asset = nil
                errorMessage = "嗅探未找到可用的媒体直链（页面可能为纯文本、需登录，或视频由 JS 动态加载未被捕获）"
                isLoadingContent = false
            }
            return
        }
        await setAsset(VideoPlayAsset.parse(first.absoluteString, base: chapterURL))
    }

    /// 构造 AVPlayerItem：无防盗链头直接用 URL；否则经 HeaderProxyLoader 代理注入头。
    private func makePlayerItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        if headers.isEmpty {
            return AVPlayerItem(url: url)
        }
        let loader = HeaderProxyLoader(headers: headers)
        guard let proxied = loader.proxiedURL(for: url) else { return AVPlayerItem(url: url) }
        let avAsset = AVURLAsset(url: proxied)
        avAsset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "legado.video.loader"))
        // 仅保留当前 loader，避免历史实例泄漏
        activeLoaders = [ObjectIdentifier(avAsset): loader]
        return AVPlayerItem(asset: avAsset)
    }

    private func previous() {
        if currentIndex > 0 {
            currentIndex -= 1
            Task { await loadContent(index: currentIndex) }
        }
    }

    private func next() {
        if currentIndex < chapters.count - 1 {
            currentIndex += 1
            Task { await loadContent(index: currentIndex) }
        }
    }

    // MARK: - 复用辅助（与 BookReaderView 同源语义）

    /// 书源 header 字段 → 请求头字典
    private var sourceHeaders: [String: String] {
        guard let raw = source.header?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in obj {
            result[key] = value is String ? value as! String : String(describing: value)
        }
        return result
    }

    private func resolveURL(_ relative: String, base: URL?) -> URL? {
        guard !relative.isEmpty else { return nil }
        if let url = URLSanitizer.sanitize(relative) { return url }
        guard let base else { return nil }
        return URL(string: relative, relativeTo: base)?.absoluteURL
    }

    // MARK: - 选集面板

    private var chapterListSheet: some View {
        NavigationStack {
            List {
                ForEach(chapters.indices, id: \.self) { idx in
                    let ch = chapters[idx]
                    Button {
                        showChapterList = false
                        currentIndex = idx
                        Task { await loadContent(index: idx) }
                    } label: {
                        HStack {
                            Text(ch.title)
                                .foregroundStyle(ch.isVolume ? .secondary : .primary)
                            Spacer()
                            if idx == currentIndex {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showChapterList = false }
                }
            }
        }
    }
}

/// HLS / 普通媒体的请求头注入代理。
///
/// 背景：AVPlayer 不能为 HLS 直接设置请求头，而视频源常需 Referer / Origin 防盗链。
/// 做法：把请求 URL 的 scheme 换成自定义 scheme，由本代理拦截并重新发起带头的请求；
/// 对返回的 m3u8 文本做递归改写（把其中 https URL 也换成自定义 scheme），使变体与切片
/// 请求同样带上请求头。仅 GET，按 dataRequest 的 offset/length 切片响应。
final class HeaderProxyLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "legadohdr"
    private let headers: [String: String]
    private var tasks: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]

    init(headers: [String: String]) {
        self.headers = headers
    }

    /// 把原始 URL 改写到自定义 scheme，触发资源加载代理
    func proxiedURL(for original: URL) -> URL? {
        guard var c = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = HeaderProxyLoader.scheme
        return c.url
    }

    func resourceLoader(_ rl: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let customURL = req.request.url, let original = originalURL(customURL) else {
            req.finishLoading(with: NSError(domain: "legado", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的资源 URL"]))
            return true
        }
        var request = URLRequest(url: original)
        for (k, v) in headers where k.lowercased() != "range" {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let range = req.request.allHTTPHeaderFields?["Range"] {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let response {
                if let http = response as? HTTPURLResponse {
                    // 透传 Content-Type，帮助 AVFoundation 识别 playlist 与媒体
                    let ct = (http.allHeaderFields["Content-Type"] as? String) ?? ""
                    let newResp = HTTPURLResponse(
                        url: original, statusCode: http.statusCode, httpVersion: nil,
                        headerFields: ct.isEmpty ? nil : ["Content-Type": ct]
                    ) ?? response
                    req.response = newResp
                } else {
                    req.response = response
                }
            }
            if let error {
                req.finishLoading(with: error)
                self.tasks[req] = nil
                return
            }
            guard let data, !data.isEmpty else {
                req.finishLoading()
                self.tasks[req] = nil
                return
            }
            let ct = (response as? HTTPURLResponse)?.allHeaderFields["Content-Type"] as? String ?? ""
            let isPlaylist = ct.contains("mpegurl") || ct.contains("vnd.apple.mpegurl")
                || data.prefix(20).starts(with: Data("#EXTM3U".utf8))
            if isPlaylist, let text = String(data: data, encoding: .utf8) {
                let rewritten = self.rewritePlaylist(text)
                if let rdata = rewritten.data(using: .utf8) {
                    self.respondData(rdata, for: req)
                } else {
                    req.finishLoading()
                }
            } else {
                self.respondData(data, for: req)
            }
            self.tasks[req] = nil
        }
        tasks[req] = task
        task.resume()
        return true
    }

    func resourceLoader(_ rl: AVAssetResourceLoader, didCancel req: AVAssetResourceLoadingRequest) {
        tasks[req]?.cancel()
        tasks[req] = nil
    }

    private func respondData(_ data: Data, for req: AVAssetResourceLoadingRequest) {
        guard let dr = req.dataRequest else { req.finishLoading(); return }
        let offset = Int(dr.requestedOffset)
        let length = Int(dr.requestedLength)
        let lo = min(offset, data.count)
        let hi = min(offset + length, data.count)
        if hi > lo {
            dr.respond(with: data.subdata(in: lo..<hi))
        }
        req.finishLoading()
    }

    private func originalURL(_ custom: URL) -> URL? {
        guard var c = URLComponents(url: custom, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        return c.url
    }

    /// 把 playlist 文本中的 https? URL 改写为自定义 scheme，使下级请求也被代理拦截并带头。
    /// 逆序替换以保证低位 range 在多次替换后仍有效（自定义 scheme 与原 scheme 长度不同）。
    private func rewritePlaylist(_ text: String) -> String {
        let pattern = #"https?://[^\s"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let urlString = ns.substring(with: match.range)
            guard let u = URL(string: urlString),
                  var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { continue }
            c.scheme = HeaderProxyLoader.scheme
            if let proxied = c.url?.absoluteString {
                mutable.replaceCharacters(in: match.range, with: proxied)
            }
        }
        return mutable as String
    }
}
