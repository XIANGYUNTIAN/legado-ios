import SwiftUI
import VLCKit

/// 软解播放视图（DASH / FLV 等原生 AVPlayer 不支持的格式）。
///
/// 背景：iOS 原生 AVPlayer 仅支持 HLS/MP4。遇 DASH(.mpd)/FLV(.flv) 改用 libVLC
/// （MobileVLCKit）软解。防盗链头经 VLCMedia 的 http-referrer / http-user-agent 选项注入。
struct SoftPlayerView: UIViewRepresentable {
    let url: URL
    let headers: [String: String]

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let player = VLCMediaPlayer()
        player.drawable = container
        player.media = makeMedia(url)
        context.coordinator.player = player
        context.coordinator.currentURL = url
        player.play()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let player = context.coordinator.player else { return }
        if context.coordinator.currentURL != url {
            player.stop()
            player.media = makeMedia(url)
            player.play()
            context.coordinator.currentURL = url
        }
    }

    func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.player?.stop()
        coordinator.player?.media = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMedia(_ url: URL) -> VLCMedia {
        let media = VLCMedia(url: url)
        var opts: [String: Any] = [:]
        if let ref = headers["Referer"] ?? headers["referer"] {
            opts["http-referrer"] = ref
        }
        if let ua = headers["User-Agent"] {
            opts["http-user-agent"] = ua
        }
        if !opts.isEmpty { media.addOptions(opts) }
        return media
    }

    final class Coordinator {
        var player: VLCMediaPlayer?
        var currentURL: URL?
    }
}
