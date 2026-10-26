import AppKit
import ApplicationServices

/// 点选窗口排除 app：弹出一个全屏透明层，光标移动时高亮其下方的窗口，
/// 点击即把该窗口所属 app 的 bundleID 加入「不翻译」列表（排除的是整个 app，
/// 而非该窗口所在的那块屏幕区域）。交互灵感取自「框选截屏」，但语义是「排除 app」。
final class AppPickerController {
    static let shared = AppPickerController()
    var onPicked: ((String) -> Void)?
    private var window: NSWindow?

    func begin() {
        guard let screen = NSScreen.main else { return }
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.isReleasedWhenClosed = false   // ARC：防止 close() 过度释放
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 3)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false
        let view = AppPickerView()
        view.onPick = { [weak self] bundleID in
            self?.finish(bundleID)
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    private func finish(_ bundleID: String?) {
        window?.close()
        window = nil
        if let id = bundleID, !id.isEmpty { onPicked?(id) }
    }

    /// 关闭选窗（切换模式时调用，避免残留）。
    func cancel() {
        window?.close()
        window = nil
    }
}

/// 全屏取窗视图：移动高亮、点击取 bundleID。
final class AppPickerView: NSView {
    var onPick: ((String?) -> Void)?
    private let feedback = NSView()
    private let hint = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        feedback.wantsLayer = true
        feedback.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.16).cgColor
        feedback.layer?.borderWidth = 2
        feedback.layer?.borderColor = NSColor.systemOrange.cgColor
        feedback.layer?.cornerRadius = 8
        feedback.isHidden = true
        addSubview(feedback)

        hint.stringValue = L10n.s("点击要排除的窗口（其所属 App 将不再被翻译）· Esc 取消",
                                  "Click a window to exclude its app · Esc to cancel")
        hint.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .labelColor
        hint.drawsBackground = false
        hint.isBordered = false
        hint.sizeToFit()
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        hint.layer?.cornerRadius = 6
        hint.isHidden = true
        addSubview(hint)

        let opts = NSTrackingArea.Options([.mouseMoved, .activeAlways, .inVisibleRect])
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window {
            hint.isHidden = false
            hint.frame = NSRect(x: 12, y: w.frame.height - 40, width: hint.frame.width + 16, height: hint.frame.height + 8)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, to: nil)
        if let (rect, _) = windowInfo(at: p) {
            feedback.frame = rect
            feedback.isHidden = false
        } else {
            feedback.isHidden = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, to: nil)
        let bid = windowInfo(at: p)?.1
        onPick?(bid)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onPick?(nil) }   // Esc 取消
    }

    /// 返回光标处最上层（非自身）窗口的屏幕矩形（AppKit 坐标）与其所属 app 的 bundleID。
    private func windowInfo(at p: NSPoint) -> (NSRect, String?)? {
        let selfBundle = Bundle.main.bundleIdentifier
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        for info in list.reversed() {
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { continue }
            // CG 坐标 Y 原点在左上 → 转 AppKit（原点左下）
            let rect = NSRect(x: x, y: primaryH - y - h, width: w, height: h)
            if rect.contains(p) {
                let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
                guard pid != selfPid else { continue }
                let bid = NSWorkspace.shared.runningApplications
                    .first { $0.processIdentifier == pid }?.bundleIdentifier
                if bid == selfBundle { continue }
                return (rect, bid)
            }
        }
        return nil
    }
}
