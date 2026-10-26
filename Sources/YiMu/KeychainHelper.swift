import Foundation
import Security

/// 极简 Keychain 封装：仅用于安全保存各翻译引擎的 API key。
///
/// 隐私红线要求：密钥**绝不**以明文落盘到文件、绝不进 git/仓库。
/// 这里走 macOS Keychain（钥匙串），由系统加密存储，且只在用户本机可用。
enum KeychainHelper {
    /// 写入（或删除，当 value 为空时）。覆盖式：先删后写。
    static func set(_ value: String, forService service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)

        guard !value.isEmpty else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// 读取。取不到返回 nil。
    static func get(_ service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
