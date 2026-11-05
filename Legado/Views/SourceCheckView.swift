import SwiftUI

// MARK: - 书源检测结果页
//
// 公子 2026-11-05 需求：「筛查书源是否失效，并将失效书源直接选中，自助决定
// 是否一键删除或部分删除」。
// - 检测完成后失效行自动勾选，可逐个取消 → 部分删除；
// - 「全选失效」+「删除选中」→ 一键删除全部失效；
// - 「返回列表并选中」把勾选集回传书源列表，在列表里继续自助删除。
// 「无法检测」的书源不自动选中，避免误删。

struct SourceCheckView: View {
    let sources: [BookSource]
    let onApplySelection: (Set<String>) -> Void
    let onDelete: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var targets: [SourceCheckTarget] = []
    @State private var results: [String: SourceCheckResult] = [:]
    @State private var checked: Set<String> = []
    @State private var doneCount = 0
    @State private var isRunning = false
    @State private var failedFirst = true
    @State private var showDeleteConfirm = false
    @State private var deleteAllFailed = false
    @State private var runTask: Task<Void, Never>?

    // 结构含 private @State 时合成 memberwise init 会是 private，必须显式声明
    init(sources: [BookSource],
         onApplySelection: @escaping (Set<String>) -> Void,
         onDelete: @escaping (Set<String>) -> Void) {
        self.sources = sources
        self.onApplySelection = onApplySelection
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                List {
                    Section("检测结果") {
                        ForEach(displayTargets) { target in
                            resultRow(target)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                actionBar
            }
            .navigationTitle("书源检测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { stop(); dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Button(role: .destructive) {
                                checked = Set(failedIDs)
                                deleteAllFailed = true
                                showDeleteConfirm = true
                            } label: {
                                Label("一键删除全部失效（\(failedCount)）", systemImage: "trash")
                            }
                            .disabled(failedCount == 0 || isRunning)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        if isRunning {
                            Button("停止") { stop() }
                        } else {
                            Button("重新检测") { start() }
                        }
                    }
                }
            }
            .confirmationDialog("确认删除", isPresented: $showDeleteConfirm) {
                Button(deleteAllFailed
                       ? "删除全部 \(checked.count) 个失效书源"
                       : "删除 \(checked.count) 个书源", role: .destructive) {
                    onDelete(checked)
                    stop()
                    dismiss()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text(deleteAllFailed
                     ? "将永久删除本次检测出的全部失效书源，不可恢复。"
                     : "将永久删除选中的 \(checked.count) 个书源，不可恢复。未勾选的书源会保留。")
            }
            .onAppear { start() }
            .onDisappear { stop() }
        }
    }

    // MARK: - 顶部进度

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已检测 \(doneCount) / \(targets.count)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isRunning { ProgressView().scaleEffect(0.8) }
                Text("失效 \(failedCount) · 可用 \(okCount) · 无法检测 \(unknownCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(doneCount), total: Double(max(targets.count, 1)))
            Text("仅检测站点连通性，不代表搜索 / 目录 / 正文规则仍可用。401/403 视为站点可达，"
                 + "无地址标为「无法检测」且不自动选中。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - 底部操作

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button(failedFirst ? "失效优先" : "按原顺序") { failedFirst.toggle() }
                Spacer()
                Button("全选失效") { checked = Set(failedIDs) }
                    .disabled(failedIDs.isEmpty)
                Button("取消全选") { checked = [] }
                    .disabled(checked.isEmpty)
            }
            .font(.caption)
            HStack(spacing: 12) {
                Button {
                    onApplySelection(checked)
                    stop()
                    dismiss()
                } label: {
                    Text("返回列表并选中（\(checked.count)）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(checked.isEmpty)
                Button {
                    deleteAllFailed = false
                    showDeleteConfirm = true
                } label: {
                    Text("删除选中（\(checked.count)）")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(checked.isEmpty || isRunning)
            }
            .font(.subheadline)
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - 结果行

    private func resultRow(_ target: SourceCheckTarget) -> some View {
        let record = results[target.id]
        let state = record?.state
        return HStack(spacing: 10) {
            Image(systemName: symbol(for: state))
                .foregroundStyle(color(for: state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(record?.detail ?? (isRunning ? "检测中…" : "待检测"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(target.host)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if state == .failed {
                Button {
                    toggle(target.id)
                } label: {
                    Image(systemName: checked.contains(target.id)
                          ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checked.contains(target.id)
                                         ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
            } else if let record {
                Text("\(record.milliseconds) ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 检测调度

    /// 分批并发（每批 5 个），避免上百个书源同时打满 URLSession；
    /// 结果先收进局部数组再统一写 @State，检测过程中列表不会逐条跳动。
    private func start() {
        guard !isRunning else { return }
        stop()
        if targets.isEmpty { targets = SourceHealthChecker.targets(from: sources) }
        results = [:]
        checked = []
        doneCount = 0
        isRunning = true
        let list = targets
        runTask = Task { @MainActor in
            let batchSize = 5
            var index = 0
            while index < list.count {
                if Task.isCancelled { break }
                let end = min(index + batchSize, list.count)
                let slice = Array(list[index..<end])
                let batch = await withTaskGroup(
                    of: SourceCheckResult.self,
                    returning: [SourceCheckResult].self
                ) { group in
                    for target in slice {
                        group.addTask { await SourceHealthChecker.check(target) }
                    }
                    var collected: [SourceCheckResult] = []
                    for await item in group { collected.append(item) }
                    return collected
                }
                if Task.isCancelled { break }
                for item in batch {
                    results[item.id] = item
                    // 失效源直接选中；「无法检测」不选中，避免误删
                    if item.state == .failed { checked.insert(item.id) }
                }
                doneCount += batch.count
                index = end
            }
            isRunning = false
        }
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    private func toggle(_ id: String) {
        if checked.contains(id) { checked.remove(id) }
        else { checked.insert(id) }
    }

    // MARK: - 派生数据

    private var failedIDs: [String] {
        targets.filter { results[$0.id]?.state == .failed }.map { $0.id }
    }
    private var failedCount: Int {
        results.values.filter { $0.state == .failed }.count
    }
    private var okCount: Int {
        results.values.filter { $0.state == .ok }.count
    }
    private var unknownCount: Int {
        results.values.filter { $0.state == .unknown }.count
    }

    private var displayTargets: [SourceCheckTarget] {
        guard failedFirst, !isRunning else { return targets }
        return targets.sorted { rank(results[$0.id]?.state) < rank(results[$1.id]?.state) }
    }

    private func rank(_ state: SourceCheckState?) -> Int {
        switch state {
        case .failed: return 0
        case .unknown: return 1
        case .cancelled: return 2
        case .ok: return 3
        case nil: return 4
        }
    }

    private func symbol(for state: SourceCheckState?) -> String {
        switch state {
        case .failed: return "xmark.circle.fill"
        case .ok: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case nil: return "clock"
        }
    }

    private func color(for state: SourceCheckState?) -> Color {
        switch state {
        case .failed: return .red
        case .ok: return .green
        case .unknown: return .orange
        default: return .secondary
        }
    }
}
