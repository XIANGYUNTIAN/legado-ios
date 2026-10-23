import SwiftUI

/// URL 添加书籍：粘贴远程链接，下载并入库
struct AddBookByURLView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bookStore: BookStore

    var onResult: (String, Bool) -> Void

    @State private var urlText = ""
    @State private var isLoading = false

    init(onResult: @escaping (String, Bool) -> Void) {
        self.onResult = onResult
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("粘贴远程书籍链接（TXT / EPUB），应用将下载并导入书架。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                TextField("https://.../book.txt", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal)
                Button {
                    start()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("添加")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(isLoading || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(.top)
            .navigationTitle("URL 添加书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func start() {
        let link = urlText
        isLoading = true
        Task {
            do {
                let book = try await bookStore.importRemoteBook(from: link)
                onResult("已添加：《\(book.title)》", false)
                dismiss()
            } catch {
                isLoading = false
                onResult(error.localizedDescription, true)
            }
        }
    }
}
