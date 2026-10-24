import SwiftUI

struct SourceDetailView: View {
    @EnvironmentObject private var store: BookSourceStore
    let source: BookSource

    var body: some View {
        List {
            Section("基本信息") {
                LabeledContent("名称", value: source.bookSourceName.isEmpty ? "未命名" : source.bookSourceName)
                LabeledContent("分组", value: source.bookSourceGroup ?? "未分组")
                LabeledContent("类型", value: source.typeName)
                LabeledContent("地址", value: source.bookSourceUrl)
                Toggle("启用", isOn: Binding(
                    get: { source.enabled },
                    set: { _ in store.toggle(source) }
                ))
            }

            Section("规则") {
                ruleRow("搜索", source.ruleSearch)
                ruleRow("发现", source.ruleExplore)
                ruleRow("详情", source.ruleBookInfo)
                ruleRow("目录", source.ruleToc)
                ruleRow("正文", source.ruleContent)
            }

            Section {
                NavigationLink {
                    RuleTestView(presetRule: source.ruleContent?.content ?? "")
                } label: {
                    Label("规则测试台", systemImage: "wrench.and.screwdriver")
                }
            } footer: {
                Text("P0 引擎支持 JSON / 正则 / JS 规则；HTML 规则（CSS / XPath）将在 P1 开放。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(source.bookSourceName.isEmpty ? "书源" : source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func ruleRow(_ title: String, _ ruleSet: SourceRuleSet?) -> some View {
        if let ruleSet = ruleSet, !ruleSet.isEmpty {
            NavigationLink {
                RuleSetDetailView(title: title, ruleSet: ruleSet)
            } label: {
                Text(title)
            }
        }
    }
}

private struct RuleRow: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

struct RuleSetDetailView: View {
    let title: String
    let ruleSet: SourceRuleSet

    private var rows: [RuleRow] {
        let candidates: [(String, String?)] = [
            ("bookList", ruleSet.bookList),
            ("name", ruleSet.name),
            ("author", ruleSet.author),
            ("intro", ruleSet.intro),
            ("kind", ruleSet.kind),
            ("lastChapter", ruleSet.lastChapter),
            ("bookUrl", ruleSet.bookUrl),
            ("coverUrl", ruleSet.coverUrl),
            ("wordCount", ruleSet.wordCount),
            ("init", ruleSet.initRule),
            ("tocUrl", ruleSet.tocUrl),
            ("downloadUrls", ruleSet.downloadUrls),
            ("chapterList", ruleSet.chapterList),
            ("chapterName", ruleSet.chapterName),
            ("chapterUrl", ruleSet.chapterUrl),
            ("isVolume", ruleSet.isVolume),
            ("nextTocUrl", ruleSet.nextTocUrl),
            ("content", ruleSet.content),
            ("nextContentUrl", ruleSet.nextContentUrl),
            ("subContent", ruleSet.subContent),
            ("title", ruleSet.title)
        ]
        return candidates.compactMap { pair in
            guard let value = pair.1, !value.isEmpty else { return nil }
            return RuleRow(key: pair.0, value: value)
        }
    }

    var body: some View {
        List(rows) { row in
            VStack(alignment: .leading, spacing: 6) {
                Text(row.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
