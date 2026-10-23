import Foundation
import CommonCrypto

/// 注入 JavaScriptCore 的 `java.*` 桥对象（对应 help/JsEncodeUtils 的常用函数）。
/// 在 JS 中以 `java.base64Encode("...")` 形式调用。
@objc final class JsJavaBridge: NSObject {

    @objc func log(_ message: String) {
        print("[rule-js] \(message)")
    }

    @objc func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    @objc func base64Decode(_ text: String) -> String {
        guard let data = Data(base64Encoded: text) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @objc func hexEncode(_ text: String) -> String {
        Data(text.utf8).map { String(format: "%02x", $0) }.joined()
    }

    @objc func hexDecode(_ text: String) -> String {
        let characters = Array(text)
        var bytes = [UInt8]()
        var index = 0
        while index + 1 < characters.count {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return ""
            }
            bytes.append(byte)
            index += 2
        }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    @objc func md5Encode(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            CC_MD5(raw.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
