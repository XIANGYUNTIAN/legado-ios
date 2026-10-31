import Foundation
import SwiftUI

/// 书架布局设置：列表 / 网格、网格列数，持久化到 Documents/bookshelf_layout.json
@MainActor
final class BookshelfSettings: ObservableObject {
    static let shared = BookshelfSettings()

    enum Layout: String, CaseIterable, Codable {
        case list = "列表"
        case grid = "网格"
    }

    /// 网格列数可选项（LEGADO 的「几×几」以列数表达）
    static let gridColumnOptions: [Int] = [2, 3, 4, 5]

    @Published var layout: Layout = .list
    @Published var gridColumns: Int = 3

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = docs.appendingPathComponent("bookshelf_layout.json")
        load()
    }

    private struct Data: Codable {
        var layout: Layout
        var gridColumns: Int
    }

    func load() {
        guard let data = try? Foundation.Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Data.self, from: data) else { return }
        layout = decoded.layout
        if Self.gridColumnOptions.contains(decoded.gridColumns) {
            gridColumns = decoded.gridColumns
        }
    }

    func save() {
        let obj = Data(layout: layout, gridColumns: gridColumns)
        guard let data = try? JSONEncoder().encode(obj) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
