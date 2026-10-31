import Foundation
import SwiftUI

/// 阅读器排版与翻页设置，持久化到 Documents/reader_settings.json
///
/// 字段对齐 LEGADO：多种日间背景 + 独立日/夜开关、字号、字距、行距、
/// 正文字体、翻页模式（滚动 / 左右翻页）、翻页动画（滑动 / 仿真 / 无）。
/// 旧版设置文件缺新字段时整体解码失败 → load() 忽略并回退默认值，保证升级不崩。
@MainActor
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    /// 阅读背景（日间预设，对齐 LEGADO 6 种护眼底色）
    enum Theme: String, CaseIterable, Codable {
        case paper = "羊皮纸"   // 米黄
        case green = "护眼"     // 淡绿
        case blue  = "淡蓝"
        case pink  = "淡粉"
        case gray  = "浅灰"
        case white = "纯白"

        var background: Color {
            switch self {
            case .paper: return Color(red: 0.96, green: 0.93, blue: 0.86)
            case .green: return Color(red: 0.90, green: 0.95, blue: 0.90)
            case .blue:  return Color(red: 0.92, green: 0.95, blue: 0.97)
            case .pink:  return Color(red: 0.97, green: 0.92, blue: 0.92)
            case .gray:  return Color(red: 0.93, green: 0.93, blue: 0.93)
            case .white: return Color.white
            }
        }

        var foreground: Color {
            switch self {
            case .paper: return Color(red: 0.28, green: 0.22, blue: 0.14)
            case .green: return Color(red: 0.20, green: 0.30, blue: 0.20)
            case .blue:  return Color(red: 0.18, green: 0.25, blue: 0.32)
            case .pink:  return Color(red: 0.35, green: 0.20, blue: 0.22)
            case .gray:  return Color(red: 0.20, green: 0.20, blue: 0.22)
            case .white: return Color(red: 0.10, green: 0.10, blue: 0.10)
            }
        }
    }

    /// 字体族
    enum FontFamily: String, CaseIterable, Codable {
        case system = "系统"
        case songti = "宋体"
        case heiti  = "黑体"
        case kaiti  = "楷体"

        /// 预设对应的 SwiftUI 字体（不含字号，由 textFont 统一加 size）
        var base: Font {
            switch self {
            case .system: return .system(.body, design: .default)
            case .songti: return .system(.body, design: .serif)
            case .heiti:  return .system(.body, design: .default)
            case .kaiti:  return Font.custom("Kaiti SC", size: 17)
            }
        }
    }

    /// 翻页模式：滚动（连续纵向） / 左右翻页（按章分页横向）
    enum PageMode: String, CaseIterable, Codable {
        case scroll = "滚动"
        case page   = "左右翻页"
    }

    /// 翻页动画：滑动 / 仿真（卷页）/ 无
    /// 注：仿真在 SwiftUI TabView 下暂以滑动呈现，后续可换 UIPageViewController 实现真卷页。
    enum PageAnimation: String, CaseIterable, Codable {
        case slide = "滑动"
        case curl  = "仿真"
        case none  = "无"
    }

    // MARK: - 排版

    @Published var theme: Theme = .paper
    @Published var isNight: Bool = false
    @Published var fontFamily: FontFamily = .system
    @Published var customFontName: String = ""   // 自定义字体名（留空则用 fontFamily）
    @Published var fontSize: Double = 18          // 点
    @Published var letterSpacing: Double = 0      // 字间距（pt）
    @Published var lineSpacing: Double = 8        // 额外行距（pt）
    @Published var justified: Bool = true         // 左右对齐
    @Published var showChapterHeader: Bool = true // 章节标题

    // MARK: - 翻页

    @Published var pageMode: PageMode = .scroll
    @Published var pageAnimation: PageAnimation = .slide

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = docs.appendingPathComponent("reader_settings.json")
        load()
    }

    // MARK: - 派生

    /// 有效背景色：夜间模式优先（深底），否则取当前背景主题
    var effectiveBackground: Color {
        isNight ? Color(red: 0.12, green: 0.12, blue: 0.13) : theme.background
    }

    /// 有效前景色：夜间模式优先（白字），否则取当前主题前景
    var effectiveForeground: Color {
        isNight ? Color.white : theme.foreground
    }

    /// 当前正文字体（含字号与自定义字体名）
    var textFont: Font {
        if !customFontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .custom(customFontName, size: fontSize)
        }
        // 把预设基准字体按当前字号重建（base 是 .body 尺寸，需显式化字号）
        switch fontFamily {
        case .system: return .system(size: fontSize, design: .default)
        case .songti: return .system(size: fontSize, design: .serif)
        case .heiti:  return .system(size: fontSize, design: .default)
        case .kaiti:  return Font.custom("Kaiti SC", size: fontSize)
        }
    }

    // MARK: - 持久化

    private struct SettingsData: Codable {
        var theme: Theme
        var isNight: Bool
        var fontFamily: FontFamily
        var customFontName: String
        var fontSize: Double
        var letterSpacing: Double
        var lineSpacing: Double
        var justified: Bool
        var showChapterHeader: Bool
        var pageMode: PageMode
        var pageAnimation: PageAnimation
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(SettingsData.self, from: data) else {
            return
        }
        theme = decoded.theme
        isNight = decoded.isNight
        fontFamily = decoded.fontFamily
        customFontName = decoded.customFontName
        fontSize = decoded.fontSize
        letterSpacing = decoded.letterSpacing
        lineSpacing = decoded.lineSpacing
        justified = decoded.justified
        showChapterHeader = decoded.showChapterHeader
        pageMode = decoded.pageMode
        pageAnimation = decoded.pageAnimation
    }

    func save() {
        let dataObj = SettingsData(
            theme: theme, isNight: isNight, fontFamily: fontFamily,
            customFontName: customFontName, fontSize: fontSize,
            letterSpacing: letterSpacing, lineSpacing: lineSpacing,
            justified: justified, showChapterHeader: showChapterHeader,
            pageMode: pageMode, pageAnimation: pageAnimation
        )
        guard let data = try? JSONEncoder().encode(dataObj) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func apply(_ theme: Theme) {
        self.theme = theme
        save()
    }
}
