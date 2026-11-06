import SwiftUI

// MARK: - 书源检测结果页
//
// 公子 2026-11-05 需求：筛查失效书源、失效源直接选中，自助决定一键 / 部分删除。
// 公子 2026-11-06 需求：合并去重检测，重复书源直接选中，确保相同的有效书源只保留一个。
// 两类问题独立统计、独立一键删除；「删除选中」对当前勾选集通用。
// 「无法检测」的书源不自动选中，避免误删；每个重复组的保留项永不因「重复」被选中。

private enum DeleteMode {
    case selected
    case failed
    case duplicate
}

struct SourceCheckView: View {
    let sources: [BookSource]
    let onApplySelection: (Set<String>) -> Void
    let onDelete: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var targets: [SourceCheckTarget] = []
    @State private var results: [String: SourceCheckResult] = [:]
    @State private var checked: Set<String> = []
    @State private var duplicateGroups: [SourceDuplicateGroup] = []
    /// 判重指纹（Sendable）：检测任务里重算分组只传它，不捕获非 Sendable 的 BookSource
    @State private var fingerprints: [SourceFingerprint] = []
    /// 用户手动改过的行：自动勾选重算时不覆盖这些行
    @State private var manualOverrides: Set<String> = []
    @State private var doneCount = 0
    @State private var isRunning = false
    @State private var failedFirst = true
    @State private var showDeleteConfirm = false
    @State private var deleteMode: DeleteMode = .selected
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
                    if !duplicateGroups.isEmpty {
                        Section("重复分组（\(duplicateGroups.count) 组）") {
                            ForEach(duplicateGroups) { group in
                                duplicateGroupRow(group)
                            }
                        }
                    }
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
                                checked = failedIDSet
                                deleteMode = .failed
                                showDeleteConfirm = true
                            } label: {
                                Label("一键删除全部失效（\(failedCount)）", systemImage: "trash")
                            }
                            .disabled(failedCount == 0 || isRunning)

                            Button(role: .destructive) {
                                // 已排除每组保留项，删完每组恰好剩 1 个
                                checked = duplicateIDSet
                                deleteMode = .duplicate
                                showDeleteConfirm = true
                            } label: {
                                Label("一键删除全部重复（\(duplicateCount)）",
                                      systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(duplicateCount == 0 || isRunning)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        if isRunning {
                            Button("停止") { stop(); syncAutoSelection() }
                        } else {
                            Button("重新检测") { start() }
                        }
                    }
                }
            }
            .confirmationDialog("确认删除", isPresented: $showDeleteConfirm) {
                Button(deleteTitle, role: .destructive) {
                    onDelete(checked)
                    stop()
                    dismiss()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text(deleteMessage)
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
            }
            Text("失效 \(failedCount) · 重复 \(duplicateCount) · 可用 \(okCount) · 无法检测 \(unknownCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: Double(doneCount), total: Double(max(targets.count, 1)))
            Text("仅检测站点连通性，不代表搜索 / 目录 / 正文规则仍可用；401/403 视为站点可达，"
                 + "无地址标为「无法检测」且不自动选中。重复按规范化地址判定"
                 + "（忽略 http/https、www、大小写、尾斜杠、默认端口；名称相同但地址不同不算重复），"
                 + "每组保留 1 个（保留项不自动选中），其余自动选中。")
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
                Button(failedFirst ? "问题优先" : "按原顺序") { failedFirst.toggle() }
                Spacer()
                Button("全选失效") { apply(selection: failedIDSet) }
                    .disabled(failedIDSet.isEmpty)
                Button("全选重复") { apply(selection: duplicateIDSet) }
                    .disabled(duplicateIDSet.isEmpty)
                Button("取消全选") {
                    manualOverrides.formUnion(failedIDSet.union(duplicateIDSet))
                    checked = []
                }
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
                    deleteMode = .selected
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

    // MARK: - 重复分组行

    private func duplicateGroupRow(_ group: SourceDuplicateGroup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("保留「\(group.keepName)」，重复 \(group.duplicateIDs.count) 个")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("选中重复") {
                checked.formUnion(group.duplicateIDs)
                manualOverrides.formUnion(group.duplicateIDs)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 结果行

    private func resultRow(_ target: SourceCheckTarget) -> some View {
        let record = results[target.id]
        let state = record?.state
        let isDuplicate = duplicateIDSet.contains(target.id)
        let isKeeper = keptIDSet.contains(target.id)
        let tag = isDuplicate ? "【重复】" : (isKeeper ? "【保留】" : "")
        return HStack(spacing: 10) {
            Image(systemName: symbol(for: state))
                .foregroundStyle(color(for: state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(tag + (record?.detail ?? (isRunning ? "检测中…" : "待检测")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(target.host)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if state == .failed || isDuplicate {
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
        manualOverrides = []
        doneCount = 0
        isRunning = true
        // 检测前先按「启用 / 规则完整 / 原顺序」给出保留项；检测中随结果重算
        fingerprints = SourceDuplicateDetector.fingerprints(from: sources)
        duplicateGroups = SourceDuplicateDetector.groups(from: fingerprints, health: [:])
        let list = targets
        let prints = fingerprints
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
                for item in batch { results[item.id] = item }
                doneCount += batch.count
                index = end
                duplicateGroups = SourceDuplicateDetector.groups(
                    from: prints, health: results.mapValues { $0.state })
                // 失效 + 重复自动勾选；保留项与用户手动改过的行不覆盖
                syncAutoSelection()
            }
            isRunning = false
        }
    }

    private func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    /// 把「失效 ∪ 重复」同步进勾选集合，同时撤回已不再属于建议项的自动勾选。
    private func syncAutoSelection() {
        // 重复组的保留项不因「失效」被自动勾选，避免自动勾选集把整组清空；
        // 用户仍可手动勾选它，或用「一键删除全部失效」主动删除。
        let suggested = failedIDSet.union(duplicateIDSet).subtracting(keptIDSet)
        for id in suggested where !manualOverrides.contains(id) {
            checked.insert(id)
        }
        let snapshot = checked
        for id in snapshot where !manualOverrides.contains(id) && !suggested.contains(id) {
            checked.remove(id)
        }
    }

    private func toggle(_ id: String) {
        manualOverrides.insert(id)
        if checked.contains(id) { checked.remove(id) }
        else { checked.insert(id) }
    }

    private func apply(selection: Set<String>) {
        checked = selection
        manualOverrides.formUnion(selection)
    }

    // MARK: - 派生数据

    private var failedIDs: [String] {
        targets.filter { results[$0.id]?.state == .failed }.map { $0.id }
    }
    private var failedIDSet: Set<String> { Set(failedIDs) }
    private var duplicateIDSet: Set<String> {
        Set(duplicateGroups.flatMap { $0.duplicateIDs })
    }
    private var duplicateCount: Int { duplicateIDSet.count }
    private var keptIDSet: Set<String> { Set(duplicateGroups.map { $0.keepID }) }
    private var failedCount: Int {
        results.values.filter { $0.state == .failed }.count
    }
    private var okCount: Int {
        results.values.filter { $0.state == .ok }.count
    }
    private var unknownCount: Int {
        results.values.filter { $0.state == .unknown }.count
    }

    private var deleteTitle: String {
        switch deleteMode {
        case .failed: return "删除全部 \(checked.count) 个失效书源"
        case .duplicate: return "删除 \(checked.count) 个重复书源"
        case .selected: return "删除 \(checked.count) 个书源"
        }
    }

    private var deleteMessage: String {
        switch deleteMode {
        case .failed:
            return "将永久删除本次检测出的全部失效书源，不可恢复。"
        case .duplicate:
            return "将永久删除各重复组中多余的 \(checked.count) 个书源，每组保留 1 个，不可恢复。"
        case .selected:
            return "将永久删除选中的 \(checked.count) 个书源，不可恢复。未勾选的书源会保留。"
        }
    }

    private var displayTargets: [SourceCheckTarget] {
        guard failedFirst, !isRunning else { return targets }
        return targets.enumerated().sorted { a, b in
            let ra = problemRank(a.element.id), rb = problemRank(b.element.id)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map { $0.element }
    }

    private func problemRank(_ id: String) -> Int {
        if results[id]?.state == .failed { return 0 }
        if duplicateIDSet.contains(id) { return 1 }
        switch results[id]?.state {
        case .some(.unknown): return 2
        case .some(.cancelled): return 3
        case .some(.ok): return 4
        default: return 5
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
