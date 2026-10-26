import AppKit

/// 框选控制器：弹出一个覆盖主屏的透明层，让用户拖拽画出矩形；松手后将全局矩形回调出去。
/// 用于「区域翻译」模式——只在你框选的那一块里取字/翻译（像阅读放大镜）。
final class RegionSelectionController {
    static let shared = RegionSelectionController()
    var onSelected: ((NSRect) -> Void)?
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
        win.isReleasedWhenClosed = false   // ARC：防止 close() 过度释放（闪退根因）
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = false
        let view = RegionSelectionView()
        view.onRect = { [weak self] rect in
            self?.finish(rect)
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    private func finish(_ rect: NSRect) {
        window?.close()
        window = nil
        onSelected?(rect)
    }

    /// 关闭选框（切换模式时调用，避免残留）。
    func cancel() {
        window?.close()
        window = nil
    }
}

/// 拖拽选框视图：蓝边半透明矩形随鼠标绘制；松手回传全局矩形（窗口=主屏，故本地坐标即全局）。
final class RegionSelectionView: NSView {
    var onRect: ((NSRect) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?
    private let feedback = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        feedback.wantsLayer = true
        feedback.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        feedback.layer?.borderWidth = 2
        feedback.layer?.borderColor = NSColor.systemBlue.cgColor
        feedback.isHidden = true
        addSubview(feedback)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, to: nil)
        current = start
        feedback.isHidden = false
        updateFeedback()
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, to: nil)
        updateFeedback()
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = start, let c = current else { return }
        let rect = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                          width: abs(c.x - s.x), height: abs(c.y - s.y))
        start = nil; current = nil
        if rect.width > 10 && rect.height > 10 {
            onRect?(rect)
        } else {
            feedback.isHidden = true   // 太小，视为误点
        }
    }

    private func updateFeedback() {
        guard let s = start, let c = current else { return }
        feedback.frame = NSRect(x: min(s.x, c.x), y: min(s.y, c.y),
                               width: abs(c.x - s.x), height: abs(c.y - s.y))
    }
}
