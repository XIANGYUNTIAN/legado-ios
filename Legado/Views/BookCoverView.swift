import SwiftUI
import UIKit

/// 书架行内封面：自适应尺寸显示书籍封面。
/// - 显示：resizable().scaledToFill() + 固定比例 frame + 裁剪，封面图随 frame 缩放（自适应大小与分辨率）。
/// - 来源：优先缓存 / 网络封面；加载中或未取到时显示格式占位图，加载完成后替换为真实 / 生成封面。
struct BookCoverView: View {
    let book: Book
    var size: CGSize = CGSize(width: 44, height: 62)
    @EnvironmentObject private var bookStore: BookStore
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task { await load() }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .overlay(
                Image(systemName: book.format == .txt ? "doc.text.fill" : "book.closed.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: min(size.width, size.height) * 0.4))
            )
    }

    private func load() async {
        guard image == nil else { return }
        let (img, remote) = await CoverService.shared.cover(for: book)
        await MainActor.run {
            image = img
            if let remote, book.coverRemoteURL == nil {
                bookStore.setCoverURL(bookID: book.id, url: remote)
            }
        }
    }
}
