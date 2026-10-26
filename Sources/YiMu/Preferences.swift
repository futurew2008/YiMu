import Foundation
import AppKit

/// 全局用户偏好：UI 语言、排除的应用、自定义快捷键、是否已完成引导。
/// 全部落盘 UserDefaults，跨会话保留。属性只在主线程改动（设置 UI / 热键录制），与 AppModel 同模式。
final class Preferences: ObservableObject {
    static let shared = Preferences()

    // MARK: - 可观察属性

    /// 界面语言："zh" / "en"。
    @Published var uiLanguage: String {
        didSet { UserDefaults.standard.set(uiLanguage, forKey: Key.uiLanguage) }
    }

    /// 已完成首次引导。
    @Published var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Key.onboarded) }
    }

    /// 已见过融合态角落 HUD（首次进入时自动提示一次）。
    @Published var hasSeenFusionHUD: Bool {
        didSet { UserDefaults.standard.set(hasSeenFusionHUD, forKey: Key.seenFusionHUD) }
    }

    /// 已见过首次进入融合态的交互引导卡（一次性）。
    @Published var hasSeenFusionTip: Bool {
        didSet { UserDefaults.standard.set(hasSeenFusionTip, forKey: Key.seenFusionTip) }
    }

    /// 已看过设置页「按住 Shift 看原文」一次性提示（关闭后永不再弹）。
    @Published var gestureTipSeen: Bool {
        didSet { UserDefaults.standard.set(gestureTipSeen, forKey: Key.gestureTipSeen) }
    }

    /// 排除（永不翻译）的应用 bundle ID 列表。
    @Published var excludedBundleIDs: [String] {
        didSet { persist(Array(Set(excludedBundleIDs)).sorted(), key: Key.excluded) }
    }

    /// 源语言 code（nil = 自动识别）。**必须持久化**：否则每次启动都被重置成默认，
    /// 用户设的「日→中」一重启就没了，还会立刻用错误的语言方向去翻译并写进缓存。
    var savedSourceLanguage: String? {
        get { UserDefaults.standard.string(forKey: Key.sourceLanguage) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: Key.sourceLanguage) }
            else { UserDefaults.standard.removeObject(forKey: Key.sourceLanguage) }
        }
    }

    /// 目标语言 code（默认 zh-Hans）。同上，必须持久化。
    var savedTargetLanguage: String {
        get { UserDefaults.standard.string(forKey: Key.targetLanguage) ?? "zh-Hans" }
        set { UserDefaults.standard.set(newValue, forKey: Key.targetLanguage) }
    }

    /// 自定义快捷键：动作名 → 按键组合。
    @Published var hotkeys: [String: Hotkey] {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeys) { persist(data, key: Key.hotkeys) }
        }
    }

    // MARK: - 翻译引擎（2026-10-14 新增：可选云端引擎，默认 Apple 设备端）

    /// 当前翻译后端。默认 `.apple`（设备端、零外发）。
    /// 用 `@Published` 的 `backendRaw` 做后备，保证设置页切换时 SwiftUI 即时刷新。
    @Published private var backendRaw: String =
        UserDefaults.standard.string(forKey: Key.backend) ?? TranslationBackend.apple.rawValue
    var translationBackend: TranslationBackend {
        get { TranslationBackend(rawValue: backendRaw) ?? .apple }
        set { backendRaw = newValue.rawValue }
    }

    /// Microsoft Translator（Azure）区域，如 "eastasia"。
    @Published var microsoftRegion: String {
        didSet { persist(microsoftRegion, key: Key.microsoftRegion) }
    }

    /// 是否使用 DeepL Pro 端点（默认免费端点 api-free.deepl.com）。
    @Published var deeplPro: Bool {
        didSet { UserDefaults.standard.set(deeplPro, forKey: Key.deeplPro) }
    }

    // MARK: - 便捷计算

    var isEnglish: Bool { uiLanguage == "en" }

    // MARK: - 初始化

    private init() {
        let d = UserDefaults.standard
        self.uiLanguage = d.string(forKey: Key.uiLanguage) ?? "zh"
        self.hasOnboarded = d.bool(forKey: Key.onboarded)
        self.hasSeenFusionHUD = d.bool(forKey: Key.seenFusionHUD)
        self.hasSeenFusionTip = d.bool(forKey: Key.seenFusionTip)
        self.gestureTipSeen = d.bool(forKey: Key.gestureTipSeen)
        if let data = d.data(forKey: Key.excluded),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.excludedBundleIDs = arr
        } else {
            self.excludedBundleIDs = []
        }
        if let data = d.data(forKey: Key.hotkeys),
           let hk = try? JSONDecoder().decode([String: Hotkey].self, from: data) {
            var fixed = hk
            // 一次性迁移：老版本存下来的「裸 Esc 退出融合」升级为 ⌘⇧Esc。
            // 裸键无法被全局 monitor 拦截，用户在任何 app 里按 Esc 都会被静默踢出融合态。
            // 只针对这一个已知有害的组合，不碰用户自定义的其它绑定。
            if let old = fixed[Hotkey.Action.exitFusion], old.keyCode == 53, old.flagsRaw == 0 {
                fixed[Hotkey.Action.exitFusion] = Hotkey.defaultExitFusion
            }
            // 2026-10-14 新增「画框翻译」独立快捷键：老用户存档里没有这个动作，补默认值。
            if fixed[Hotkey.Action.showLens] == nil {
                fixed[Hotkey.Action.showLens] = Hotkey.defaultShowLens
            }
            self.hotkeys = fixed
        } else {
            self.hotkeys = Hotkey.defaults
        }
        self.microsoftRegion = d.string(forKey: Key.microsoftRegion) ?? ""
        self.deeplPro = d.bool(forKey: Key.deeplPro)
    }

    /// 恢复默认快捷键。
    func resetHotkeys() { hotkeys = Hotkey.defaults }

    /// 是否应翻译给定 bundle ID 的前台 App（排除列表内则返回 false）。
    func shouldTranslate(_ bundleID: String?) -> Bool {
        guard let id = bundleID, !id.isEmpty else { return true }
        return !excludedBundleIDs.contains(id)
    }

    // MARK: - 内部

    private func persist(_ value: Any?, key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private enum Key {
        static let uiLanguage = "yi.uiLanguage"
        static let onboarded  = "yi.hasOnboarded"
        static let seenFusionHUD = "yi.hasSeenFusionHUD"
        static let seenFusionTip = "yi.hasSeenFusionTip"
        static let gestureTipSeen = "yi.gestureTipSeen"
        static let excluded   = "yi.excludedBundleIDs"
        static let hotkeys    = "yi.hotkeys"
        static let sourceLanguage = "yi.sourceLanguage"
        static let targetLanguage = "yi.targetLanguage"
        static let backend         = "yi.translationBackend"
        static let microsoftRegion = "yi.microsoftRegion"
        static let deeplPro        = "yi.deeplPro"
    }
}

/// 一个快捷键组合：按键码 + 修饰键位（原始值，便于 Codable）。
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var flagsRaw: UInt

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flagsRaw) }

    /// 人类可读的组合，如 "⌘⇧T"。
    var display: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.command)  { s += "⌘" }
        if f.contains(.shift)    { s += "⇧" }
        if f.contains(.option)   { s += "⌥" }
        if f.contains(.control)  { s += "⌃" }
        s += Hotkey.keyGlyph(code: keyCode)
        return s
    }

    /// 是否匹配一次按键事件（仅比较 command/shift/option/control 四位）。
    func matches(_ event: NSEvent) -> Bool {
        let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        return event.modifierFlags.intersection(mask) == modifierFlags.intersection(mask)
            && event.keyCode == keyCode
    }

    // MARK: - 默认组合

    static let cmdShift = NSEvent.ModifierFlags([.command, .shift]).rawValue

    static let defaultTogglePause = Hotkey(keyCode: 17, flagsRaw: cmdShift) // T
    static let defaultShowLens = Hotkey(keyCode: 37, flagsRaw: cmdShift)    // L（Lens）
    static let defaultToggleFusion = Hotkey(keyCode: 3, flagsRaw: cmdShift) // F
    /// 退出融合：**必须带修饰键**。
    /// 旧默认是无修饰键的裸 Esc —— 全局 monitor 拦不住事件，于是用户在别的 app 里
    /// 关 Spotlight、取消保存对话框、退出视频全屏、关通知……**每一次按 Esc 都会把译幕
    /// 静默踢出融合态**。改为 ⌘⇧Esc，与另外两个动作同族，不可能误触。
    static let defaultExitFusion = Hotkey(keyCode: 53, flagsRaw: cmdShift)  // ⌘⇧Esc

    static let defaults: [String: Hotkey] = [
        Action.showLens:      defaultShowLens,
        Action.togglePause:   defaultTogglePause,
        Action.toggleFusion:  defaultToggleFusion,
        Action.exitFusion:    defaultExitFusion,
    ]

    /// 快捷键动作名。
    enum Action {
        static let showLens     = "showLens"
        static let togglePause  = "togglePause"
        static let toggleFusion = "toggleFusion"
        static let exitFusion   = "exitFusion"
    }

    /// 动作的中文/英文标签。
    static func actionTitle(_ action: String, english: Bool) -> String {
        switch action {
        case Action.showLens:     return english ? "Frame translation" : "画框翻译"
        case Action.togglePause:  return english ? "Pause / Resume Translation" : "暂停/恢复 翻译"
        case Action.toggleFusion: return english ? "Fusion"         : "屏幕融合"
        case Action.exitFusion:   return english ? "Exit Fusion"    : "退出屏幕融合"
        default:                  return action
        }
    }

    // MARK: - 按键名

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "5", 23: "6", 24: "7", 25: "8", 26: "9", 27: "0",
        31: "O", 32: "U", 33: "8?", 34: "I", 35: "P", 37: "L", 38: "J", 39: "K",
        40: ";", 41: "'", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        49: "Space", 51: "Backspace", 53: "Esc", 36: "Return", 48: "Tab",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    static func keyGlyph(code: UInt16) -> String {
        if let n = keyNames[code] { return n }
        return "·\(code)"
    }
}

/// 轻量双语 helper：L10n.s("中文", "English")。
enum L10n {
    static func s(_ zh: String, _ en: String) -> String {
        Preferences.shared.uiLanguage == "en" ? en : zh
    }
}
