import Foundation
import UIKit

/// 书架封面服务：为每本书解析封面，优先级如下：
/// 1. 内存缓存 → 2. 磁盘缓存（Documents/Covers/<id>.png）→
/// 3. 已记录的远程封面地址直接下载 → 4. 豆瓣图书搜索建议（按书名匹配）→
/// 5. 本地自动生成封面（渐变底 + 书名/作者），保证每本书都有封面。
///
/// 网络抓取不到（无网 / 站点拦截 / 无匹配）时自动降级为生成封面，
/// 因此「网络抓取不到封面的，自动生成封面」天然满足。
@MainActor
final class CoverService {
    static let shared = CoverService()

    private let coversDir: URL
    /// 内存缓存：id → 封面图
    private var inMemory: [String: UIImage] = [:]
    /// 在途请求：合并同 id 并发请求，避免重复打网络
    private var pending: [String: Task<(UIImage?, String?), Never>] = [:]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        coversDir = docs.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
    }

    // MARK: - 主入口

    /// 取得某本书的封面。返回（封面图，远程地址）。远程地址非空表示来自网络，调用方可回填到 Book。
    func cover(for book: Book) async -> (UIImage?, String?) {
        // 1. 内存
        if let img = inMemory[book.id] { return (img, book.coverRemoteURL) }
        // 2. 磁盘
        let path = cachePath(for: book.id)
        if let data = try? Data(contentsOf: path), let img = UIImage(data: data) {
            inMemory[book.id] = img
            return (img, book.coverRemoteURL)
        }
        // 合并在途请求
        if let task = pending[book.id] { return await task.value }
        let task = Task<(UIImage?, String?), Never> { [weak self] in
            await self?.fetchOrGenerate(book, diskPath: path) ?? (nil, nil)
        }
        pending[book.id] = task
        defer { pending.removeValue(forKey: book.id) }
        return await task.value
    }

    // MARK: - 解析顺序

    private func fetchOrGenerate(_ book: Book, diskPath: URL) async -> (UIImage?, String?) {
        // 3. 已有远程地址：直接下载
        if let remote = book.coverRemoteURL, let url = URL(string: remote), let img = await download(url) {
            save(img, to: diskPath)
            inMemory[book.id] = img
            return (img, remote)
        }
        // 4. 豆瓣图书搜索建议
        if let (img, remote) = await fetchFromDouban(book) {
            save(img, to: diskPath)
            inMemory[book.id] = img
            return (img, remote)
        }
        // 5. 自动生成（兜底，必有封面）
        let gen = Self.generateCover(title: book.displayTitle, author: book.author)
        save(gen, to: diskPath)
        inMemory[book.id] = gen
        return (gen, nil)
    }

    // MARK: - 网络

    private func download(_ url: URL) async -> UIImage? {
        guard let data = try? await NetworkService.shared.fetchData(from: url, timeout: 12),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    /// 调用豆瓣「图书搜索建议」JSON 接口，按书名匹配最佳结果，返回（封面图，封面地址）。
    private func fetchFromDouban(_ book: Book) async -> (UIImage, String)? {
        let title = book.displayTitle
        guard let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://book.douban.com/j/subject_suggest?q=\(q)") else { return nil }
        guard let data = try? await NetworkService.shared.fetchData(from: url, timeout: 12) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        // 选最佳匹配：书名完全相等优先；否则包含关系；否则取首个
        var best: [String: Any]? = nil
        for item in json {
            guard let t = item["title"] as? String, !t.isEmpty else { continue }
            if t == title { best = item; break }
            if best == nil, t.contains(title) || title.contains(t) { best = item }
        }
        guard let item = best else { return nil }
        guard let cover = (item["cover"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cover.isEmpty, let coverURL = URL(string: cover) else { return nil }

        // 升级为更清晰的图：将 /view/subject/s/ 替换为 /view/subject/l/
        let largeURL: URL
        if var comps = URLComponents(url: coverURL, resolvingAgainstBaseURL: false) {
            comps.path = comps.path.replacingOccurrences(of: "/view/subject/s/", with: "/view/subject/l/")
            largeURL = comps.url ?? coverURL
        } else { largeURL = coverURL }

        guard let img = await download(largeURL) else { return nil }
        return (img, cover)
    }

    // MARK: - 本地生成封面

    /// 按书名哈希选色，画渐变底 + 书名 + 作者。逻辑尺寸 300x420（@2x/@3x 屏自动高清）。
    private static func generateCover(title: String, author: String) -> UIImage {
        let w: CGFloat = 300, h: CGFloat = 420
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        return renderer.image { _ in
            let hue = CGFloat(abs(title.hashValue) % 360) / 360.0
            let top = UIColor(hue: hue, saturation: 0.55, brightness: 0.42, alpha: 1)
            let bottom = UIColor(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1.0),
                                 saturation: 0.6, brightness: 0.2, alpha: 1)
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            let space = CGColorSpaceCreateDeviceRGB()
            var locations: [CGFloat] = [0, 1]
            let grad = CGGradient(colorsSpace: space,
                                 colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: &locations)!
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: h),
                                  startRadius: 0, endRadius: 0, options: [])
            // 标题（居中、自动换行）
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byWordWrapping
            let titleFont = UIFont.systemFont(ofSize: 30, weight: .bold)
            let titleStr = NSAttributedString(
                string: title,
                attributes: [.font: titleFont,
                             .foregroundColor: UIColor.white,
                             .paragraphStyle: para]
            )
            titleStr.draw(in: CGRect(x: 24, y: h * 0.26, width: w - 48, height: h * 0.42))
            // 作者
            let authorText = author.isEmpty ? "" : "\(author)"
            if !authorText.isEmpty {
                let authorStr = NSAttributedString(
                    string: authorText,
                    attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .regular),
                                 .foregroundColor: UIColor(white: 0.88, alpha: 0.9),
                                 .paragraphStyle: para]
                )
                authorStr.draw(in: CGRect(x: 24, y: h - 72, width: w - 48, height: 40))
            }
        }
    }

    // MARK: - 缓存工具

    private func cachePath(for id: String) -> URL {
        coversDir.appendingPathComponent("\(id).png")
    }

    private func save(_ image: UIImage, to url: URL) {
        guard let data = image.pngData() else { return }
        try? data.write(to: url, options: .atomic)
    }
}
