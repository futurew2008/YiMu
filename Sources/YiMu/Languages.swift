import Foundation

/// 一个可选翻译语言：displayName 中文显示，locale 为对应的 Locale.Language（nil = 自动识别）。
struct LanguageOption: Identifiable, Hashable {
    let id: String                 // 规范化 code，如 "en" / "zh-Hans"；自动识别用 "auto"
    let displayName: String        // 中文显示名
    let locale: Locale.Language?   // nil 表示「自动识别」源语言

    static let auto = LanguageOption(id: "auto", displayName: "自动识别", locale: nil)

    /// 源语言候选：自动识别 + 全部目标语言。
    static let allSource: [LanguageOption] = {
        var list = [auto]
        list += targetOptions
        return list
    }()

    /// 目标语言候选：Apple 离线翻译支持的语言（约 20 种，随系统更新自动变多）。
    static let targetOptions: [LanguageOption] = [
        .init(id: "zh-Hans", displayName: "简体中文", locale: .init(identifier: "zh-Hans")),
        .init(id: "zh-Hant", displayName: "繁體中文", locale: .init(identifier: "zh-Hant")),
        .init(id: "en",     displayName: "英语",     locale: .init(identifier: "en")),
        .init(id: "ja",     displayName: "日语",     locale: .init(identifier: "ja")),
        .init(id: "ko",     displayName: "韩语",     locale: .init(identifier: "ko")),
        .init(id: "fr",     displayName: "法语",     locale: .init(identifier: "fr")),
        .init(id: "de",     displayName: "德语",     locale: .init(identifier: "de")),
        .init(id: "it",     displayName: "意大利语", locale: .init(identifier: "it")),
        .init(id: "es",     displayName: "西班牙语", locale: .init(identifier: "es")),
        .init(id: "pt-BR",  displayName: "葡萄牙语", locale: .init(identifier: "pt-BR")),
        .init(id: "ru",     displayName: "俄语",     locale: .init(identifier: "ru")),
        .init(id: "ar",     displayName: "阿拉伯语", locale: .init(identifier: "ar")),
        .init(id: "id",     displayName: "印尼语",   locale: .init(identifier: "id")),
        .init(id: "nl",     displayName: "荷兰语",   locale: .init(identifier: "nl")),
        .init(id: "pl",     displayName: "波兰语",   locale: .init(identifier: "pl")),
        .init(id: "th",     displayName: "泰语",     locale: .init(identifier: "th")),
        .init(id: "tr",     displayName: "土耳其语", locale: .init(identifier: "tr")),
        .init(id: "uk",     displayName: "乌克兰语", locale: .init(identifier: "uk")),
        .init(id: "vi",     displayName: "越南语",   locale: .init(identifier: "vi")),
        .init(id: "hi",     displayName: "印地语",   locale: .init(identifier: "hi")),
    ]

    /// 按 code 找源语言选项（nil / "auto" 指向自动识别）。
    static func sourceOption(forCode code: String?) -> LanguageOption {
        guard let code, code != "auto" else { return .auto }
        return allSource.first { $0.id == code } ?? .auto
    }

    /// 按 code 找目标语言选项，找不到回退简体中文。
    static func targetOption(forCode code: String) -> LanguageOption {
        targetOptions.first { $0.id == code } ?? targetOptions[0]
    }
}
