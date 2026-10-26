import AppKit
import SwiftUI
import Combine
import CoreGraphics
import Vision
import CoreImage

// CGWindowListCreateImage 在 macOS 15+ 的 Swift overlay 中被标记 unavailable
// （提示改用 ScreenCaptureKit），但底层 C API 仍可用。指译 OCR 兜底需要它「只截
// 译幕主覆盖窗口之下」的内容，以排除自己的译文块、避免把译文再翻一遍（反馈循环）。
// 这里用 @_silgen_name 重新声明该 C 符号，继续沿用。
@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImage(
    _ screenBounds: CGRect,
    _ windowOption: CGWindowListOption,
    _ windowNumber: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> Unmanaged<CGImage>?

/// 点击穿透容器：仅在「设置态」正常交互；镜头/融合态下除融按钮外全部穿透到下层 app。
final class ClickThroughContainer: NSView {
    weak var fuseButton: NSView?
    var mode: AppState = .settings

    override func hitTest(_ point: NSPoint) -> NSView? {
        if mode == .settings { return super.hitTest(point) }

        // 融合按钮：所有非设置态都可点（镜头态显示，融合 / 区域态隐藏）
        if let fb = fuseButton, !fb.isHidden, fb.frame.contains(point) { return fb }

        guard mode == .lens else { return nil }   // 融合 / 区域：全透

        // 镜头态：主窗口是「透明镜头框」。框内完全穿透；顶部 30pt 控制栏可拖动、红绿灯可点；
        // 边缘 5pt 交给窗口系统（可拖拽缩放框大小）。
        let pWin = convert(point, to: nil)
        let b = bounds
        let edge: CGFloat = 5
        let nearEdge = pWin.x < edge || pWin.x > b.width - edge
            || pWin.y < edge || pWin.y > b.height - edge
        if nearEdge { return super.hitTest(point) }

        let barTop = b.height - Self.lensBarHeight
        if pWin.y >= barTop {
            if let win = self.window,
               let c = win.standardWindowButton(.closeButton),
               let m = win.standardWindowButton(.miniaturizeButton),
               let z = win.standardWindowButton(.zoomButton),
               let csup = c.superview, let msup = m.superview, let zsup = z.superview {
                let cf = csup.convert(c.frame, to: nil)
                let mf = msup.convert(m.frame, to: nil)
                let zf = zsup.convert(z.frame, to: nil)
                if [cf, mf, zf].contains(where: { $0.contains(pWin) }) {
                    return super.hitTest(point)   // 红绿灯可点
                }
            }
            return self   // 控制栏空白处：拖动窗口
        }
        return nil   // 框内：完全穿透
    }

    /// 镜头态控制栏高度（对齐设计稿：细条，含红绿灯 + 融按钮）。
    static let lensBarHeight: CGFloat = 30
}

/// 纯视觉、永远穿透的视图（镜头框描边等装饰用）。
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var overlayWindow: NSWindow!
    private var container: ClickThroughContainer!
    private var overlayView: TranslationOverlayView!
    private var fuseButton: NSButton!
    /// 设置态的窗口磨砂底：铺满整窗（含标题栏区域），
    /// 否则 SwiftUI 内容受安全区约束，标题栏那一横条会完全透明、透出桌面。
    private var windowBackdrop: NSVisualEffectView!
    /// 镜头态的控制栏底色：窗口顶部的细磨砂条，让控制栏"立"起来、便于拖动。
    private var lensBar: NSVisualEffectView!
    /// 镜头态的框描边：让透明镜头框的边缘可见（用户原始设计稿第 2 页的"透明框"）。
    private var lensBorder: PassThroughView!
    /// 镜头态四角点亮光（挂在 lensBorder 图层上的蓝色弧光；仅画框态随 lensBorder 显隐）。
    private var lensCornerGlow: CAShapeLayer?
    /// 根 SwiftUI 宿主视图（设置页 / 镜头提示），便于在镜头态隐藏、设置态显示。
    private var hostingView: NSView!
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Control 悬停翻译（按住 ⌃ 指译：只翻译指针所指单词/句子，含桌面文件）
    private var controlMonitors: [Any] = []
    private var hoverWindow: NSPanel?
    private var hoverLabel: NSTextField?        // 气泡第一行：原文（浅灰）
    private var hoverLabelTrans: NSTextField?   // 气泡第二行：译文（黑字），无译文时隐藏
    private var hoverBg: NSVisualEffectView?
    private var hoverTimer: Timer?
    private var lastHoverText: String?
    private var lastHoverOriginal: String?
    private var lastHoverPoint: NSPoint = .zero
    private var lastOcrAt: Double = 0   // 指译 OCR 节流时间戳
    private var lastOcrNilAt: Double = 0   // 指译 OCR 瞬时空宽限计时（避免气泡乱闪）
    private var lastControlEventAt: Double = 0   // 最近一次收到 Control 状态事件的时间（诊断用）
    private var controlUpSince: Double? = nil    // 权威状态显示「⌃ 未按下」的起始时刻（防误杀宽限）
    private var lastHoverWord: String?   // 当前气泡已显示的词（稳定化后的显示词）
    private var pendingWord: String?     // 候选词防抖：OCR 逐帧挑「最近词」会漂移，需连续命中才切换
    private var pendingCount: Int = 0    // 候选词连续命中帧数
    private var hoverTranslations: [String: String] = [:]  // 已翻译词缓存：word -> 译文（"" 表示翻译中）
    /// 缓存锁。**绝不能用 ocrQueue.sync 保护它**：OCR 走 ocrQueue，一旦某次截屏
    /// （CGWindowListCreateImage）卡顿，主线程 sync 等待就会被整体卡死 →
    /// flagsChanged 送不进来 → 表现为「按住 ⌃ 完全没反应」（实测出现过 34 秒死区）。
    /// 字典读写只需微秒级，用轻量锁即可，主线程永不因 OCR 被阻塞。
    private let hoverCacheLock = NSLock()

    /// 线程安全地读取已缓存译文。
    private func hoverCached(_ word: String) -> String? {
        hoverCacheLock.lock(); defer { hoverCacheLock.unlock() }
        return hoverTranslations[word]
    }
    private let hoverWorkQueue = DispatchQueue(label: "com.weilai.transcreen.hover", qos: .userInitiated)
    private let ocrQueue = DispatchQueue(label: "com.weilai.transcreen.hover.ocr", qos: .userInitiated)

    /// 融合态下，为每块屏幕各建一个覆盖窗口（主窗口隐藏，避免主屏双重覆盖）。
    private var fusionWindows: [NSScreen: NSWindow] = [:]
    private var fusionOverlays: [TranslationOverlayView] = []

    // MARK: - 生命周期

    /// 退出收尾（2026-10-13 补）：停掉采集与 OCR 流、作废定时器，并把译文缓存立即落盘。
    /// 旧实现没有收尾：SCStream 与定时器随进程一起消失虽不致命，但缓存的 2 秒去抖写入
    /// 会在退出瞬间丢掉最近一批译文（下次开机要重翻一遍）。
    func applicationWillTerminate(_ notification: Notification) {
        CaptureEngine.shared.stop()
        OCRTextExtractor.shared.stop()
        livenessTimer?.invalidate(); livenessTimer = nil
        hoverTimer?.invalidate(); hoverTimer = nil
        Translator.shared.flushCache()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApplication.shared.setActivationPolicy(.accessory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // 透明置顶穿透画布的核心配置
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        // ARC 下必须关掉：isReleasedWhenClosed 默认 true，close() 会自己 release 一次，
        // 叠加 ARC 的释放即过度释放——这是融合态退出闪退（autorelease pool 过度释放）的根因。
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false

        container = ClickThroughContainer()
        container.frame = NSRect(x: 0, y: 0, width: 620, height: 460)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true

        let hosting = NSHostingView(rootView: OverlayContentView().environmentObject(AppModel.shared))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        self.hostingView = hosting

        overlayView = TranslationOverlayView()
        overlayView.frame = container.bounds
        overlayView.autoresizingMask = [.width, .height]
        // 译文块绝不画出镜头框外（镜头态按框裁剪显示）
        overlayView.wantsLayer = true
        overlayView.layer?.masksToBounds = true

        fuseButton = makeFuseButton()

        // 设置态窗口底：真正的磨砂玻璃，铺满整窗（含标题栏横条），让窗口"立"起来
        windowBackdrop = NSVisualEffectView()
        windowBackdrop.material = .underWindowBackground
        windowBackdrop.blendingMode = .behindWindow
        windowBackdrop.state = .active
        windowBackdrop.frame = container.bounds
        windowBackdrop.autoresizingMask = [.width, .height]
        windowBackdrop.isHidden = true

        // 镜头态控制栏底色（仅镜头态显示）：窗口顶部细磨砂条，便于拖动
        lensBar = NSVisualEffectView()
        lensBar.material = .popover
        lensBar.blendingMode = .behindWindow
        lensBar.state = .active
        lensBar.wantsLayer = true
        // 标题栏形底（2026-10-12 18:38 用户截图圈绿）：左右补全到窗口两缘，
        // 顶角随镜头框圆角 12、底角直角——不再是四角全圆的"规整圆角矩形"。
        lensBar.layer?.cornerRadius = 12
        // 实测该图层坐标 minY = 底部（18:44 首版 MinY 对圆的是底两角）→ 顶两角用 MaxY 对。
        lensBar.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] // 仅顶两角圆、底两角直角
        lensBar.layer?.masksToBounds = true
        lensBar.frame = NSRect(x: 0, y: container.bounds.height - ClickThroughContainer.lensBarHeight - 3,
                               width: container.bounds.width,
                               height: ClickThroughContainer.lensBarHeight)
        lensBar.autoresizingMask = [.width, .minYMargin]
        lensBar.isHidden = true

        // 镜头态框描边（仅镜头态显示）：透明框的边缘可见、且暗示可缩放
        lensBorder = PassThroughView()
        lensBorder.wantsLayer = true
        lensBorder.layer?.borderWidth = 1.5
        lensBorder.layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        lensBorder.layer?.cornerRadius = 12
        lensBorder.frame = container.bounds
        lensBorder.autoresizingMask = [.width, .height]
        lensBorder.isHidden = true
        refreshLensCornerGlow()   // 四角点亮光（AppKit 图层；镜头态 hosting 隐藏，SwiftUI 版不渲染）

        container.addSubview(windowBackdrop, positioned: .below, relativeTo: hosting)
        container.addSubview(lensBar, positioned: .below, relativeTo: hosting)
        container.addSubview(hosting)
        container.addSubview(overlayView)
        container.addSubview(lensBorder)
        container.addSubview(fuseButton)
        container.fuseButton = fuseButton

        window.contentView = container
        window.delegate = self
        self.overlayWindow = window
        let c = container!
        Task { @MainActor in Translator.shared.attachHosting(to: c) }
        CaptureEngine.shared.excludeWindowIDs = [CGWindowID(overlayWindow.windowNumber)]

        // 取字引擎 → 覆盖层（广播到主覆盖层 + 所有融合态分屏覆盖层）
        CaptureEngine.shared.onUpdate = { [weak self] items in
            self?.pushItems(items)
        }
        CaptureEngine.shared.regionProvider = { [weak self] in
            self?.overlayWindow.frame ?? .zero
        }

        // 暂停联动
        AppModel.shared.$paused
            .sink { [weak self] paused in
                CaptureEngine.shared.setPaused(paused)
                if paused {
                    // 两套覆盖层都必须清空：融合态下**主覆盖层是隐藏的**，
                    // 只清它等于没清 —— 分屏覆盖层的块会原样留在屏幕上（2026-10-13 用户报
                    // 「页面经常整体跳动 / 满屏残留」时发现的遗漏：applyPeek / applyHover
                    // 都同时广播两套覆盖层，唯独这里漏了 fusionOverlays）。
                    self?.overlayView.items = []
                    for ov in self?.fusionOverlays ?? [] { ov.items = [] }
                }
            }
            .store(in: &cancellables)

        // 语言切换 → 预热翻译会话（订阅时立即按当前设置预热一次）
        AppModel.shared.$sourceLanguageCode
            .combineLatest(AppModel.shared.$targetLanguageCode)
            .sink { src, tgt in
                Task { @MainActor in
                    // 目标语言是否中文 → 供「已是中文的文本不再翻译」这条过滤使用
                    CaptureEngine.shared.targetIsChinese = tgt.hasPrefix("zh")
                // 语言方向变了 → 清空引擎内译文表，避免沿用另一种语言的旧译文
                CaptureEngine.shared.invalidateTranslations()
                // 源语言同步给 OCR：决定 Vision 识别语言集合，非中英文源不再乱码
                OCRTextExtractor.shared.sourceLanguageCode = src
                    // 记录方向：用户选定的源语言 = 低置信度检测的回退目标；目标语言决定术语表是否生效。
                    // 必须在这里（而不是 prepare 里）设置——prepare 每批都会按「检测出的语言」被调用，
                    // 在那里写会把用户的选择覆盖成"当前这一组的语言"。
                    Translator.shared.setDirection(sourceCode: src, targetCode: tgt)
                    let srcLocale = LanguageOption.sourceOption(forCode: src).locale
                    let tgtLocale = LanguageOption.targetOption(forCode: tgt).locale ?? .init(identifier: "zh-Hans")
                    await Translator.shared.prepare(source: srcLocale, target: tgtLocale)
                }
            }
            .store(in: &cancellables)

        setupStatusItem()
        HotkeyManager.shared.start()
        PeekManager.shared.start()
        startHoverTracking()   // 菜单类块悬停高亮：常驻全局鼠标跟踪（2026-10-12 用户）
        AXTextExtractor.shared.startMonitoring()   // 记录上一个前台 app，供镜头态回退取字
        startControlMonitor()   // 按住 ⌃ 悬停翻译
        startLivenessProbe()    // 临时诊断：心跳探针，用于判定「没反应」是主线程卡死还是按键事件没送到

        centerOnMainScreen(window)
        applyState(.settings)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 标题栏布局完成后再校正一次融按钮位置（首次窗口尚未 on-screen 时读不到红绿灯 frame）
        DispatchQueue.main.async { [weak self] in self?.layoutFuseButton() }

        // 首次启动 → 弹出 3 步引导（权限讲解 + 一键跳设置）。
        OnboardingWindowController.shared.showIfNeeded()
    }

    // MARK: - 三态切换

    func applyState(_ state: AppState) {
        let w = overlayWindow!
        AppModel.shared.state = state
        container.mode = state
        fuseButton.isHidden = (state == .fusion || state == .region || state == .off)   // 设置态 / 镜头态都显示
        windowBackdrop.isHidden = (state != .settings)                 // 磨砂底只在设置态
        RegionSelectionController.shared.cancel()   // 切换模式时关闭残留选框
        if state != .fusion { teardownFusionWindows() }   // 离开融合态时拆除分屏覆盖窗口
        if state == .off { stopLensCursorPoller() }

        switch state {
        case .settings:
            stopLensCursorPoller()
            w.level = .floating
            w.isMovableByWindowBackground = false
            w.ignoresMouseEvents = false
            setTrafficLights(hidden: false)
            hostingView.isHidden = false
            lensBar.isHidden = true
            lensBorder.isHidden = true
            container.layer?.cornerRadius = 0
            w.setContentSize(NSSize(width: 620, height: 460))
            centerOnMainScreen(w)
            CaptureEngine.shared.stop()
            w.orderFront(nil)
            layoutFuseButton()          // 设置态才显示融按钮，此处定位最可靠

        case .lens:
            // 镜头态：恢复设计稿第 2 页的「透明镜头框」——可见圆角边框罩住一块区域，
            // 框内文字实时翻译（AX + OCR 均裁到框内）、完全鼠标穿透；
            // 顶部为细磨砂控制栏（30pt）：可拖动、红绿灯可点、融按钮可进融合。
            w.level = .floating
            w.isMovableByWindowBackground = true
            w.ignoresMouseEvents = true   // 默认整窗穿透；光标轮询在控制栏/边缘处临时开启交互
            w.orderFront(nil)             // 从融合态切来时主窗口已被 orderOut 隐藏，必须重新显形
            setTrafficLights(hidden: false)
            hostingView.isHidden = true
            lensBar.isHidden = false
            lensBorder.isHidden = false
            container.layer?.cornerRadius = 12
            // 镜头框默认尺寸 620×460，居中略偏上（视觉重心更稳）
            let screen = NSScreen.main ?? NSScreen.screens.first!
            let fw: CGFloat = 620, fh: CGFloat = 460
            let fx = screen.visibleFrame.midX - fw / 2
            let fy = screen.visibleFrame.midY - fh / 2 + 30
            w.setFrame(NSRect(x: fx, y: fy, width: fw, height: fh), display: true)
            updateLensChrome()
            overlayView.items = []
            CaptureEngine.shared.start(mode: .lens, region: w.frame)
            layoutFuseButton()
            startLensCursorPoller()

        case .fusion:
            stopLensCursorPoller()
            // 融合态：为每块屏幕各建一个覆盖窗口（主窗口隐藏，避免主屏双重覆盖），
            // 罩住整屏含菜单栏；不抢焦点、完全点击穿透。
            w.orderOut(nil)                 // 主窗口隐藏，改用分屏覆盖窗口
            lensBar.isHidden = true
            lensBorder.isHidden = true
            container.layer?.cornerRadius = 0
            hostingView?.isHidden = false
            buildFusionWindows()
            CaptureEngine.shared.start(mode: .fusion, region: .zero)
            // 首次进入融合态：浮出一次性交互引导卡（教手势 / 指出口）
            if let main = NSScreen.main ?? NSScreen.screens.first {
                FusionCoachMark.shared.showIfNeeded(on: main)
            }

        case .region:
            stopLensCursorPoller()
            // 区域态：先弹拖拽选框，用户选定后再把覆盖窗口定位到该矩形并启动 OCR 裁切捕获。
            w.level = .floating
            w.isMovableByWindowBackground = false
            w.ignoresMouseEvents = true
            setTrafficLights(hidden: true)
            hostingView.isHidden = false
            lensBar.isHidden = true
            lensBorder.isHidden = true
            container.layer?.cornerRadius = 0
            CaptureEngine.shared.stop()
            w.orderFront(nil)
            RegionSelectionController.shared.onSelected = { [weak self] rect in
                self?.startRegion(rect)
            }
            RegionSelectionController.shared.begin()

        case .off:
            // 隐藏态：完全停止翻译、隐藏所有窗口，仅菜单栏图标可见。
            // teardownFusionWindows / stopLensCursorPoller 已在 switch 前统一处理；
            // 由「退出屏幕融合/区域」快捷键触发，之后可经菜单「画框翻译 / 屏幕融合 / 设置」重新唤醒。
            CaptureEngine.shared.stop()
            setTrafficLights(hidden: true)
            lensBar.isHidden = true
            lensBorder.isHidden = true
            windowBackdrop.isHidden = true
            hostingView.isHidden = false
            container.layer?.cornerRadius = 0
            w.orderOut(nil)   // 主窗口隐藏，仅留菜单栏
        }
    }

    /// 镜头态 chrome 布局：控制栏细条贴窗口顶部、框描边铺满整窗。
    /// 窗口在镜头态可缩放，resize 时也会调用。
    private func updateLensChrome() {
        let b = container.bounds
        lensBorder.frame = b
        refreshLensCornerGlow()   // 窗口缩放后重算四角弧光路径
        layoutFuseButton()   // 控制栏磨砂条 + 融按钮随窗口尺寸重新居中对齐红绿灯
    }

    /// 镜头态四角点亮光：沿镜头框四个圆角各画一段 90° 蓝色弧光 + 沿边短延伸臂。
    /// 2026-10-14：SwiftUI（LensView）版在镜头态完全不渲染——切镜头态时 hosting 整体 isHidden=true，
    /// 用户看到的白框是这里的 AppKit lensBorder。故角光挂同一机制（lensBorder 图层子层），
    /// 仅画框态可见（随 lensBorder 显隐），窗口缩放时重算路径。
    private func refreshLensCornerGlow() {
        let glow: CAShapeLayer
        if let l = lensCornerGlow {
            glow = l
        } else {
            glow = CAShapeLayer()
            glow.strokeColor = NSColor.systemBlue.cgColor
            glow.fillColor = NSColor.clear.cgColor
            glow.lineWidth = 1.5              // 与白色描边同粗
            glow.lineCap = .round
            glow.shadowColor = NSColor.systemBlue.cgColor
            glow.shadowOpacity = 0.35
            glow.shadowRadius = 22            // 模糊发光：更大半径、更淡，更透明更散
            glow.shadowOffset = .zero
            lensBorder.layer?.addSublayer(glow)
            lensCornerGlow = glow
        }
        let b = lensBorder.bounds.insetBy(dx: 1.5, dy: 1.5)
        let r: CGFloat = 12      // 与镜头框圆角一致
        let arm: CGFloat = 4     // 弧两端沿边延伸的亮臂长度（减半）
        let p = CGMutablePath()
        // AppKit 图层坐标：原点左下、y 向上。
        // 仅保留下面两个角（左下、右下）的蓝光；上面两个角（左上、右上）靠近控制栏，
        // 已按用户要求（2026-10-14 15:30「上面两个蓝色圆角删除」）移除。
        // 左下：左边缘向下 → 弧 180°→270° → 底边缘向右
        p.move(to: CGPoint(x: b.minX, y: b.minY + r + arm))
        p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
        p.addArc(center: CGPoint(x: b.minX + r, y: b.minY + r), radius: r,
                 startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        p.addLine(to: CGPoint(x: b.minX + r + arm, y: b.minY))
        // 右下：底边缘向左 → 弧 270°→360° → 右边缘向上
        p.move(to: CGPoint(x: b.maxX - r - arm, y: b.minY))
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
        p.addArc(center: CGPoint(x: b.maxX - r, y: b.minY + r), radius: r,
                 startAngle: .pi * 1.5, endAngle: .pi * 2, clockwise: false)
        p.addLine(to: CGPoint(x: b.maxX, y: b.minY + r + arm))
        glow.path = p
    }

    /// 区域选框确认后：将覆盖窗口定位到选区矩形，仅在该区域内取字翻译。
    private func startRegion(_ rect: NSRect) {
        let w = overlayWindow!
        w.level = .floating
        w.setFrame(rect, display: true)
        w.ignoresMouseEvents = true
        setTrafficLights(hidden: true)
        CaptureEngine.shared.start(mode: .region, region: rect)
        w.orderFront(nil)
    }

    // MARK: - 多屏融合覆盖窗口

    /// 把最新一批译文广播到覆盖层：
    /// 设置 / 镜头 / 区域态 → 主窗口覆盖层（镜头态的译文块只出现在镜头框内）；
    /// 融合态 → 各分屏覆盖层（主窗口此时隐藏）。
    private func pushItems(_ items: [CapturedText]) {
        // 两套覆盖层**都**更新（2026-10-13 加固，非行为改动：另一套的窗口此刻是隐藏/已关闭的）。
        // 旧写法按当前 state 分派，而 `applyState` 里 **state 先改、`CaptureEngine.stop()` 后调**，
        // 中间那一拍的推送就只写主覆盖层 —— 融合态分屏覆盖层从此冻结在最后一批块不再刷新，
        // 用户看到的就是「退出融合态后屏幕上还留着一层块 / 页面像卡住」。
        // 代价：多赋值一次（不可见）；收益：任何 state 下都没有"被漏更新的覆盖层"。
        overlayView.items = items
        for ov in fusionOverlays { ov.items = items }
    }

    /// 「按住 Shift 偷看原文」：把 peek 状态广播到主覆盖层与所有分屏覆盖层。
    func applyPeek(active: Bool, point: NSPoint) {
        overlayView.applyPeek(active: active, point: point)
        for ov in fusionOverlays { ov.applyPeek(active: active, point: point) }
    }

    /// 悬停高亮广播：把鼠标位置转发给主覆盖层与所有分屏覆盖层。
    /// 块命中判断在各覆盖层内部做（point 不属于自己的块时自然无高亮），天然支持多屏。
    func applyHover(point: NSPoint) {
        overlayView.applyHover(point: point)
        for ov in fusionOverlays { ov.applyHover(point: point) }
    }

    /// 菜单类块悬停高亮的常驻全局鼠标跟踪（2026-10-12 用户）。
    /// 为什么不用 PeekManager 通道：peek 只在按住 Shift 时活跃，而悬停高亮要「平时移动就生效」。
    /// 全局 mouseMoved 频率高，但处理只是几次矩形 contains 判断 + setHovered 防抖，开销可忽略。
    /// 需要辅助功能授权（本 app 的 AX 采集本就依赖它）。
    private var hoverMonitor: Any?
    private func startHoverTracking() {
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.applyHover(point: NSEvent.mouseLocation)
        }
    }

    /// 融合覆盖窗口只建在**主显示器**上（用户要求：融合态仅翻译主屏）。
    /// 取零号屏（CG 坐标原点、菜单栏所在屏）。
    private var fusionScreen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main!
    }

    /// 为主显示器建一个透明覆盖窗口，用于融合态。
    private func buildFusionWindows(showHUD: Bool = true) {
        teardownFusionWindows()
        let screen = fusionScreen
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
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true
        let ov = TranslationOverlayView()
        ov.frame = NSRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        ov.autoresizingMask = [.width, .height]
        win.contentView = ov
        win.orderFront(nil)
        fusionWindows[screen] = win
        fusionOverlays.append(ov)
        // 融合态出口：角落 HUD（鼠标靠近才浮现；隐藏时完全穿透）。仅装在主屏。
        if showHUD { FusionHUD.shared.install(screens: [screen]) }

        // OCR 必须排除所有覆盖窗口（含 HUD），否则译文块会被二次识别、越堆越多。
        CaptureEngine.shared.excludeWindowIDs =
            [CGWindowID(overlayWindow.windowNumber)] +
            fusionWindows.values.map { CGWindowID($0.windowNumber) } +
            FusionHUD.shared.windowIDs
        // 若进入融合时正按住 Option，让新分屏覆盖层也立即进入偷看状态
        if PeekManager.shared.isActive {
            for ov in fusionOverlays { ov.applyPeek(active: true, point: NSEvent.mouseLocation) }
        }
    }

    /// 关闭并清理所有分屏覆盖窗口，主窗口恢复为可见态由调用方决定。
    private func teardownFusionWindows() {
        FusionHUD.shared.teardown()
        for (_, win) in fusionWindows { win.close() }
        fusionWindows.removeAll()
        fusionOverlays.removeAll()
        // 防御性直清主覆盖层：杜绝任何在途后台扫描把上一帧融合块又推回隐藏的主层、
        // 待下次进入非融合态时闪现残留。（结构上 stop() 也会推空，这里双保险。）
        overlayView?.items = []
        if let w = overlayWindow {
            CaptureEngine.shared.excludeWindowIDs = [CGWindowID(w.windowNumber)]
        }
    }

    /// 隐藏/显示窗口红绿灯按钮（融合态隐藏 chrome）。
    private func setTrafficLights(hidden: Bool) {
        for kind in [NSWindow.ButtonType.closeButton,
                     .miniaturizeButton,
                     .zoomButton] {
            overlayWindow!.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    // MARK: - 融按钮

    /// 融按钮：圆点配色跟随「窗口 key 态 + 悬停」，对齐红绿灯行为（2026-10-12 18:51 用户）。
    /// 窗口未选中且未悬停 → 失焦灰点（动态跟随深/浅色模式）；悬停或窗口选中 → 蓝色强调色。
    final class FuseDotButton: NSButton {
        private var hovered = false { didSet { if hovered != oldValue { updateColor() } } }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for ta in trackingAreas where ta.owner === self { removeTrackingArea(ta) }
            // activeAlways：窗口未选中（非 key）时悬停依然生效，与红绿灯悬停一致
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent)  { hovered = false }

        func updateColor() {
            wantsLayer = true
            // 圆角必须在这里设：wantsLayer 之前 layer 为 nil，外部提前设会被丢掉（18:54 方形 bug 根因）
            layer?.cornerRadius = 6    // 12px 圆 → 半径 6，与红绿灯同尺寸
            layer?.masksToBounds = true
            let accent = NSColor.controlAccentColor
            // 失焦红绿灯参考值（2026-10-12 18:58 用户用数码测色计实测，浅色模式）：
            // 内圆填充 sRGB(193,197,199)、外环 sRGB(165,169,171)——失焦态是「内圆+外环」双层。
            let fill = NSColor(name: nil) { ap in
                ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 0.35, alpha: 1)
                    : NSColor(srgbRed: 193.0/255.0, green: 197.0/255.0, blue: 199.0/255.0, alpha: 1)
            }
            let ring = NSColor(name: nil) { ap in
                ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 0.45, alpha: 1)
                    : NSColor(srgbRed: 165.0/255.0, green: 169.0/255.0, blue: 171.0/255.0, alpha: 1)
            }
            let active = hovered || (window?.isKeyWindow ?? false)
            if active {
                layer?.backgroundColor = accent.cgColor
                layer?.borderWidth = 0          // 点亮态：纯蓝实心，无环
            } else {
                layer?.backgroundColor = fill.cgColor
                layer?.borderWidth = 1          // 失焦态：内圆填充 + 1pt 外环描边
                layer?.borderColor = ring.cgColor
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateColor()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }
    }

    private func makeFuseButton() -> NSButton {
        let b = FuseDotButton()
        b.title = ""                              // 与红绿灯统一：纯圆点，不写字
        b.isBordered = false
        b.updateColor()
        b.frame = NSRect(x: 74, y: 460 - 20, width: 12, height: 12)
        b.autoresizingMask = [.maxXMargin, .minYMargin] // 钉在左上角，紧挨红绿灯右侧
        b.toolTip = L10n.s("屏幕融合（⌘⇧F）", "Fusion (⌘⇧F)")
        b.target = self
        b.action = #selector(fuseTapped)
        b.isHidden = true
        return b
    }

    /// 控制栏（红绿灯 + 融按钮）+ 镜头态磨砂条统一布局：
    /// - 融按钮紧挨放大按钮右侧、与红绿灯同垂直中心；
    /// - 镜头态磨砂条在垂直方向**居中对齐**红绿灯中心（修复「四个按钮不居中」）。
    /// 全部读取真实窗口按钮位置（不同 macOS 版本红绿灯尺寸/间距不同），不写死坐标。
    private func layoutFuseButton() {
        guard let zoom = overlayWindow?.standardWindowButton(.zoomButton),
              let mini = overlayWindow?.standardWindowButton(.miniaturizeButton),
              let titlebar = zoom.superview else { return }

        // 红绿灯之间的中心距（标准 ≈ 20pt），融按钮沿用同一距离
        let spacing = max(zoom.frame.midX - mini.frame.midX, 16)

        // 融按钮：放大按钮中心向右 spacing，与红绿灯同中心
        let fbPoint = NSPoint(x: zoom.frame.midX + spacing, y: zoom.frame.midY)
        let fbWindow = titlebar.convert(fbPoint, to: nil)
        let fb = container.convert(fbWindow, from: nil)
        let s = fuseButton.frame.width
        fuseButton.frame = NSRect(x: fb.x - s / 2, y: fb.y - s / 2, width: s, height: s)

        // 控制栏磨砂条：垂直居中于红绿灯中心（四个按钮即在栏内垂直居中）；
        // 水平方向铺满窗口全宽（2026-10-12 18:38 用户：两端补全，不再左右各留 6pt）。
        let barH = ClickThroughContainer.lensBarHeight
        lensBar.frame = NSRect(x: 0, y: fb.y - barH / 2,
                               width: container.bounds.width, height: barH)
    }

    /// 融按钮配色跟随窗口选中状态（2026-10-12 18:47 用户）：key 通知到来时刷新。
    /// 具体配色（含悬停点亮、深/浅色失焦灰）由 FuseDotButton.updateColor() 统一负责。
    private func updateFuseAppearance() {
        (fuseButton as? FuseDotButton)?.updateColor()
    }

    @objc private func fuseTapped() { applyState(.fusion) }

    // MARK: - 镜头态鼠标穿透轮询

    /// 镜头态默认整窗 ignoresMouseEvents=true（完全穿透到下层 app）；
    /// 仅当光标位于顶部控制栏 / 窗口边缘时切回 false，
    /// 使控制栏可拖动、红绿灯/融按钮可点、窗口可缩放。
    private var lensCursorPoller: Timer?

    private func startLensCursorPoller() {
        stopLensCursorPoller()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateLensCursorIgnores()
        }
        RunLoop.main.add(t, forMode: .common)
        lensCursorPoller = t
        updateLensCursorIgnores()
    }

    private func stopLensCursorPoller() {
        lensCursorPoller?.invalidate()
        lensCursorPoller = nil
    }

    private func updateLensCursorIgnores() {
        guard AppModel.shared.state == .lens, let w = overlayWindow else { return }
        let m = NSEvent.mouseLocation
        let f = w.frame
        guard f.contains(m) else { w.ignoresMouseEvents = true; return }
        let fromTop = f.maxY - m.y
        let fromBottom = m.y - f.minY
        let fromLeft = m.x - f.minX
        let fromRight = f.maxX - m.x
        let barH = ClickThroughContainer.lensBarHeight + 6
        let inBar = fromTop <= barH

        // 四角：较大热区，光标变对角缩放样式并允许拖拽缩放（窗口本就 resizable）
        let cz: CGFloat = 20
        let dirs: NSCursor.FrameResizeDirection.Set = [.inward, .outward]
        let cornerPos: NSCursor.FrameResizePosition? = {
            if fromTop <= cz && fromLeft <= cz  { return .topLeft }
            if fromTop <= cz && fromRight <= cz { return .topRight }
            if fromBottom <= cz && fromLeft <= cz { return .bottomLeft }
            if fromBottom <= cz && fromRight <= cz { return .bottomRight }
            return nil
        }()
        if let pos = cornerPos {
            w.ignoresMouseEvents = false
            NSCursor.frameResize(position: pos, directions: dirs).set()
            return
        }

        let nearEdge = fromTop <= 6 || fromBottom <= 6 || fromLeft <= 6 || fromRight <= 6
        w.ignoresMouseEvents = !(inBar || nearEdge)
    }

    // MARK: - Control 悬停翻译

    /// 全局 + 本地监听 ⌃ 修饰键（需辅助功能授权，已在用）。按下进入悬停翻译、
    /// 松开退出。两种 monitor 并存：app 自身在前台时用本地，其他 app 前台时用全局。
    private func startControlMonitor() {
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            self?.handleControlFlags(ev); return ev
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            self?.handleControlFlags(ev)
        }
        if let local { controlMonitors.append(local) }
        if let global { controlMonitors.append(global) }

        // 打字活动监听：任意按键都刷新「最近键盘活动时刻」，供 CaptureEngine 做「打字冻结」——
        // 用户在别的 app（如 WorkBuddy）里打字时，被查看的 app（如 Xcode）AX 扫描偶发空，
        // 若照常清屏会主观"打字就不翻译了"；冻结上一帧即可，松手即恢复。
        // 本地（YiMu 自身在前台时）+ 全局（其他 app 前台时）并存。
        let keyLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            CaptureEngine.lastKeyAt = CACurrentMediaTime()
            return ev
        }
        let keyGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in
            CaptureEngine.lastKeyAt = CACurrentMediaTime()
        }
        if let keyLocal { controlMonitors.append(keyLocal) }
        if let keyGlobal { controlMonitors.append(keyGlobal) }
    }

    /// 心跳探针（临时诊断，验收后随日志一并删除）：每 3 秒无条件打一行
    /// `LIVE hovering=... ctrlDown=...`。它跑在**常驻**主线程定时器上（与悬停定时器无关），
    /// 于是可以决定性区分两类「没反应」：
    ///   · LIVE 行中断  → 主线程被卡死（如被 OCR 队列阻塞）；
    ///   · LIVE 行持续、ctrlDown=true 但 hovering=false → flagsChanged 没送到 / 状态机没切换。
    private var livenessTimer: Timer?
    private func startLivenessProbe() {
        livenessTimer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard self != nil else { return }        // 已释放即停，不 retain
            let held = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
            // 只在指译真正发生（悬停中 / 正按住 ⌃）时打点：其余时间零写入。
            // 旧实现无条件每 3 秒一行，实测日志 1893 行全是 hovering=false 的空转心跳，
            // 既白白常驻写盘，又让真正的 LIVE 信号淹没在噪声里。
            // 判据不变：LIVE 中断 = 主线程被卡死；LIVE 持续而 hovering=false = 事件没送到。
            guard AppModel.shared.hovering || held else { return }
            Self.hoverDiag("LIVE hovering=\(AppModel.shared.hovering) ctrlDown=\(held)")
        }
        RunLoop.main.add(t, forMode: .common)
        livenessTimer = t
    }

    private func handleControlFlags(_ ev: NSEvent) {
        lastControlEventAt = CACurrentMediaTime()
        setHovering(ev.modifierFlags.contains(.control))
    }

    /// 进入 / 退出悬停翻译（按住 ⌃ 指译）。
    /// 2026-10-12 用户新要求：指译优先级最高、但**不暂停**底层镜头 / 融合翻译——
    /// 指译气泡浮在最上层，底层翻译继续同步进行。故进入时不再 setPaused / 不再隐藏常规块。
    private func setHovering(_ on: Bool) {
        guard on != AppModel.shared.hovering else { return }
        AppModel.shared.hovering = on
        AXTextExtractor.diagLog("HOVER \(on ? "on" : "off")")   // 诊断：是否误触 Control 悬停清屏
        if on {
            ensureHoverWindow()
            lastOcrAt = 0        // 进入即清零 → 首帧立即抓 OCR，不等节流，指上去立刻有反应
            lastOcrNilAt = 0
            controlUpSince = nil // 刚按下，宽限计时清零，杜绝按下瞬间被误判为「已松开」
            // 指译 OCR 截的是「其他 app 窗口之下」的屏，必须经「屏幕录制」授权（TCC）。
            // 没授权时 CGWindowListCreateImage 只返回本 app 窗口 / 纯色 → 指到别的 app 永远"没反应"。
            // 进入时预检：未授权则弹一次系统授权框（已授权则 CGPreflight 直接 true，不会重复弹）。
            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                Self.hoverDiag("OCR needs Screen Recording permission")
            }
            startHoverTimer()
        } else {
            stopHoverTimer()
            hoverWindow?.orderOut(nil)
            lastHoverText = nil
            lastHoverOriginal = nil
            lastHoverWord = nil
            pendingWord = nil
            pendingCount = 0
            hoverCacheLock.lock()
            hoverTranslations.removeAll()
            hoverCacheLock.unlock()
        }
    }

    private func ensureHoverWindow() {
        guard hoverWindow == nil else { return }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.ignoresMouseEvents = true   // 悬停窗不抢事件，点击仍落到下层 app
        let v = NSView(); v.wantsLayer = true
        let bg = NSVisualEffectView()
        bg.material = .popover; bg.blendingMode = .behindWindow; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 8
        // 气泡改为「两个独立单行标签上下堆叠」：上行原文（浅灰次要），下行译文（黑字突出）。
        // 为什么不用单个多行 NSTextField：NSTextField 渲染 \n 换行依赖 NSTextFieldCell.wraps、
        // usesSingleLineMode、cellSize 等多个开关，任一未生效（或标签宽度刚好卡在折行边界）
        // 就会把第二行（译文）整行裁掉 —— 实测窗口已按两行撑到 h=55，用户却只看到第一行原文。
        // 两个单行标签各自设 frame、互不依赖换行渲染，译文必定画得出来。
        let mkLabel = { () -> NSTextField in
            let f = NSTextField(labelWithString: "")
            f.drawsBackground = false; f.isBordered = false
            f.isEditable = false; f.isSelectable = false
            // 自动折行（气泡「随内容伸缩」的前提）：仅设 lineBreakMode 不够——
            // wraps 藏在 NSTextFieldCell 里、默认 false，会把超宽文本按单行裁掉（显示不全）。
            f.usesSingleLineMode = false
            f.maximumNumberOfLines = 0
            f.lineBreakMode = .byWordWrapping
            if let c = f.cell as? NSTextFieldCell { c.wraps = true; c.isScrollable = false }
            return f
        }
        let label = mkLabel()
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        let label2 = mkLabel()
        label2.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label2.textColor = .labelColor
        label2.isHidden = true
        v.addSubview(bg); v.addSubview(label); v.addSubview(label2)
        w.contentView = v
        hoverWindow = w; hoverBg = bg; hoverLabel = label; hoverLabelTrans = label2
    }

    private func startHoverTimer() {
        stopHoverTimer()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tickHover() }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
        tickHover()
    }

    private func stopHoverTimer() { hoverTimer?.invalidate(); hoverTimer = nil }

    /// 每帧（主线程定时器触发）：指译**完全走 OCR，不依赖 AX**（用户 2026-10-12 决定）。
    /// 流程：光标周围截一小块屏 → 独立后台队列跑 Vision 识别 → 取离光标最近的行 →
    /// 主线程刷新气泡 + 翻译。主线程只做显示，不被 OCR（~300ms）阻塞，气泡即时刷新。
    /// 节流 0.15s（~6-7fps）：兼顾灵敏度与 CPU；OCR 瞬时空给 0.25s 宽限，避免气泡乱闪。
    private func tickHover() {
        // 防卡死兜底（关键修正）：flagsChanged 只在修饰键「变化」那一刻触发，
        // **稳定按住 ⌃ 期间不会再有任何事件**——旧逻辑用「距上次事件 > 3 秒」判断，
        // 于是正常按住不动约 3 秒就被误判为「已松开」而强制关闭气泡，且松手前再也不会回来
        // （这正是「气泡都没弹出来 / 用一会儿就没反应」的根因）。
        // 改用权威的全局按键状态 CGEventSourceFlagsState(.combinedSessionState)——
        // 它反映窗口服务器里的真实按键状态，不依赖事件是否送达。
        // 连续 0.6s 都显示 ⌃ 未按下才退出（0.6s 宽限避开按下瞬间事件与状态的竞态，不闪烁）。
        if AppModel.shared.hovering {
            let held = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
            if held {
                self.controlUpSince = nil
            } else {
                if self.controlUpSince == nil {
                    self.controlUpSince = CACurrentMediaTime()
                } else if CACurrentMediaTime() - self.controlUpSince! > 0.6 {
                    self.controlUpSince = nil
                    setHovering(false)
                    return
                }
            }
        }
        let m = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        guard now - self.lastOcrAt > 0.15 else { return }
        self.lastOcrAt = now
        self.ocrQueue.async { [weak self] in
            guard let self, AppModel.shared.hovering else { return }
            let t0 = CACurrentMediaTime()
            guard let word = self.ocrWord(at: m) else {
                // OCR 瞬时空（光标划过图标缝隙 / 空白处）：给 0.25s 宽限，避免气泡无故闪烁消失。
                Self.hoverDiag("OCR nil  \(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000))ms @\(Int(m.x)),\(Int(m.y))")
                if CACurrentMediaTime() - self.lastOcrNilAt > 0.25 {
                    DispatchQueue.main.async { self.hoverWindow?.orderOut(nil) }
                }
                return
            }
            self.lastOcrNilAt = CACurrentMediaTime()

            // 稳定化（防抖）：密集文字里 OCR 每帧挑「离光标最近」的词，候选会逐帧漂移，
            // 直接 switch 显示词会让 presentHover 每帧把气泡重置成「原词单行」，
            // 译文两行刚异步回来就被下一帧冲掉 → 用户看到「只显示原文、不翻译」。
            // 规则：同一候选连续命中 ≥2 帧（≈0.3s）才切换显示词；切换后用缓存优先显示两行。
            if word == self.pendingWord {
                self.pendingCount += 1
            } else {
                self.pendingWord = word
                self.pendingCount = 1
            }
            let stable = self.pendingCount >= 2
            let pt = m

            // 同一显示词：译文可能已在后台回来、但显示仍停在单行 → 补成两行并持久
            // （防止被旧帧的反向覆盖循环掉），且全程不再用单行原词回写。
            if word == self.lastHoverWord,
               let tr = self.hoverCached(word), !tr.isEmpty, tr != word {
                let shown = "\(word)\n\(tr)"
                DispatchQueue.main.async {
                    guard AppModel.shared.hovering, self.lastHoverWord == word else { return }
                    self.presentHover(shown, at: pt)
                }
                return
            }
            // 切换条件：尚无显示词，或（候选≠显示词 且 已稳定）
            guard self.lastHoverWord == nil || (word != self.lastHoverWord && stable) else { return }
            self.lastHoverWord = word
            Self.hoverDiag("OCR word \(String(format: "%.0f", (CACurrentMediaTime() - t0) * 1000))ms len=\(word.count)")
            DispatchQueue.main.async {
                guard AppModel.shared.hovering else { return }
                // 已翻过该词 → 直接两行，不闪单行；否则先单行原文、再异步补全译文。
                if let tr = self.hoverCached(word), !tr.isEmpty, tr != word {
                    self.presentHover("\(word)\n\(tr)", at: pt)
                } else {
                    self.presentHover(word, at: pt)
                    self.translateHoverIfNeeded(word, at: pt)
                }
            }
        }
    }

    /// 指译调试日志（临时）：记录每帧走的是 AX 还是 OCR、OCR 耗时与识别结果，
    /// 便于量化「迟钝 / 没反应」到底卡在哪。验收后删除。
    ///
    /// 隐私红线（2026-10-13 收口，勿回退）：
    /// ① **绝不落屏幕上的任何真实文本**——只记数量与长度（`len=`），
    ///    旧实现把 OCR 候选与译文整句明文写进日志（实测历史日志里有整段业务文本 + 业务 ID）；
    /// ② 不再写 `/tmp`（该目录全局可读，sticky 只防删不防读），改到 Application Support 下的
    ///    Logs 目录，并以 `0600` 创建——同机其他用户/进程读不到。
    private static func hoverDiag(_ s: String) {
        let line = String(format: "%.2f %@\n", Date().timeIntervalSince1970, s)
        guard let data = line.data(using: .utf8) else { return }
        guard let dir = Self.privacySafeLogDir() else { return }
        let path = dir.appendingPathComponent("hover.log").path
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: data,
                          attributes: [.posixPermissions: 0o600])
            return
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        }
    }

    /// 诊断日志目录：`~/Library/Application Support/YiMu/Logs`，0700，与业务数据同处一处，
    /// 绝不放 `/tmp`（全局可读）。日志一律 0600 创建。
    static func privacySafeLogDir() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("YiMu/Logs", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        return dir
    }

    /// 指译 OCR 兜底用的识别语言：覆盖中日韩俄法德西等常用语言（比镜头「跟随源语言」更宽），
    /// 保证用户随手指到的任意语言都能被 Vision 认出，不再因语言不匹配而「没反应」。
    private static let hoverOCRLanguages: [String] = [
        "en-US","zh-Hans","ja-JP","ko-KR","ru-RU","fr-FR","de-DE","es-ES",
        "pt-BR","it-IT","th-TH","vi-VN","ar","id","ms","nl-NL","pl-PL","tr-TR","uk-UA"
    ]

    /// 指译 OCR 兜底：在光标周围截一小块「我们窗口之下」的屏（CGWindowListCreateImage
    /// .optionOnScreenBelowWindow → 排除自身译文块，杜绝反馈循环），跑 Vision 识别，
    /// 挑「光标落在其词框内」的那个词（无则最近），返回其文本。范围交给任何可见内容。
    private func ocrWord(at point: NSPoint) -> String? {
        let ext: CGFloat = 90          // 光标周围 90pt 半边 → 180pt 见方
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main!
        let sf = screen.frame
        var region = NSRect(x: point.x - ext, y: point.y - ext, width: ext * 2, height: ext * 2)
        region = region.intersection(sf)
        guard region.width > 20, region.height > 20 else { return nil }

        let primaryH = AXTextExtractor.primaryDisplayHeight()
        // AppKit 全局（原点左下）→ Quartz 全局（原点左上、Y 向下），翻转 Y，基准=主屏高度。
        let quartz = CGRect(x: region.minX,
                            y: primaryH - region.maxY,
                            width: region.width,
                            height: region.height)
        // 只截「译幕主覆盖窗口之下」的内容，排除译文块自身（避免把译文再翻一遍）。
        // .bestResolution：视网膜屏用设备像素截（2x/3x），小字不被降采样 → Vision 认得更准
        // （实测 .nominalResolution 下桌面文件标签小字被认成 "tim" 这类截断）。
        let belowWin: CGWindowID = (overlayWindow?.windowNumber).map { CGWindowID($0) } ?? kCGNullWindowID
        guard let img = _CGWindowListCreateImage(quartz,
                                                 .optionOnScreenBelowWindow,
                                                 belowWin,
                                                 .bestResolution)?.takeRetainedValue() else { return nil }

        let ci = CIImage(cgImage: img)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        // 指译是「随手点哪翻哪」，目标文字语言不可预知——用覆盖面最广的语言集
        // （不再跟随源语言设置），避免「指到非源语言内容 → Vision 识别失败 → 没反应」。
        req.usesLanguageCorrection = true
        req.recognitionLanguages = Self.hoverOCRLanguages
        req.automaticallyDetectsLanguage = true
        // 0.008（2x 屏约 8pt）：与镜头一致，桌面图标标签/菜单小字也能认，扩大可指范围。
        req.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        try? handler.perform([req])
        guard let obs = req.results else { return nil }

        // Vision boundingBox 为归一化（原点左下、Y 上），直接按区域尺寸换算成 AppKit 全局矩形，
        // 与截图像素分辨率无关（兼容 .bestResolution 的高分图，词框定位仍准确）。
        var items: [(text: String, rect: NSRect)] = []
        var candsDbg: [String] = []
        for o in obs {
            let cands = o.topCandidates(4)
            // 在置信度≥0.3 的候选里优先取「更完整」的（最长，其次置信度更高）：
            // 解决 Vision 把 "time" 误判成 "tim" 这类截断——脏图下首选候选偏短，
            // 而第二候选常是完整词，取最长即可兜底。
            let good = cands.filter { $0.confidence >= 0.3 }
            guard !good.isEmpty else { continue }
            let chosen = good.max { a, b in
                if a.string.count != b.string.count { return a.string.count < b.string.count }
                return a.confidence < b.confidence
            }!
            let b = o.boundingBox
            let gx = region.minX + b.origin.x * region.width
            let gy = region.minY + b.origin.y * region.height
            let rect = NSRect(x: gx, y: gy, width: b.width * region.width, height: b.height * region.height)
            items.append((chosen.string, rect))
            candsDbg.append(good.map { "\($0.string)(\(String(format: "%.2f", $0.confidence)))" }.joined(separator: "/"))
        }
        if !candsDbg.isEmpty {
            Self.hoverDiag("OCR cands n=\(candsDbg.count) len=["
                           + candsDbg.map { String($0.count) }.joined(separator: ",") + "]")
        }
        guard !items.isEmpty else { return nil }

        // 同一基线（光标所在行）上被图标/间距拆开的碎片合并成完整词。
        // 典型：桌面文件夹名 "time" 的图标插在中间 → Vision 识别成 "tim" + "e" 两个独立
        // 观察；不合并就会在气泡里闪 "tim" / "e"。把同基线、相邻（间隙 < 80pt）的碎片
        // 按 x 顺序拼回 → "time"。真实词间有空格时 Vision 本就识别成「一个带空格的观察」，
        // 不会拆成两个，故这里合并不会误并真实多词。
        let lineItems = items.filter { abs($0.rect.midY - point.y) < 30 }
        if lineItems.count >= 2 {
            let sorted = lineItems.sorted { $0.rect.minX < $1.rect.minX }
            var merged = sorted[0].text
            var union = sorted[0].rect
            for i in 1..<sorted.count {
                let gap = sorted[i].rect.minX - union.maxX
                if gap > -4, gap < 80 {   // 相邻（允许轻微重叠），间隙不超过 80pt（图标宽度级）
                    merged += sorted[i].text
                    let minX = min(union.minX, sorted[i].rect.minX)
                    let minY = min(union.minY, sorted[i].rect.minY)
                    let maxX = max(union.maxX, sorted[i].rect.maxX)
                    let maxY = max(union.maxY, sorted[i].rect.maxY)
                    union = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                }
            }
            if merged != sorted[0].text {
                items.append((merged, union))
                Self.hoverDiag("OCR merge n=\(sorted.count) len=["
                               + sorted.map { String($0.text.count) }.joined(separator: ",")
                               + "] => len=\(merged.count)")
            }
        }

        // 选最贴近光标的（光标落在矩形内优先）。
        var best: (text: String, score: CGFloat)?
        for it in items {
            let score: CGFloat = it.rect.contains(point) ? -1 : hypot(it.rect.midX - point.x, it.rect.midY - point.y)
            if best == nil || score < best!.score { best = (it.text, score) }
        }
        return best?.text
    }

    /// 指译翻译（原文→译文），文本变化才发请求；译文回来后原文+译文上下同显（气泡体验）。
    /// 指译翻译（原文→译文）。用 hoverTranslations 缓存：命中已译/翻译中直接跳过，
    /// 译文回来后写回缓存、若仍是当前显示词则持久显示「原词\n译文」两行。
    private func translateHoverIfNeeded(_ text: String, at point: NSPoint) {
        // 同步查/置缓存（ocrQueue 串行），避免同一词被并发重复发起翻译。
        // 用轻量锁（微秒级），不用 ocrQueue.sync —— 主线程绝不能等 OCR 队列。
        var shouldGo: Bool = false
        hoverCacheLock.lock()
        if self.hoverTranslations[text] == nil {
            self.hoverTranslations[text] = ""   // 翻译中占位
            shouldGo = true
        }
        hoverCacheLock.unlock()
        guard shouldGo else { return }
        Task { [weak self] in
            let tr = await Translator.shared.translate(text)
            let dir = "\(AppModel.shared.sourceLanguageCode ?? "auto")>\(AppModel.shared.targetLanguageCode)"
            Self.hoverDiag("TR dir=[\(dir)] srcLen=\(text.count) trLen=\(tr.count)")
            // 回写缓存 + 上屏都放进主队列的**同步**闭包：
            // ① NSLock 在 async 上下文不可用（Swift 6 是硬错误），同步闭包里才合法；
            // ② hoverTranslations 由「主线程 / ocrQueue / 本回调」三方共享，锁一步也不能省
            //    （后台 ocrQueue 里的 hoverCached 带锁读，见 tickHover）。
            // AppDelegate 不符合 Sendable，直接捕获进 @Sendable 闭包在 Swift 6 是硬错误。
            // 这里转存为 nonisolated(unsafe) 局部量：下文只在主队列里用它，线程模型不变。
            nonisolated(unsafe) let app = self
            DispatchQueue.main.async {
                guard let app else { return }
                app.hoverCacheLock.lock()
                app.hoverTranslations[text] = tr
                app.hoverCacheLock.unlock()
                guard AppModel.shared.hovering, app.lastHoverWord == text else { return }
                let shown = tr.isEmpty || tr == text ? text : "\(text)\n\(tr)"
                app.presentHover(shown, at: app.lastHoverPoint)
            }
        }
    }

    /// 在光标附近显示译文气泡（跟随光标，自动避让屏幕右/下边界）。
    private func presentHover(_ text: String, at point: NSPoint) {
        guard let w = hoverWindow, let label = hoverLabel,
              let label2 = hoverLabelTrans, let bg = hoverBg else { return }
        lastHoverPoint = point

        // 拆成「原文 / 译文」两行（只有原文时译文行隐藏）。
        var original = text
        var translation: String? = nil
        if text.contains("\n") {
            let parts = text.components(separatedBy: "\n")
            original = parts.first ?? text
            // 译文若含换行一律并成单行：气泡是「原文/译文」两行结构，多出的行会撑破布局。
            let t = parts.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            translation = t.isEmpty ? nil : t
        }

        let maxW: CGFloat = 460
        let pad: CGFloat = 10
        let gap: CGFloat = 4
        let maxTextH: CGFloat = 104     // 单条最多约 6 行，超出截断加省略号，气泡不被撑爆
        let origFont = NSFont.systemFont(ofSize: 13, weight: .regular)
        let transFont = NSFont.systemFont(ofSize: 13, weight: .medium)

        // ① 先测「不折行」的天然宽度 → 定气泡内容宽度 textW（这就是「自动伸缩」的宽度依据）。
        let natural1 = (original as NSString).size(withAttributes: [.font: origFont]).width
        let natural2 = translation.map {
            ($0 as NSString).size(withAttributes: [.font: transFont]).width } ?? 0
        let textW = ceil(min(max(natural1, natural2), maxW))

        // ② 再用 textW 折行测真实高度。关键：测量宽度必须等于标签最终 frame 宽度，
        //    否则（旧代码用 maxW 测、却按 textW 摆标签）折行行数不同 → 高度算少 → 显示不全。
        let (o1, s1) = Self.fitted(original, font: origFont, width: textW, maxHeight: maxTextH)
        let (o2, s2) = translation.map {
            Self.fitted($0, font: transFont, width: textW, maxHeight: maxTextH) } ?? ("", NSSize.zero)

        // 第一行：原文（浅灰次要）
        label.font = origFont
        label.textColor = .secondaryLabelColor
        label.stringValue = o1

        // 第二行：译文（黑字突出）
        if translation != nil {
            label2.font = transFont
            label2.textColor = .labelColor
            label2.stringValue = o2
            label2.isHidden = false
        } else {
            label2.stringValue = ""
            label2.isHidden = true
        }

        let h1 = ceil(s1.height) + 1     // +1px 抵消字体度量取整误差，避免末行被切
        let h2 = ceil(s2.height) + 1
        let contentH = h1 + (translation == nil ? 0 : gap + h2)
        let wWidth = textW + pad * 2
        let wHeight = contentH + pad * 2

        var x = point.x + 16
        var y = point.y - 16 - wHeight
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main!
        let sf = screen.frame
        if x + wWidth > sf.maxX { x = point.x - 16 - wWidth }   // 右侧放不下 → 翻到光标左侧
        if x < sf.minX { x = sf.minX + 4 }                      // 左侧也放不下 → 贴左边
        if y < sf.minY { y = point.y + 16 }                     // 下方放不下 → 翻到光标上方
        if y + wHeight > sf.maxY { y = sf.maxY - wHeight - 4 }  // 上边溢出 → 收回来
        w.setContentSize(NSSize(width: wWidth, height: wHeight))
        w.setFrameOrigin(NSPoint(x: x, y: y))
        bg.frame = NSRect(x: 0, y: 0, width: wWidth, height: wHeight)
        // 内容视图未翻转（y 轴向上）：译文放下部，原文叠在其上。
        label2.frame = NSRect(x: pad, y: pad, width: textW, height: h2)
        label.frame = NSRect(x: pad,
                             y: pad + (translation == nil ? 0 : h2 + gap),
                             width: textW, height: h1)
        w.orderFront(nil)
        Self.hoverDiag("SHOW w=\(Int(wWidth)) h=\(Int(wHeight)) x=\(Int(x)) y=\(Int(y)) onscreen=\(w.isOnActiveSpace) origLen=\(o1.count) trLen=\(translation == nil ? 0 : o2.count)")
    }

    /// 在给定宽度内按折行测量文本尺寸；若高度超过 maxHeight，二分截断并加省略号。
    /// 返回（最终要显示的文本, 渲染所需尺寸）——保证气泡永远完整显示、不被超长内容撑爆。
    private static func fitted(_ text: String, font: NSFont, width: CGFloat,
                               maxHeight: CGFloat) -> (String, NSSize) {
        let measure = { (s: String) -> NSSize in
            (s as NSString).boundingRect(
                with: NSSize(width: width, height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]).size
        }
        let full = measure(text)
        if full.height <= maxHeight || text.isEmpty { return (text, full) }
        // 二分：找能塞进 maxHeight 的最大字符数（高度随字符数单调不减）
        var lo = 0, hi = text.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(String(text.prefix(mid)) + "…").height <= maxHeight {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        let cut = lo > 0 ? String(text.prefix(lo)) + "…" : "…"
        return (cut, measure(cut))
    }

    // MARK: - 点选窗口排除 app

    /// 进入「点选窗口」模式：用户在屏幕上点一个窗口，该窗口所属 app 即被加入排除列表。
    func startAppPicker() {
        AppPickerController.shared.onPicked = { [weak self] id in
            guard let self else { return }
            if !Preferences.shared.excludedBundleIDs.contains(id) {
                Preferences.shared.excludedBundleIDs.append(id)
            }
            self.refreshStatusMenu()
        }
        AppPickerController.shared.begin()
    }

    // MARK: - 菜单栏

    private var stateMenuItem: NSMenuItem?
    private var lensMenuItem: NSMenuItem?
    private var fusionMenuItem: NSMenuItem?
    private var pauseMenuItem: NSMenuItem?
    private var noticeMenuItem: NSMenuItem?
    /// 状态栏菜单是否正打开（HotkeyManager 据此跳过监听，避免与 keyEquivalent 双触发）。
    var statusMenuOpen = false

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 用 SF Symbol 模板图替代纯文字「译」：菜单栏自动适配明暗、更原生、更国际化。
            if let img = NSImage(systemSymbolName: "character.bubble.fill",
                                 accessibilityDescription: L10n.s("译幕", "Transcreen")) {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = L10n.s("译", "Tr")
            }
            button.toolTip = L10n.s("译幕", "Transcreen")
        }
        let menu = NSMenu()
        menu.delegate = self

        let state = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateMenuItem = state
        menu.addItem(state)

        // 语言包缺失提示（非模态、不弹窗）：只在菜单里显示一行，用户按需下载
        let notice = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        noticeMenuItem = notice
        menu.addItem(notice)

        let items: [(String, Selector)] = [
            (L10n.s("设置", "Settings"), #selector(showSettings)),
        ]
        for (title, sel) in items {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        // 2026-10-14 调整：画框翻译、屏幕融合移入「暂停翻译」同一栏，置于其上；
        // 快捷键同步显示在标题右侧（见 refreshStatusMenu）。
        let lens = NSMenuItem(title: L10n.s("画框翻译", "Frame translation"),
                              action: #selector(showLens), keyEquivalent: "")
        lens.target = self
        lensMenuItem = lens
        menu.addItem(lens)

        let fusion = NSMenuItem(title: L10n.s("屏幕融合", "Fusion"),
                                action: #selector(showFusion), keyEquivalent: "")
        fusion.target = self
        fusionMenuItem = fusion
        menu.addItem(fusion)

        let pause = NSMenuItem(title: "", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pauseMenuItem = pause
        menu.addItem(pause)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.s("退出译幕", "Quit Transcreen"),
                              action: #selector(terminate), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        self.statusItem = item
        refreshStatusMenu()
        // 监听后端切换（设置页写入 UserDefaults）→ 实时刷新「数据已外发」云标识。
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusBarBadge()
        }
    }

    /// 菜单栏按钮在「数据会外发」的引擎下显示 ☁，否则清空。
    /// 这是对你隐私红线的兜底：无论何时，一眼知道此刻翻译是否走云端。
    private func refreshStatusBarBadge() {
        guard let button = statusItem?.button else { return }
        button.title = Preferences.shared.translationBackend.sendsDataOffDevice ? "  ☁" : ""
    }

    /// 根据当前状态刷新菜单的动态文案（模式名 + 暂停/恢复）。
    func refreshStatusMenu() {
        let stateName: String
        switch AppModel.shared.state {
        case .settings: stateName = L10n.s("设置", "Settings")
        case .lens:     stateName = L10n.s("画框", "Frame")
        case .fusion:   stateName = L10n.s("屏幕融合", "Fusion")
        case .region:   stateName = L10n.s("区域", "Region")
        case .off:      stateName = L10n.s("已隐藏", "Hidden")
        }
        stateMenuItem?.title = L10n.s("当前：", "Mode: ") + stateName
        // 快捷键同步显示（每次菜单打开经 menuWillOpen 走到这里，改键后自动跟随）。
        // 优先用原生 keyEquivalent（真正右对齐、高亮变白，与 ⌘Q 同款观感）；
        // HotkeyManager 在菜单打开期间跳过监听，不会双触发。
        // 组合键无法映射为 keyEquivalent（Esc / 方向键等）时，退化为空格拼在标题后。
        applyMenuKey(lensMenuItem, action: Hotkey.Action.showLens,
                     title: L10n.s("画框翻译", "Frame translation"))
        applyMenuKey(fusionMenuItem, action: Hotkey.Action.toggleFusion,
                     title: L10n.s("屏幕融合", "Fusion"))
        applyMenuKey(pauseMenuItem, action: Hotkey.Action.togglePause,
                     title: AppModel.shared.paused
                        ? L10n.s("恢复翻译", "Resume")
                        : L10n.s("暂停翻译", "Pause"))
        // 融合态角落 HUD 的暂停图标也要跟着变：从菜单栏 / 热键切暂停时，
        // 旧实现只刷新菜单栏标题，HUD 上仍显示旧图标（点一下反而是相反的动作）。
        FusionHUD.shared.refresh()
        // 「数据已外发」云标识随后端实时更新。
        refreshStatusBarBadge()
        // 语言包缺失：菜单里安静提示（绝不自动弹系统下载框）
        let msg = MainActor.assumeIsolated { Translator.shared.missingNotice }
        if let msg {
            noticeMenuItem?.title = "⚠️ " + msg + L10n.s("（设置→通用→语言与地区 可下载）",
                                                         " (download via System Settings → General → Language & Region)")
            noticeMenuItem?.isHidden = false
        } else {
            noticeMenuItem?.isHidden = true
        }
    }

    /// 把配置的快捷键显示到菜单项右侧：能映射为 keyEquivalent 的用原生右对齐显示，
    /// 否则退化为把组合文本追加到标题后（少数 Esc/方向键组合才会走到这里）。
    private func applyMenuKey(_ mi: NSMenuItem?, action: String, title: String) {
        guard let mi else { return }
        mi.title = title
        mi.keyEquivalent = ""
        mi.keyEquivalentModifierMask = []
        guard let hk = Preferences.shared.hotkeys[action] else { return }
        let glyph = Hotkey.keyGlyph(code: hk.keyCode)
        if glyph.count == 1, let c = glyph.lowercased().first, c.isLetter || c.isNumber {
            mi.keyEquivalent = String(c)
            mi.keyEquivalentModifierMask = hk.modifierFlags
                .intersection([.command, .shift, .option, .control])
        } else {
            mi.title = title + "      " + hk.display
        }
    }

    @objc private func togglePause() {
        AppModel.shared.paused.toggle()
        refreshStatusMenu()
    }

    @objc private func showSettings() { applyState(.settings) }
    @objc private func showLens()     { applyState(.lens) }
    @objc private func showFusion()   { applyState(.fusion) }
    @objc private func showRegion()   { applyState(.region) }
    @objc private func terminate()    { NSApp.terminate(nil) }
}

// MARK: - 菜单栏动态刷新

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        statusMenuOpen = true
        refreshStatusMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuOpen = false
    }
}

// MARK: - 窗口尺寸变化

extension AppDelegate: NSWindowDelegate {
    /// 关闭按钮：镜头态回到设置（不退出 app）；设置态仅隐藏窗口（菜单栏可重新打开）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppModel.shared.state == .lens {
            applyState(.settings)
        } else {
            overlayWindow.orderOut(nil)
        }
        return false
    }

    func windowDidResize(_ notification: Notification) {
        layoutFuseButton()      // 窗口缩放后重新与红绿灯对齐
        if AppModel.shared.state == .lens {
            updateLensChrome()  // 控制栏细条 / 框描边跟随窗口
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        layoutFuseButton()
        updateFuseAppearance()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateFuseAppearance()
    }
}

// MARK: - 工具

extension AppDelegate {
    private func centerOnMainScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let origin = NSPoint(
            x: screen.visibleFrame.midX - frame.width / 2,
            y: screen.visibleFrame.midY - frame.height / 2
        )
        window.setFrameOrigin(origin)
    }
}
