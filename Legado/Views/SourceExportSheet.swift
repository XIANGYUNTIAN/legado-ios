import SwiftUI

/// 书源导出：把当前全部书源序列化为 legado 兼容 JSON，经系统分享面板导出
///（备份 / 跨设备迁移 / 问题诊断取材）。
struct SourceExportSheet: View {
    let sources: [BookSource]
    @Environment(\.dismiss) private var dismiss
    @State private var exportText: String = ""
    @State private var errorMessage: String?
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
                                "共 \(sources.count) 个书源，约 \(exportText.count / 1024) KB。点右上角「分享」发送或存储。",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Section("预览（前 20 个书源名）") {
                            ForEach(sources.prefix(20), id: \.bookSourceUrl) { source in
                                Text(source.bookSourceName.isEmpty ? source.bookSourceUrl : source.bookSourceName)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("导出书源")
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

    /// 把导出 JSON 写入 App 文档目录（文件 App 可访问），满足「导出到本地」
    private func saveLocal() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sources)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd_HHmmss"
            let name = "书源导出_\(fmt.string(from: Date())).json"
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            savedName = name
        } catch {
            errorMessage = error.localizedDescription
        }
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
}
