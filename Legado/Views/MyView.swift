import SwiftUI

struct MyView: View {
    private let authorName = "小马哥"
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
                Text(verbatim: "作者：" + authorName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("免责声明：本应用为开源阅读工具，不内置、不托管、不分发任何受版权保护的书籍或内容，亦不提供任何书源。所有书籍与书源均由用户自行添加与管理，相关版权及合规责任由使用者自行承担。本应用与任何内容提供方无任何关联，不对用户使用本应用所产生的行为及后果承担责任。")
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
