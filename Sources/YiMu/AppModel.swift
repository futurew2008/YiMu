import SwiftUI
import Combine
import Foundation

/// 状态机：设置（毛玻璃）/ 镜头（透明，只罩窗口区域）/ 融合（全屏覆盖）/ 区域（框选矩形）/ 隐藏（仅菜单栏）。
enum AppState: String {
    case settings
    case lens
    case fusion
    case region
    case off
}

/// 全局可观察模型，驱动 SwiftUI 内容与菜单栏/热键联动。
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var state: AppState = .settings
    /// 源语言 code：nil = 自动识别；否则对应 LanguageOption.id。
    /// 落盘 UserDefaults（2026-10-13）：旧版只存在内存里，重启就被重置回「自动识别」，
    /// 用户设的语言方向每次开机都要重设。
    @Published var sourceLanguageCode: String? = Preferences.shared.savedSourceLanguage {
        didSet { Preferences.shared.savedSourceLanguage = sourceLanguageCode }
    }
    /// 目标语言 code（对应 LanguageOption.id）。同样落盘。
    @Published var targetLanguageCode: String = Preferences.shared.savedTargetLanguage {
        didSet { Preferences.shared.savedTargetLanguage = targetLanguageCode }
    }
    @Published var paused: Bool = false
    /// 是否处于「按住 Control 悬停翻译」状态（隐藏常规译文块、只显示指针处译文）。
    @Published var hovering: Bool = false

    /// 源语言 Locale（自动识别为 nil）。
    var sourceLocale: Locale.Language? {
        LanguageOption.sourceOption(forCode: sourceLanguageCode).locale
    }
    /// 目标语言 Locale。
    var targetLocale: Locale.Language {
        LanguageOption.targetOption(forCode: targetLanguageCode).locale ?? .init(identifier: "zh-Hans")
    }
}
