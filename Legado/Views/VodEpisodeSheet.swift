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
        var h = list.headers
        if h["Referer"] == nil && h["referer"] == nil {
            h["Referer"] = list.referer
        }
        // v52：原生播放失败时自动降级到详情页网页内联播放。
        // list.referer 在探针分支就是详情页；若是直链则交给播放器回退到站点根。
        var fallback: URL? = nil
        if let r = URL(string: list.referer),
           !VideoPlayAsset.parse(r.absoluteString).isExplicitMediaURL {
            fallback = r
        }
        media = BrowserMedia(url: ep.url, headers: h, fallbackURL: fallback)
    }
}
