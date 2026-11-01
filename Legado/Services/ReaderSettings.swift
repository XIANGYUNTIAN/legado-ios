import Foundation
import SwiftUI
import UIKit
import CoreText

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

    // MARK: - 沉浸式阅读（隐藏状态栏与工具栏）

    @Published var isImmersive: Bool = false

    /// 运行时字体就绪计数：宋体/楷体等「非预装、按需下载」CJK 字体下载完成时自增，
    /// 驱动阅读视图（尤其翻页模式）重新排版，使新字体立即生效。无需持久化。
    @Published var fontReadyTick: Int = 0

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

    /// 当前正文字体（含字号与自定义字体名）。滚动/翻页两套渲染路径共用同一解析。
    var textFont: Font {
        Font(resolvedUIFont())
    }

    /// 解析为实际 UIFont：自定义字体名优先，否则按预设族加载。
    /// 系统/黑体用苹方（黑体用中字重区分）；宋体/楷体为 iOS 非预装字体，需经动态下载，
    /// 未就绪时先兜底系统字体保证可读，下载完成后由 `fontReadyTick` 驱动重排切换。
    func resolvedUIFont() -> UIFont {
        Self.uiFont(for: fontFamily, size: CGFloat(fontSize), customName: customFontName)
    }

    /// 按字体族解析 UIFont（供正文与设置面板预览共用）。
    ///
    /// - Note: 宋体/楷体在 iOS 上为「按需下载」字体（非预装）：首次使用会经 `ensureCJKFont`
    ///          异步下载；已就绪则直接返回，未就绪则兜底系统字体，下载完成后自动生效。
    static func uiFont(for family: FontFamily, size: CGFloat, customName: String) -> UIFont {
        if !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return UIFont(name: customName, size: size) ?? .systemFont(ofSize: size)
        }
        let psName: String?
        switch family {
        case .songti: psName = "Songti SC"
        case .kaiti:  psName = "Kaiti SC"
        case .system, .heiti: psName = nil
        }
        if let ps = psName {
            if let f = UIFont(name: ps, size: size) { return f }
            shared.ensureCJKFont(ps)        // 未就绪：后台下载，当前兜底系统字体
            return .systemFont(ofSize: size)
        }
        // 系统/黑体：iOS 黑体（Heiti SC）同样非预装，用中字重苹方区分，避免依赖下载。
        return family == .heiti ? .systemFont(ofSize: size, weight: .semibold)
                                : .systemFont(ofSize: size)
    }

    // MARK: - CJK 动态字体下载

    /// iOS 非预装字体（宋体/楷体）的下载去重与调度。独立于 MainActor，使其可被下载回调的任意线程安全访问。
    private struct FontDownloadTracker {
        static let queue = DispatchQueue(label: "legado.cjk.font.dl")
        static var downloading: Set<String> = []
    }

    /// 若指定 PostScript 字体名尚未就绪，则经 Core Text 动态下载；下载完成后 `fontReadyTick`
    /// 自增，由阅读视图重排生效。已就绪或已在进行中则直接返回（避免重复下载）。
    func ensureCJKFont(_ postScriptName: String) {
        guard UIFont(name: postScriptName, size: 12) == nil else { return }
        var shouldStart = false
        FontDownloadTracker.queue.sync {
            if !FontDownloadTracker.downloading.contains(postScriptName) {
                FontDownloadTracker.downloading.insert(postScriptName)
                shouldStart = true
            }
        }
        guard shouldStart else { return }
        let descriptor = CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, 0)
        _ = CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, .downloadFonts) { state, _, _ -> Bool in
            // CTFontMatchState.rawValue：0=inProgress，1=matched，2=failure；1/2 都代表本轮匹配结束
            if state.rawValue >= 1 {
                FontDownloadTracker.queue.sync { FontDownloadTracker.downloading.remove(postScriptName) }
                DispatchQueue.main.async { [weak self] in self?.fontReadyTick += 1 }
            }
            return true
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
        var isImmersive: Bool
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
        isImmersive = decoded.isImmersive
    }

    func save() {
        let dataObj = SettingsData(
            theme: theme, isNight: isNight, fontFamily: fontFamily,
            customFontName: customFontName, fontSize: fontSize,
            letterSpacing: letterSpacing, lineSpacing: lineSpacing,
            justified: justified, showChapterHeader: showChapterHeader,
            pageMode: pageMode, pageAnimation: pageAnimation,
            isImmersive: isImmersive
        )
        guard let data = try? JSONEncoder().encode(dataObj) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func apply(_ theme: Theme) {
        self.theme = theme
        save()
    }
}
