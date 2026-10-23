import Foundation
import SwiftUI

/// 阅读器排版设置（字体、字号、行距、主题），持久化到 Documents/reader_settings.json
@MainActor
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    /// 阅读主题
    enum Theme: String, CaseIterable, Codable {
        case light = "浅色"
        case sepia = "米色"
        case dark = "暗色"

        var background: Color {
            switch self {
            case .light: return Color(.systemBackground)
            case .sepia: return Color(red: 0.96, green: 0.93, blue: 0.86)
            case .dark: return Color(red: 0.12, green: 0.12, blue: 0.13)
            }
        }

        var foreground: Color {
            switch self {
            case .light: return Color(.label)
            case .sepia: return Color(red: 0.28, green: 0.22, blue: 0.14)
            case .dark: return Color.white
            }
        }
    }

    /// 字体族
    enum FontFamily: String, CaseIterable, Codable {
        case system = "系统"
        case songti = "宋体"
        case heiti = "黑体"
        case kaiti = "楷体"

        var font: Font {
            switch self {
            case .system: return .body
            case .songti: return Font.system(.body, design: .serif)
            case .heiti: return Font.system(.body, design: .default)
            case .kaiti: return Font.system(.body, design: .serif)
            }
        }
    }

    @Published var theme: Theme = .light
    @Published var fontFamily: FontFamily = .system
    @Published var fontSize: Double = 18          // 点
    @Published var lineSpacing: Double = 8        // 额外行距（pt）
    @Published var justified: Bool = true         // 左右对齐
    @Published var showChapterHeader: Bool = true // 章节标题

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = docs.appendingPathComponent("reader_settings.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ReaderSettings.self, from: data) else {
            return
        }
        theme = decoded.theme
        fontFamily = decoded.fontFamily
        fontSize = decoded.fontSize
        lineSpacing = decoded.lineSpacing
        justified = decoded.justified
        showChapterHeader = decoded.showChapterHeader
    }

    func save() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func apply(_ theme: Theme) {
        self.theme = theme
        save()
    }
}