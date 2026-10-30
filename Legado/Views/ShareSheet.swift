import SwiftUI
import UIKit

/// 系统分享面板（UIActivityViewController 封装）：用于把导出的 TXT 文件
/// 通过「存储到文件」「拷贝到…」等方式保存到本地，或以其他 App 打开。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad 上 UIActivityViewController 必须给定 popover 来源，否则会崩溃（白屏）。
        if let popover = controller.popoverPresentationController {
            if let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foreground }) as? UIWindowScene,
               let window = scene.windows.first(where: { $0.isKeyWindow }) {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            }
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
