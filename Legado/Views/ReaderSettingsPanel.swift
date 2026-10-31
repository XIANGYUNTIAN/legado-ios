import SwiftUI

/// 阅读设置浮层（非 sheet）：底部卡片式面板，覆盖在阅读内容上方。
///
/// 关键点：面板与阅读内容同处一个视图层级，阅读页仍渲染在面板之上/之后，
/// 因此改动字号/字距/背景/日夜间等设置时，正文实时联动（live preview），
/// 无需退出阅读界面——对齐 LEGADO 的设置交互。
struct ReaderSettingsPanel: View {
    @ObservedObject var settings: ReaderSettings
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部把手 + 标题 + 完成
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 36, height: 4)
                Spacer()
            }
            .padding(.top, 8)

            HStack {
                Text("阅读设置")
                    .font(.headline)
                Spacer()
                Button("完成") { onClose() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    themeRow
                    nightRow
                    fontRow
                    fontSizeRow
                    letterSpacingRow
                    lineSpacingRow
                    pageModeRow
                    pageAnimationRow
                    immersiveRow
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity)
        // 高度上限：面板经 safeAreaInset 底部承载，正文在其上方可见并可实时联动。
        // 若不做上限，内部 ScrollView（贪婪）会撑到近全屏，把正文挤成窄条、遮挡效果。
        .frame(maxHeight: 300, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 16, y: -4)
    }

    // MARK: - 背景主题色卡

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowLabel("阅读背景")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                        Button {
                            settings.theme = theme
                            settings.save()
                        } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.background)
                                .frame(width: 44, height: 60)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(settings.theme == theme ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text(theme.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(theme.foreground.opacity(0.85))
                                )
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 夜间模式 / 沉浸式

    private var nightRow: some View {
        Toggle("夜间模式", isOn: $settings.isNight)
            .onChange(of: settings.isNight) { _, _ in settings.save() }
    }

    private var immersiveRow: some View {
        Toggle("沉浸式阅读（隐藏状态栏与工具栏）", isOn: $settings.isImmersive)
            .onChange(of: settings.isImmersive) { _, _ in settings.save() }
    }

    // MARK: - 字体

    private var fontRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowLabel("正文字体")
            HStack(spacing: 8) {
                ForEach(ReaderSettings.FontFamily.allCases, id: \.self) { font in
                    Button {
                        settings.fontFamily = font
                        settings.save()
                    } label: {
                        Text(font.rawValue)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(settings.fontFamily == font ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(settings.fontFamily == font ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                            .foregroundStyle(settings.fontFamily == font ? Color.accentColor : Color.primary)
                    }
                }
            }
            TextField("自定义字体名（留空用上方预设）", text: $settings.customFontName)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .onChange(of: settings.customFontName) { _, _ in settings.save() }
        }
    }

    // MARK: - 字号 / 字距 / 行距

    private var fontSizeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("字号：\(Int(settings.fontSize))pt")
            Slider(value: $settings.fontSize, in: 12...40, step: 1)
                .tint(.accentColor)
                .onChange(of: settings.fontSize) { _, _ in settings.save() }
        }
    }

    private var letterSpacingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("字间距：\(String(format: "%.1f", settings.letterSpacing))pt")
            Slider(value: $settings.letterSpacing, in: -1...6, step: 0.5)
                .tint(.accentColor)
                .onChange(of: settings.letterSpacing) { _, _ in settings.save() }
        }
    }

    private var lineSpacingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("行距：\(Int(settings.lineSpacing))pt")
            Slider(value: $settings.lineSpacing, in: 0...24, step: 1)
                .tint(.accentColor)
                .onChange(of: settings.lineSpacing) { _, _ in settings.save() }
        }
    }

    // MARK: - 翻页模式 / 动画

    private var pageModeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("翻页模式")
            Picker("翻页模式", selection: $settings.pageMode) {
                ForEach(ReaderSettings.PageMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.pageMode) { _, _ in settings.save() }
        }
    }

    private var pageAnimationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("翻页动画")
            Picker("翻页动画", selection: $settings.pageAnimation) {
                ForEach(ReaderSettings.PageAnimation.allCases, id: \.self) { anim in
                    Text(anim.rawValue).tag(anim)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.pageAnimation) { _, _ in settings.save() }
        }
    }

    // MARK: - 辅助

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }
}
