import AppKit

/// 「按住 Shift 偷看原文」控制器。
///
/// 按住 Shift 键时，光标所指的译文块临时隐藏，露出底下原界面文字；
/// 松开 Shift 恢复翻译显示。按住期间实时跟踪鼠标，使露出区域随指针移动。
///
/// - Shift 键状态由 `.flagsChanged` 事件捕获（本地 + 全局，需辅助功能授权）；
/// - 按住期间用 `.mouseMoved` 事件实时更新光标位置（同样本地 + 全局）。
final class PeekManager {
    static let shared = PeekManager()

    private(set) var isActive = false

    private var flagMonitors: [Any] = []
    private var mouseLocal: Any?
    private var mouseGlobal: Any?

    func start() {
        let localF = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            self?.handleFlags(ev)
            return ev
        }
        let globalF = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            self?.handleFlags(ev)
        }
        if let localF { flagMonitors.append(localF) }
        if let globalF { flagMonitors.append(globalF) }
    }

    // MARK: - Shift 键

    private func handleFlags(_ ev: NSEvent) {
        let down = ev.modifierFlags.contains(.shift)
        setShiftDown(down)
    }

    private func setShiftDown(_ down: Bool) {
        guard down != isActive else { return }
        isActive = down
        if isActive {
            startMouseTracking()
            AppDelegate.shared?.applyPeek(active: true, point: NSEvent.mouseLocation)
        } else {
            stopMouseTracking()
            AppDelegate.shared?.applyPeek(active: false, point: .zero)
        }
    }

    // MARK: - 鼠标跟踪（仅按住 Shift 期间）

    private func startMouseTracking() {
        mouseLocal = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            self?.refreshPoint()
            return ev
        }
        mouseGlobal = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.refreshPoint()
        }
    }

    private func stopMouseTracking() {
        if let m = mouseLocal { NSEvent.removeMonitor(m) }
        if let m = mouseGlobal { NSEvent.removeMonitor(m) }
        mouseLocal = nil
        mouseGlobal = nil
    }

    private func refreshPoint() {
        guard isActive else { return }
        AppDelegate.shared?.applyPeek(active: true, point: NSEvent.mouseLocation)
    }
}
