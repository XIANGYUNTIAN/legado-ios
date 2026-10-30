import SwiftUI
import UIKit

/// 系统分享面板（UIActivityViewController 封装）：用于把导出的 TXT 文件
/// 通过「存储到文件」「拷贝到…」等方式保存到本地，或以其他 App 打开。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
