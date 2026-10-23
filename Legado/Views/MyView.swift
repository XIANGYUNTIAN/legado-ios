import SwiftUI

struct MyView: View {
    var body: some View {
        Form {
            Section("当前进度") {
                LabeledContent("版本", value: "P0 骨架 1.0.0")
                LabeledContent("规则引擎", value: "JSON / 正则 / JS")
                LabeledContent("数据存储", value: "本地 JSON（P1 迁移 SQLite）")
            }

            Section("关于") {
                Text("Legado for iOS 是 legado-E（阅读Sigma，GPL-3.0）的 iOS 复刻工程。本软件不提供任何内容，需自行导入书源。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("GPL-3.0 许可证", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }

            Section("路线图") {
                Text("P1：HTML 规则（SwiftSoup）+ 网络层 + 书架")
                Text("P2：阅读器分页 / 翻页动画 / TTS 朗读")
                Text("P3：WebDav 同步 / Web 服务 / RSS")
                Text("P4：音频歌词 / 视频弹幕 / 漫画")
            }
            .font(.footnote)
        }
        .navigationTitle("我的")
    }
}
