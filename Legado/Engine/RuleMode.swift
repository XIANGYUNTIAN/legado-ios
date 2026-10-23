import Foundation

/// 规则模式（对应 AnalyzeRule.Mode）
enum RuleMode {
    case json       // JSONPath
    case regex      // 正则（含 ## 替换）
    case js         // <js> / @js:
    case css        // Jsoup CSS 选择器（P1）
    case xpath      // XPath（P1）
    case webJs      // 后台 WebView（P1）
    case plain      // 默认 / 纯字面量
}

struct RuleSegment {
    let mode: RuleMode
    let text: String
}
