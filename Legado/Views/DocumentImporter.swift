import Foundation
import UIKit
import UniformTypeIdentifiers

/// 系统文档选择器：从**顶层 UIViewController** 直接呈现
/// `UIDocumentPickerViewController`。
///
/// 为什么不用 SwiftUI `.fileImporter`（本地导入三轮失效的根因）：
/// 1. `.fileImporter` 由工具栏 `Menu`  item 的 action 触发时，存在菜单消失动画
///    与呈现竞态，选择器可能根本不出现（无任何报错）；
/// 2. open 模式给出的安全作用域 URL 只在回调期间有效，异步读取必失败；
/// 3. iCloud / 第三方提供方的文件可能未落地，直接读报 "file doesn't exist"。
///
/// 本实现逐一消除上述脆弱点：
/// - 用 UIKit 顶层 VC 呈现，完全绕开 SwiftUI 呈现栈；
/// - `forOpeningContentTypes + asCopy: true` 由系统把选中文件**拷贝到本地
///   临时目录**，回调拿到的 URL 无需安全作用域、不依赖 iCloud 落地状态；
/// - 内容类型用 `.data` 兜底，无扩展名 / 云盘文件不会被过滤掉。
enum DocumentImporter {
    /// 强引用 coordinator，防止回调前被释放导致 delegate 静默失效
    private static var activeCoordinator: Coordinator?

    /// 呈现文档选择器
    /// - Parameters:
    ///   - allowedTypes: 允许的内容类型，默认 `.data`（不过滤任何文件，
    ///     格式校验与内容嗅探在 BookStore.importBookData 内完成）
    ///   - onPick: 用户选中文件（本地拷贝 URL）
    ///   - onCancel: 用户取消或无法呈现
    static func present(allowedTypes: [UTType] = [.data],
                        onPick: @escaping (URL) -> Void,
                        onCancel: @escaping () -> Void) {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        let coordinator = Coordinator(onPick: onPick, onCancel: onCancel)
        picker.delegate = coordinator
        activeCoordinator = coordinator

        guard let top = Self.topViewController() else {
            activeCoordinator = nil
            onCancel()
            return
        }
        top.present(picker, animated: true)
    }

    /// 取当前活跃的顶层视图控制器（兼容 TabView + NavigationStack + 已呈现的 sheet）
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
            ?? scenes.first?.windows.first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: - Delegate

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            DocumentImporter.activeCoordinator = nil
            if let url = urls.first { onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentImporter.activeCoordinator = nil
            onCancel()
        }
    }
}
