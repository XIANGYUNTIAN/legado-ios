import SwiftUI

/// 规则测试台：对应 Android 端 BookSourceDebugActivity 的最小可用版本
struct RuleTestView: View {
    let presetRule: String

    @State private var content = ""
    @State private var rule = ""
    @State private var output = ""
    @State private var isError = false

    private let sampleContent = """
    {
      "data": [
        { "title": "示例：长生从熬死对手开始", "author": "公子", "url": "https://example.com/book/1" },
        { "title": "示例：归墟纪元", "author": "公子", "url": "https://example.com/book/2" }
      ]
    }
    """

    var body: some View {
        Form {
            Section {
                Button("填入示例") {
                    content = sampleContent
                    if rule.isEmpty {
                        rule = "$.data[*].title"
                    }
                }
                .font(.footnote)
            }

            Section("内容（JSON）") {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
            }

            Section("规则") {
                TextField("例如：$.data[*].title", text: $rule, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1...3)
            }

            Section {
                Button("执行") {
                    run()
                }
                .disabled(rule.isEmpty || content.isEmpty)
            }

            if !output.isEmpty {
                Section("结果") {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("规则测试")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if rule.isEmpty {
                rule = presetRule
            }
        }
    }

    private func run() {
        let engine = RuleEngine()
        do {
            let values = try engine.getStringList(rule, content: content)
            output = values.joined(separator: "\n")
            isError = false
        } catch {
            output = error.localizedDescription
            isError = true
        }
    }
}
