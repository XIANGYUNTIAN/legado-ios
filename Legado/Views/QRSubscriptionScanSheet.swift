import SwiftUI

/// 扫描订阅源二维码：解析 JSON 或链接后导入 SubscriptionSourceStore，含容错提示
struct QRSubscriptionScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sourceStore: SubscriptionSourceStore

    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            QRScanView(
                onResult: handleResult,
                onError: { showMessage($0, true) },
                onCancel: { dismiss() }
            )
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, 48)
                        .foregroundStyle(isError ? .red : .green)
                }
            }
            .navigationTitle("扫描订阅源二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func handleResult(_ code: String) {
        Task {
            do {
                let count = try await sourceStore.importFromTextOrLink(code)
                showMessage("成功导入 \(count) 个订阅源", false)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                dismiss()
            } catch {
                showMessage(error.localizedDescription, true)
            }
        }
    }

    private func showMessage(_ msg: String, _ err: Bool) {
        message = msg
        isError = err
    }
}
