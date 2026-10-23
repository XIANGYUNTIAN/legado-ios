# Legado for iOS（P0 骨架）

[legado-E（阅读Sigma）](https://github.com/Luoyacheng/legado-E) 的 iOS 复刻工程。GPL-3.0 衍生项目，**必须保持开源**。软件本身不提供任何内容，需自行导入书源。

## 当前进度（P0）

| 模块 | 状态 |
|---|---|
| Xcode 工程（XcodeGen） | ✅ |
| GitHub Actions 构建未签名 IPA | ✅ |
| 书源 JSON 模型（legado 格式对齐） | ✅ |
| 规则引擎（JSON / 正则 / JS 三模式，`&&`/`||`/`%%`/`@put`/`@get`/`{{}}`/`$n`/`##` 全语法） | ✅ |
| 书源导入 / 列表 / 详情 / 规则测试台 | ✅ |
| 书架 / 阅读器 / TTS / WebDav / Web 服务 | ⏳ P1–P4 |

规则引擎与 Android 端 `AnalyzeRule` 的对应关系见 `Legado/Engine/RuleEngine.swift` 头部注释。CSS / XPath 模式依赖 HTML 解析，P1 集成 SwiftSoup 后开放。

## 快速开始：三步拿到 IPA

```bash
# 1. 安装 GitHub CLI（Windows，如未安装）
winget install --id GitHub.cli -e

# 2. 登录 GitHub
gh auth login

# 3. 创建公开仓库并推送（公开仓库的 macOS Runner 免费且不限时长）
cd legado-ios
gh repo create legado-ios --public --source=. --remote=origin --push --description "Legado for iOS - legado-E(阅读Sigma) 的 iOS 复刻"
```

推送后 GitHub Actions 自动触发 `build-ios-ipa`（约 3–6 分钟）。

> 没有 gh 也可以：GitHub 网页创建空仓库后
> `git remote add origin https://github.com/<你的账号>/legado-ios.git && git push -u origin main`

## 下载未签名 IPA

```bash
# 命令行（在 legado-ios 目录外执行）
gh run download --repo <你的账号>/legado-ios --name Legado-unsigned-ipa
```

或网页操作：仓库 → Actions → 最新一次 `build-ios-ipa` → 页面底部 Artifacts → **Legado-unsigned-ipa**（zip 内含 `Legado-unsigned.ipa`）。Artifact 默认保留 90 天。

## 用你的 Apple ID 签名安装（AltStore / SideStore）

### AltStore（Windows，推荐）

1. 安装 **iTunes** 与 **iCloud**（注意：必须是 Apple 官网版，不是 Microsoft Store 版）
2. 下载安装 [AltServer for Windows](https://altstore.io/)
3. 任务栏 AltServer 图标 → **Install AltStore** → 选择你的 iPhone → 输入 **Apple ID**
4. iPhone 首次打开 AltStore 后：设置 → 通用 → VPN与设备管理 → 信任开发者
5. 把 IPA 传到 iPhone（微信文件传输 / 邮件 / 网盘均可），用**分享菜单 → AltStore** 安装；或在 AltStore → My Apps → 「+」选择 IPA
6. 免费 Apple ID 签名 **7 天有效**：每周连一次电脑，打开 AltStore 刷新（保持登录同一 Apple ID）
7. 若提示「无法验证应用」：设置 → 通用 → 设备管理 → 信任

### SideStore（无需电脑常驻，首次配对稍麻烦）

按 [SideStore 官方文档](https://docs.sidestore.io/) 安装；Windows 下需要生成配对文件，教程见文档 "Windows" 章节。适合不想每周连电脑的用户。

### 签名注意事项

- 免费证书 **7 天过期**，最多 3 个 App ID；付费开发者账号（99 美元/年）证书 1 年有效，且可用 TestFlight 分发给最多 100 人
- 同一个 Apple ID 一周内新建 App ID 有数量限制，反复重装会耗尽配额——必要时换用 SideStore 或付费账号
- iOS 27 设备如提示「不受支持」，说明 Runner 的 Xcode 太旧：编辑 `.github/workflows/build-ios.yml`，把 `xcode-version: latest-stable` 改成具体版本（如 `"27.0"`）后重新推送

## GitHub Actions 说明

- Runner：`macos-15`，用 [maxim-lobanov/setup-xcode](https://github.com/maxim-lobanov/setup-xcode) 选最新稳定 Xcode
- 构建方式：`xcodegen generate` 生成工程 → `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO` 不签名）→ 打包 `Payload/Legado.app` 为 IPA → 上传 Artifact
- **公开仓库** macOS  Runner 免费不限时长；私有仓库免费额度 2000 分钟/月且 macOS 按 10 倍扣除（约 200 分钟），建议公开
- 本地调试（有 Mac 时）：`brew install xcodegen && xcodegen generate` 后用 Xcode 打开 `Legado.xcodeproj`

## 目录结构

```
legado-ios/
├── project.yml                  # XcodeGen 工程定义（iOS 17.0，无签名配置）
├── Legado/
│   ├── LegadoApp.swift          # 入口
│   ├── ContentView.swift        # Tab：书架 / 书源 / 我的
│   ├── Models/BookSource.swift  # legado 书源 JSON 模型
│   ├── Engine/                  # 规则引擎（P0 核心）
│   │   ├── RuleEngine.swift     #   主流程：切分 → 模式识别 → 求值 → 回填
│   │   ├── RuleMode.swift       #   六种模式枚举
│   │   ├── RuleSplitter.swift   #   &&/||/%% 平衡组切分 + @put 提取
│   │   ├── JsonPath.swift       #   JSONPath 子集
│   │   ├── JsJavaBridge.swift   #   JavaScriptCore java.* 桥
│   │   └── RuleError.swift
│   ├── Services/                # 书源本地存储
│   ├── Views/                   # 书架 / 书源列表 / 导入 / 详情 / 测试台 / 我的
│   └── Assets.xcassets/         # App 图标
├── tools/make_icon.py           # 图标生成脚本
└── .github/workflows/build-ios.yml
```

## 路线图

| 阶段 | 内容 |
|---|---|
| P1 | SwiftSoup（CSS/XPath）+ URLSession 网络层 + cookie + 搜索→详情→目录→正文流水线 + SQLite |
| P2 | 阅读器分页（TextKit）+ 翻页动画 + 阅读配置/主题 + 本地 TXT/EPUB |
| P3 | WebDav 同步 + 备份恢复 + Web 服务 + URL scheme/分享导入 + RSS |
| P4 | TTS 朗读 + 音频歌词 + 视频弹幕/PiP + 漫画 |

## 许可证与免责

- 本工程为 GPL-3.0 衍生作品，源码必须保持公开，分发时保留署名
- 软件不提供任何内容；书源抓取的网络内容版权归权利人，请勿用于传播侵权资源
