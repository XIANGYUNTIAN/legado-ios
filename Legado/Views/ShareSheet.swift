import SwiftUI
import UIKit

/// 系统分享面板（UIActivityViewController 封装）：用于把导出的 TXT 文件
/// 通过「存储到文件」「拷贝到…」等方式保存到本地，或以其他 App 打开。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // iPad 上 UIActivityViewController 必须给定 popover 来源，否则会崩溃（白屏）。
        // 此前用 scene.windows.first(where: { $0.isKeyWindow }) 取值，而 SwiftUI 场景下
        // isKeyWindow 经常取不到 → sourceView 保持 nil → UIActivityViewController 抛
        // NSGenericException 崩溃（表现即"点击导出后白屏"）。这里用兜底链确保永远拿到一个
        // 非空 sourceView：keyWindow 优先 → 任意 foregroundActive 场景的首个 window → 任意 window。
        if let popover = controller.popoverPresentationController {
            if let window = Self.sourceWindow() {
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            }
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// 取得一个用于 popover 锚定的 window。返回 nil 的概率极低（仅在所有场景/窗口都不可用时）。
    private static func sourceWindow() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        // 1) 当前前台活动场景的 keyWindow
        for scene in scenes where scene.activationState == .foregroundActive {
            if let w = scene.windows.first(where: { $0.isKeyWindow }) { return w }
        }
        // 2) 任意前台活动场景的首个 window
        for scene in scenes where scene.activationState == .foregroundActive {
            if let w = scene.windows.first { return w }
        }
        // 3) 退化为任意场景的首个 window
        return scenes.first?.windows.first
    }
}
