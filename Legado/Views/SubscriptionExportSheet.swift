import SwiftUI

/// 订阅源导出：把全部订阅源序列化为 legado 兼容 JSON，可「保存到本地文件」或经系统分享面板导出
struct SubscriptionExportSheet: View {
    let sources: [SubscriptionSource]
    @Environment(\.dismiss) private var dismiss
    @State private var exportText: String = ""
    @State private var errorMessage: String?
    @State private var savedPath: String?
    @State private var savedName: String?

    var body: some View {
        NavigationStack {
            Group {
                if let error = errorMessage {
                    ContentUnavailableView {
                        Label("导出失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if let name = savedName {
                    ContentUnavailableView {
                        Label("已保存到本地", systemImage: "checkmark.circle")
                    } description: {
                        Text("文件：\(name)\n可在「文件」App → 我的 iPhone → Legado 中找到")
                    }
                } else if exportText.isEmpty {
                    ProgressView("正在生成…")
                } else {
                    List {
                        Section {
                            Label(
                                "共 \(sources.count) 个订阅源，约 \(exportText.count / 1024) KB。可点「保存到本地」写入文件，或用右上角「分享」发送。",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Section("预览（前 20 个订阅源名）") {
                            ForEach(sources.prefix(20), id: \.id) { source in
                                Text(source.sourceName.isEmpty ? source.sourceUrl : source.sourceName)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("导出订阅源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ShareLink(item: exportText) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportText.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        saveLocal()
                    } label: {
                        Label("保存到本地", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(exportText.isEmpty)
                }
            }
        }
        .onAppear(perform: generate)
    }

    private func generate() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sources)
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = "无法编码为 UTF-8 文本"
                return
            }
            exportText = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 把导出 JSON 写入 App 文档目录（文件 App 可访问），满足「导出到本地」
    private func saveLocal() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sources)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            let name = "订阅源导出_\(fmt.string(from: Date())).json"
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            savedName = name
            savedPath = url.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
