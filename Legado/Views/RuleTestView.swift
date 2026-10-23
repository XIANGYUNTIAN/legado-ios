import SwiftUI

/// 规则测试台：对应 Android 端 BookSourceDebugActivity 的最小可用版本。
/// 支持 JSON / 正则 / CSS / XPath 四种模式，可直接验证书源规则是否正确。
struct RuleTestView: View {
    let presetRule: String

    @State private var mode: TestMode = .json
    @State private var content = ""
    @State private var rule = ""
    @State private var output = ""
    @State private var isError = false
    @State private var hitCount: Int?

    private enum TestMode: String, CaseIterable {
        case json = "JSON"
        case regex = "正则"
        case css = "CSS"
        case xpath = "XPath"

        var placeholder: String {
            switch self {
            case .json: return "$.data[*].title"
            case .regex: return "书名：(.*?)&&##"
            case .css: return "@css:.title@text"
            case .xpath: return "//div[@class=\"title\"]/text()"
            }
        }

        var sampleContent: String {
            switch self {
            case .json:
                return """
                {
                  "data": [
                    { "title": "示例：长生从熬死对手开始", "author": "公子", "url": "https://example.com/book/1" },
                    { "title": "示例：归墟纪元", "author": "公子", "url": "https://example.com/book/2" }
                  ]
                }
                """
            case .regex:
                return "书名：长生从熬死对手开始\n作者：公子\n书名：归墟纪元\n作者：公子"
            case .css:
                return """
                <html><body>
                <ul class="chapters">
                  <li><a href="/book/1">第一回 天地初开</a></li>
                  <li><a href="/book/2">第二回 问道长生</a></li>
                </ul>
                <div class="title">示例书名</div>
                <div class="author">公子</div>
                </body></html>
                """
            case .xpath:
                return """
                <html><body>
                <ul class="chapters">
                  <li><a href="/book/1">第一回 天地初开</a></li>
                  <li><a href="/book/2">第二回 问道长生</a></li>
                </ul>
                <div class="title">示例书名</div>
                <div class="author">公子</div>
                </body></html>
                """
            }
        }

        var preset: String {
            switch self {
            case .json: return "$.data[*].title"
            case .regex: return "书名：(.*?)"
case .css: return "@css:ul.chapters li a@text"
        case .xpath: return "//ul[@class=\"chapters\"]/li/a/text()"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("模式", selection: $mode) {
                    ForEach(TestMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in
                    content = mode.sampleContent
                    rule = mode.preset
                    output = ""
                    hitCount = nil
                }
            }

            Section {
                Button("填入示例") {
                    content = mode.sampleContent
                    rule = mode.preset
                    output = ""
                    hitCount = nil
                }
                .font(.footnote)
            }

            Section("内容") {
                TextEditor(text: $content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
            }

            Section("规则") {
                TextField("规则表达式", text: $rule, axis: .vertical)
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
                    if let hitCount {
                        HStack {
                            Text("命中 \(hitCount) 项")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
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
                mode = .json
                content = mode.sampleContent
                rule = mode.preset
            }
        }
    }

    private func run() {
        let engine = RuleEngine()
        do {
            switch mode {
            case .json, .regex:
                let values = try engine.getStringList(rule, content: content)
                output = values.joined(separator: "\n")
                hitCount = values.count
                isError = false
            case .css, .xpath:
                // CSS / XPath 直接对 HTML 求值，返回命中列表
                let values = try evaluateCssXPath(rule, content: content)
                output = values.joined(separator: "\n")
                hitCount = values.count
                isError = false
            }
        } catch {
            output = error.localizedDescription
            isError = true
            hitCount = nil
        }
    }

    /// CSS / XPath 在此直接经 HtmlRuleEngine 求值（不经 RuleEngine 的链式包装），
    /// 便于在测试台观察原始命中结果。
    private func evaluateCssXPath(_ rule: String, content: String) throws -> [String] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("@css:") || trimmed.hasPrefix("@@") {
            var body = trimmed
            if lower.hasPrefix("@css:") { body = String(trimmed.dropFirst(5)) }
            if body.hasPrefix("@@") { body = String(body.dropFirst(2)) }
            return try HtmlRuleEngine.shared.evaluateCss(body, rootHTML: content)
        }
        if lower.hasPrefix("@xpath:") {
            return try HtmlRuleEngine.shared.evaluateXPath(String(trimmed.dropFirst(7)), rootHTML: content)
        }
        // 裸 XPath
        return try HtmlRuleEngine.shared.evaluateXPath(trimmed, rootHTML: content)
    }
}

struct RuleTestView_Previews: PreviewProvider {
    static var previews: some View {
        RuleTestView(presetRule: "")
    }
}