import AppKit
import CoreGraphics

/// 融合态角落 HUD：鼠标靠近才浮现，提供「暂停 / 恢复」与「退出融合」。
///
/// 为什么需要它：融合窗口是完全透明且 `ignoresMouseEvents = true` 的（必须穿透），
/// 因此它本身收不到任何点击；HUD 用**独立的小窗口**承载，只在可见时启用交互，
/// 隐藏时 `alphaValue = 0` 且重新穿透，绝不挡住下层 app 的操作。
final class FusionHUD {
    static let shared = FusionHUD()

    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private var hideTimer: Timer?
    private var hintTimer: Timer?
    private var visible = false
    /// 临近检测的节流时间戳：mouseMoved 以 60~120Hz 刷屏，每帧都算命中测试毫无必要，
    /// 限到 ~30Hz 足够（C 方案，降低主线程无用开销）。
    private var lastProxEval: CFTimeInterval = 0

    /// HUD 窗口号（供 OCR 排除，避免把自己的按钮再识别一遍）。
    var windowIDs: [CGWindowID] { windows.map { CGWindowID($0.windowNumber) } }

    // MARK: - 生命周期

    func install(screens: [NSScreen]) {
        teardown()
        for screen in screens {
            let win = makeWindow(screen: screen)
            windows.append(win)
        }
        startProximityTracking()

        // 首次进入融合态：自动浮现一次并停留 4.5 秒，让用户知道有这个出口。
        if !Preferences.shared.hasSeenFusionHUD {
            Preferences.shared.hasSeenFusionHUD = true
            setVisible(true)
            hintTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
                self?.hintTimer = nil
                self?.setVisible(false)
            }
        }
    }

    func teardown() {
        hideTimer?.invalidate(); hideTimer = nil
        hintTimer?.invalidate(); hintTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for w in windows { w.close() }
        windows.removeAll()
        visible = false
    }

    // MARK: - 窗口

    private func makeWindow(screen: NSScreen) -> NSWindow {
        let size = NSSize(width: 84, height: 36)
        let margin: CGFloat = 18
        let origin = NSPoint(x: screen.frame.maxX - size.width - margin,
                             y: screen.frame.minY + margin)
        let win = NSWindow(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.isReleasedWhenClosed = false   // ARC：防止 close() 过度释放（闪退根因）
        // 比融合覆盖窗口再高一层，确保浮在最上
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true       // 隐藏时完全穿透
        win.alphaValue = 0

        let hud = HUDView()
        hud.onPause = {
            AppModel.shared.paused.toggle()
            AppDelegate.shared?.refreshStatusMenu()
        }
        hud.onExit = { AppDelegate.shared?.applyState(.off) }
        win.contentView = hud
        win.orderFront(nil)
        return win
    }

    // MARK: - 接近检测

    private func startProximityTracking() {
        let handle: (NSEvent) -> Void = { [weak self] _ in self?.evaluateProximity() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handle) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { ev in
            handle(ev)
            return ev
        }) {
            monitors.append(m)
        }
    }

    private func evaluateProximity() {
        let now = CACurrentMediaTime()
        guard now - lastProxEval > 0.033 else { return }   // ~30Hz 上限
        lastProxEval = now
        let p = NSEvent.mouseLocation
        let near = windows.contains { $0.frame.insetBy(dx: -120, dy: -120).contains(p) }
        if near { show() } else { scheduleHide() }
    }

    private func show() {
        hideTimer?.invalidate(); hideTimer = nil
        setVisible(true)
    }

    private func scheduleHide() {
        guard visible, hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.hideTimer = nil
            self?.setVisible(false)
        }
    }

    private func setVisible(_ v: Bool) {
        guard visible != v else { return }
        visible = v
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for w in windows {
            w.ignoresMouseEvents = !v
            if v { (w.contentView as? HUDView)?.refresh() }
            if reduce {
                w.alphaValue = v ? 1 : 0
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    w.animator().alphaValue = v ? 1 : 0
                }
            }
        }
    }

    /// 外部（菜单栏 / 热键）切换暂停后同步 HUD 图标。
    /// 旧实现只在 HUD **浮现**那一刻才刷图标（setVisible 里），于是用 ⌘⇧T 或从菜单栏
    /// 暂停之后，HUD 上仍显示旧图标，点一下执行的恰好是相反的动作。
    func refresh() {
        for w in windows { (w.contentView as? HUDView)?.refresh() }
    }
}

// MARK: - HUD 内容

/// 一枚胶囊：内含「暂停/恢复」与「退出融合」两个圆形按钮。
private final class HUDView: NSVisualEffectView {
    var onPause: (() -> Void)?
    var onExit: (() -> Void)?

    private let pauseButton = NSButton()
    private let exitButton = NSButton()

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 84, height: 36))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        configure(pauseButton, symbol: "pause.fill", tip: "暂停 / 恢复")
        configure(exitButton, symbol: "xmark", tip: "退出屏幕融合")
        pauseButton.frame = NSRect(x: 12, y: 6, width: 24, height: 24)
        exitButton.frame = NSRect(x: 48, y: 6, width: 24, height: 24)
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        exitButton.target = self
        exitButton.action = #selector(exitTapped)
        addSubview(pauseButton)
        addSubview(exitButton)
    }

    private func configure(_ b: NSButton, symbol: String, tip: String) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
    }

    /// 每次浮现时同步图标（暂停中显示播放符号）。
    func refresh() {
        let paused = AppModel.shared.paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: "暂停 / 恢复")
    }

    @objc private func pauseTapped() {
        onPause?()
        refresh()
    }

    @objc private func exitTapped() { onExit?() }
}
