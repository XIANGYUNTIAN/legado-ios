import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 系统文件选择器（本地导入 TXT / EPUB）
/// 采用 UIDocumentPickerViewController，比 .fileImporter 兼容性更好，且拥有明确的取消/选择回调
struct DocumentImporter: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.text, UTType.epub])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentImporter
        init(_ parent: DocumentImporter) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { parent.onPick(url) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
