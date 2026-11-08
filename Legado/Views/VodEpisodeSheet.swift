import SwiftUI

/// 采集站播放列表选集面板：点一集直接进原生播放器（不经过网页 / 广告页）。
/// 播放器由本面板自己 present，避免与外部 sheet 抢 presented 状态。
struct VodEpisodeSheet: View {
    let list: VodEpisodeList

    @Environment(\.dismiss) private var dismiss
    @State private var media: BrowserMedia?

    var body: some View {
        NavigationStack {
            List {
                if list.episodes.isEmpty {
                    Text("未解析到可播放的剧集。可回到站点页面手动点击视频。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Section("共 \(list.episodes.count) 集 · 点选直接播放") {
                        ForEach(list.episodes) { ep in
                            Button {
                                play(ep)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(ep.name)
                                        .font(.subheadline)
                                    Text(ep.url.absoluteString)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(list.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $media) { m in
                BrowserPlayerSheet(media: m)
            }
        }
    }

    private func play(_ ep: VodEpisode) {
        // v59：采集接口（api.php / provide/vod / ac=detail…）不是详情页。
        // 第 15 轮真机图 3 就是播放失败后把这一屏 JSON 当网页降级出来；
        // 同时它还被当成 Referer 灌给 CDN，把纯净直链硬拖进自定义 scheme 代理。
        let ref = list.referer
        let low = ref.lowercased()
        let isCollectAPI = low.contains("api.php") || low.contains("/provide/vod")
            || low.contains("ac=detail") || low.contains("ac=list")
            || low.contains("ac=videolist")
        var h = list.headers
        if isCollectAPI {
            h.removeValue(forKey: "Referer")
            h.removeValue(forKey: "referer")
            h.removeValue(forKey: "Origin")
            h.removeValue(forKey: "origin")
        }
        if h["Referer"] == nil && h["referer"] == nil {
            if isCollectAPI {
                // 防盗链只认直链所在站点根，别把采集接口域名当来源
                if let scheme = ep.url.scheme, let host = ep.url.host {
                    h["Referer"] = scheme + "://" + host + "/"
                }
            } else {
                h["Referer"] = ref
            }
        }
        // v52：原生播放失败时自动降级到详情页网页内联播放。
        // v59：采集接口一律不作 fallback，交给播放器回退到媒体站点根。
        var fallback: URL? = nil
        if !isCollectAPI, let r = URL(string: ref),
           !VideoPlayAsset.parse(r.absoluteString).isExplicitMediaURL {
            fallback = r
        }
        media = BrowserMedia(url: ep.url, headers: h, fallbackURL: fallback)
    }
}
