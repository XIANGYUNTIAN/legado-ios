import SwiftUI
import UIKit

// MARK: - 漫画 / 图片书源正文
//
// 公子 2026-11-05 反馈：漫画加入书架后无法观看。文本阅读器把 ruleContent 结果
// 一律走 cleanChapterContent 文本清洗，漫画源返回的图片地址列表会被当成正文文字显示。
// 这里把「图片地址列表」识别出来并渲染成可纵向滚动的图片页，请求头沿用书源 header
// （Referer 防盗链），避免 AsyncImage 无法带 header 导致整页加载失败。

enum ComicPageDetector {
    /// 从正文规则结果里提取图片地址（HTML `<img src>`、JSON 数组、纯 URL 列表均兼容）。
    static func imageURLs(from raw: String, base: URL) -> [URL] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 300_000 else { return [] }
        let pattern = #"https?://[^\s"'<>]+?\.(?:jpg|jpeg|png|webp|gif|bmp)(?:\?[^\s"'<>]*)?"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let ns = text as NSString
        var out: [URL] = []
        var seen = Set<String>()
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var s = ns.substring(with: m.range)
            s = s.replacingOccurrences(of: #"\/"#, with: "/")
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;)]}\"'\\"))
            guard let u = URLSanitizer.sanitize(s)
                    ?? URL(string: s, relativeTo: base)?.absoluteURL else { continue }
            let key = u.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(u)
            if out.count >= 200 { break }
        }
        return out
    }
}

struct ComicPagesView: View {
    let pages: [URL]
    let headers: [String: String]
    let title: String
    /// 由父视图（BookReaderView）注入退出动作：阅读器自建 NavigationStack，
    /// 子视图自己取 @Environment(\.dismiss) 可能只作用于内层空栈而无效。
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pages.indices, id: \.self) { idx in
                    ComicPageImage(url: pages[idx], headers: headers, index: idx)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("关闭") { onClose() }
            }
        }
        // 常驻悬浮出口：即使阅读设置处于沉浸模式、导航栏仍未显示，也不会把用户卡在图片页。
        .overlay(alignment: .topTrailing) {
            Button {
                onClose()
            } label: {
                Label("返回", systemImage: "xmark")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.borderless)
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
    }
}

/// 单页图片：带书源 header 下载，失败时显示页码与原始地址便于定位。
private struct ComicPageImage: View {
    let url: URL
    let headers: [String: String]
    let index: Int

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("第 \(index + 1) 页加载失败")
                    Text(url.absoluteString)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard image == nil, !failed else { return }
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if headers["Referer"] == nil && headers["referer"] == nil,
           let host = url.host {
            req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let img = UIImage(data: data) {
                image = img
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
