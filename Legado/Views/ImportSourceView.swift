import SwiftUI

struct ImportSourceView: View {
    @EnvironmentObject private var store: BookSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?
    @State private var importedCount = 0
    @State private var isLoading = false
    @State private var messageColor: Color = .red

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary)
                    )
                    .padding(.horizontal)

                if let message = message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(messageColor)
                        .padding(.horizontal)
                }

                Button {
                    startImport()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("导入")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(isLoading || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(.top)
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    /// 支持两种输入：① 直接粘贴书源 JSON；② 粘贴单行 http(s) 链接自动抓取
    @MainActor
    private func startImport() {
        let input = text
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLink = BookSourceStore.linkIfAny(trimmed) != nil

        isLoading = true
        importedCount = 0
        messageColor = .secondary
        message = isLink ? "正在获取书源…" : nil

        Task {
            do {
                let body: String
                if let url = BookSourceStore.linkIfAny(trimmed) {
                    body = try await BookSourceStore.fetchText(from: url)
                } else {
                    body = trimmed
                }
                let count = try await store.importSources(from: body)
                importedCount = count
                messageColor = .green
                message = "成功导入 \(count) 个书源"
                text = ""
            } catch {
                importedCount = 0
                messageColor = .red
                message = error.localizedDescription
            }
            isLoading = false
        }
    }
}
