import Foundation

enum RuleError: LocalizedError {
    /// 带详细原因的导入失败（优先于笼统提示，便于用户定位问题）
    case invalidSource(String)
    case emptyResult
    /// 规则解析失败（带具体原因，如「CSS 选择器未匹配到元素」）
    case ruleFailed(String)
    case unsupportedMode(String)
    case jsError(String)
    case regexError(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let detail):
            return detail.isEmpty ? "不是合法的书源 JSON" : detail
        case .emptyResult:
            return "规则求值为空"
        case .ruleFailed(let reason):
            return reason
        case .unsupportedMode(let mode):
            return "\(mode) 模式暂不支持"
        case .jsError(let message):
            return "JS 执行错误：\(message)"
        case .regexError(let pattern):
            return "正则表达式错误：\(pattern)"
        }
    }
}
