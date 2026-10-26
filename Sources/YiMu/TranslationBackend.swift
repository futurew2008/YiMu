import Foundation

/// 翻译后端（引擎）。
///
/// 设计原则（2026-10-14 用户拍板）：
/// - **`.apple` 是默认、设备端、零外发**，契合隐私红线，也是核心卖点。
/// - DeepL / Google / Microsoft 是**可选增强（opt-in）**：用户必须主动在设置页选择并填入
///   Keychain 中的 API key，原文才会发往第三方服务器。
/// - 切到非 Apple 引擎时，界面会明确给出「数据已外发」标识（见 AppDelegate 菜单栏云标识）。
enum TranslationBackend: String, Codable, CaseIterable, Identifiable {
    case apple
    case deepl
    case google
    case microsoft

    var id: String { rawValue }

    /// 是否为设备端、零外发的引擎。
    var isOnDevice: Bool { self == .apple }

    /// 是否会把原文发往第三方服务器（隐私红线下需显式 opt-in 并提示）。
    var sendsDataOffDevice: Bool { !isOnDevice }

    var displayName: String {
        switch self {
        case .apple:      return L10n.s("Apple 设备端（零外发）", "Apple On-Device (no data leaves)")
        case .deepl:      return "DeepL"
        case .google:     return "Google"
        case .microsoft:  return "Microsoft"
        }
    }

    /// Microsoft Translator（Azure）需要额外填写区域（如 eastasia）。
    var needsRegion: Bool { self == .microsoft }

    /// 非 Apple 引擎都需要 API key。
    var needsApiKey: Bool { self != .apple }

    /// 对应 Keychain 服务名（用于存/取该引擎的 API key，绝不落明文文件）。
    var keychainService: String { "com.weilai.yimu.translation.\(rawValue)" }

    /// 各家语言码映射：把译幕内部码（"en" / "zh-Hans" / "ja" …）转换成该服务商的码。
    /// 内部码与 `Translator.supportedCode` 的 value 一致。
    func remoteLanguageCode(_ internalCode: String) -> String {
        switch self {
        case .apple:
            return internalCode
        case .deepl:
            // DeepL 用全大写；简/繁统一为 ZH（DeepL 不区分繁简）。
            if internalCode == "zh-Hans" || internalCode == "zh-Hant" { return "ZH" }
            return internalCode.uppercased()
        case .google:
            // Google：简中 zh-CN、繁中 zh-TW，其余小写。
            if internalCode == "zh-Hans" { return "zh-CN" }
            if internalCode == "zh-Hant" { return "zh-TW" }
            return internalCode.lowercased()
        case .microsoft:
            // 微软用 BCP-47，与内部码基本一致。
            return internalCode
        }
    }
}
