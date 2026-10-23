import SwiftUI
import AVFoundation
import UIKit

/// 二维码扫描视图控制器：基于 AVFoundation 识别 QR 码
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onResult: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCapture() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            reportError("设备无可用摄像头")
            return
        }
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            reportError("无法访问摄像头")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            reportError("摄像头输出不可用")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
        captureSession = session

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func reportError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(msg)
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue, !value.isEmpty else { return }
        captureSession?.stopRunning()
        onResult?(value)
    }
}

/// 将 AVFoundation 扫描器接入 SwiftUI
struct QRScanView: UIViewControllerRepresentable {
    var onResult: (String) -> Void
    var onError: (String) -> Void
    var onCancel: (() -> Void)

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onResult = onResult
        vc.onError = onError
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.onResult = onResult
        uiViewController.onError = onError
        uiViewController.onCancel = onCancel
    }
}

/// 扫描书源二维码：解析 JSON 或链接后导入 BookSourceStore，含容错提示
struct QRSourceScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sourceStore: BookSourceStore

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
            .navigationTitle("扫描书源二维码")
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
                showMessage("成功导入 \(count) 个书源", false)
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
