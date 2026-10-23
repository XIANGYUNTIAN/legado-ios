import SwiftUI

struct ImportSourceView: View {
    @EnvironmentObject private var store: BookSourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var message: String?
    @State private var importedCount = 0

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
                        .foregroundStyle(importedCount > 0 ? Color.green : Color.red)
                        .padding(.horizontal)
                }

                Button {
                    do {
                        let count = try store.importSources(from: text)
                        importedCount = count
                        message = "成功导入 \(count) 个书源"
                        text = ""
                    } catch {
                        importedCount = 0
                        message = error.localizedDescription
                    }
                } label: {
                    Text("导入")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
}
