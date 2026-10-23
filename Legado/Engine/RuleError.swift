import Foundation

enum RuleError: LocalizedError {
    case invalidJSON
    case emptyResult
    case unsupportedMode(String)
    case jsError(String)
    case regexError(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "不是合法的书源 JSON"
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
