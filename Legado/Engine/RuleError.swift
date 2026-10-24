import Foundation

enum RuleError: LocalizedError {
    /// 带详细原因的导入失败（优先于笼统提示，便于用户定位问题）
    case invalidSource(String)
    case emptyResult
    case unsupportedMode(String)
    case jsError(String)
    case regexError(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let detail):
            return detail.isEmpty ? "不是合法的书源 JSON" : detail
        case .emptyResult:
            return "规则求值为空"
        case .unsupportedMode(let mode):
            return "\(mode) 模式尚未支持（P1 集成 HTML 解析后开放）"
        case .jsError(let message):
            return "JS 执行错误：\(message)"
        case .regexError(let pattern):
            return "正则表达式错误：\(pattern)"
        }
    }
}
