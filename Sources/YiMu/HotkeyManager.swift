import AppKit

/// 全局/本地键盘监控，实现 ⌘⇧L（画框翻译）、⌘⇧T（暂停/恢复）、⌘⇧F（进入屏幕融合）。
/// 注：全局 monitor 需「辅助功能」授权才能捕获其他 App 的按键；未授权时仅在本 App 拥有焦点时生效。
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var localMonitor: Any?
    private var globalMonitor: Any?

    func start() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 本地监听：本 App 持有焦点时触发。命中的组合键直接吞掉（return nil），
            // 否则事件继续上抛，系统因无人接手会「哔」一声（按错键的提示音）。
            if self?.handle(event) == true { return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handle(event)   // 全局监听用于其它 App，无法吞事件，返回值忽略
        }
    }

    /// 处理按键；返回 true 表示已消费（调用方应吞掉事件以抑制系统提示音）。
    private func handle(_ event: NSEvent) -> Bool {
        // 状态栏菜单打开期间不处理：此时菜单项自身的 keyEquivalent 已接管同样的组合，
        // 监听再触发一次会双执行（暂停开→关、融合进→出互相抵消）。返回 false 让事件继续上抛。
        if AppDelegate.shared?.statusMenuOpen == true { return false }

        let hk = Preferences.shared.hotkeys

        if let lens = hk[Hotkey.Action.showLens], lens.matches(event) {
            AppDelegate.shared?.applyState(.lens)
            return true
        }

        if let pause = hk[Hotkey.Action.togglePause], pause.matches(event) {
            AppModel.shared.paused.toggle()
            AppDelegate.shared?.refreshStatusMenu()
            return true
        }

        // 2026-10-14 取消「切换」语义：融合快捷键只负责进入融合（退出靠退出融合快捷键）。
        if let fusion = hk[Hotkey.Action.toggleFusion], fusion.matches(event) {
            AppDelegate.shared?.applyState(.fusion)
            return true
        }

        // 退出融合/区域：完全隐藏到菜单栏（停止翻译、关窗），之后可经菜单重新唤醒。
        if let exit = hk[Hotkey.Action.exitFusion], exit.matches(event) {
            if AppModel.shared.state == .fusion || AppModel.shared.state == .region {
                AppDelegate.shared?.applyState(.off)
            }
            return true
        }

        return false
    }
}
