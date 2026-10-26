import Foundation

/// 云端翻译封装：DeepL / Google / Microsoft 三家 REST 批量翻译。
///
/// 设计边界：
/// - 只在 `TranslationBackend != .apple` 时由 `Translator` 调用；Apple 设备端路径不碰网络。
/// - 三家返回结果**保持输入顺序**，因此 `Translator` 可按下标配对回填。
/// - 内部码 → 各家码的转换在 `TranslationBackend.remoteLanguageCode` 里完成，本文件只收各家码。
/// - API key 来自 Keychain（`KeychainHelper`），本文件不负责存储。
enum CloudTranslator {
    enum CloudError: Error {
        case keyMissing
        case badStatus(Int)
        case malformed
    }

    /// 批量翻译。
    /// - Parameters:
    ///   - texts: 同批文本（目标语言一致）。
    ///   - sourceCode: 内部源语言码（可为 nil → 让云端自动检测）；会经 `backend` 映射成各家码。
    ///   - targetCode: 内部目标语言码。
    ///   - region: Microsoft 必填区域，其它引擎忽略。
    static func translate(_ texts: [String],
                          from sourceCode: String?,
                          to targetCode: String,
                          backend: TranslationBackend,
                          apiKey: String,
                          region: String = "") async throws -> [String] {
        let from = sourceCode.map { backend.remoteLanguageCode($0) }
        let to = backend.remoteLanguageCode(targetCode)
        switch backend {
        case .apple:
            throw CloudError.malformed
        case .deepl:
            return try await deepl(texts, from: from, to: to, apiKey: apiKey, pro: Preferences.shared.deeplPro)
        case .google:
            return try await google(texts, from: from, to: to, apiKey: apiKey)
        case .microsoft:
            return try await microsoft(texts, from: from, to: to, apiKey: apiKey, region: region)
        }
    }

    // MARK: - DeepL

    private static func deepl(_ texts: [String], from: String?, to: String, apiKey: String, pro: Bool) async throws -> [String] {
        guard !apiKey.isEmpty else { throw CloudError.keyMissing }
        let base = pro ? "https://api.deepl.com/v2/translate" : "https://api-free.deepl.com/v2/translate"
        var parts: [String] = []
        parts.append("auth_key=" + encode(apiKey))
        for t in texts { parts.append("text=" + encode(t)) }
        if let from { parts.append("source_lang=" + encode(from)) }
        parts.append("target_lang=" + encode(to))
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = parts.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["translations"] as? [[String: Any]] else { throw CloudError.malformed }
        return arr.map { ($0["text"] as? String) ?? "" }
    }

    // MARK: - Google

    private static func google(_ texts: [String], from: String?, to: String, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw CloudError.keyMissing }
        var comps = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["q": texts, "target": to, "format": "text"]
        if let from { payload["source"] = from }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let arr = dataObj["translations"] as? [[String: Any]] else { throw CloudError.malformed }
        return arr.map { unescapeHTML(($0["translatedText"] as? String) ?? "") }
    }

    // MARK: - Microsoft (Azure Translator)

    private static func microsoft(_ texts: [String], from: String?, to: String, apiKey: String, region: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw CloudError.keyMissing }
        var comps = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: to),
        ]
        if let from { items.append(URLQueryItem(name: "from", value: from)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: texts.map { ["Text": $0] })
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw CloudError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CloudError.malformed }
        return arr.map { entry in
            guard let translations = entry["translations"] as? [[String: Any]],
                  let first = translations.first,
                  let text = first["text"] as? String else { return "" }
            return text
        }
    }

    // MARK: - 工具

    /// 表单/URL 安全编码。
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Google 的 `translatedText` 带 HTML 实体（如 `&#39;` `&amp;` `&quot;`），需反转义。
    private static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named: [String: String] = ["&amp;": "&", "&lt;": "<", "&gt;": ">",
                                       "&quot;": "\"", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // 数字实体 &#NN; / &#xHH;
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                let body = ns.substring(with: m.range(at: 1))
                var code: UInt32?
                if body.hasPrefix("x") || body.hasPrefix("X") {
                    code = UInt32(body.dropFirst(), radix: 16)
                } else {
                    code = UInt32(body, radix: 10)
                }
                if let code, let scalar = UnicodeScalar(code),
                   let r = Range(m.range, in: out) {
                    out.replaceSubrange(r, with: String(scalar))
                }
            }
        }
        return out
    }
}
