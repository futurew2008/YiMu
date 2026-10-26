import AppKit
import SwiftUI
import Combine

/// 快捷键录制器：点"录制"后捕获下一次按键，回调组合。用于设置页自定义全局快捷键。
@MainActor
final class HotkeyRecorder: ObservableObject {
    /// 当前正在录制的动作名（nil = 空闲）。
    @Published var recordingAction: String? = nil
    private var monitor: Any?

    /// 开始录制某个动作的下一次按键。
    func begin(action: String, completion: @escaping (Hotkey) -> Void) {
        end()
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.end()
            let mask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let flags = event.modifierFlags.intersection(mask)
            let hk = Hotkey(keyCode: event.keyCode, flagsRaw: flags.rawValue)
            completion(hk)
            return nil   // 吞掉该按键，避免触发其他响应
        }
    }

    func end() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recordingAction = nil
    }
}
