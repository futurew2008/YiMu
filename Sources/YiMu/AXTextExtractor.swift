import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// 通过无障碍接口（Accessibility / AX）读取前台 app 的可见文本控件。
/// 精度高、零 OCR 延迟，仅对标准 Cocoa / Electron app 有效；游戏与自绘 UI 读不到。
///
/// **防幻影（关键）**
/// - 主内容从「前台 app 元素」递归，但**跳过整个菜单子树**（菜单单独采集）。
/// - 菜单栏 / 下拉菜单单独采集，并逐项做**命中测试**校验：该屏幕位置最上层元素是否
///   正好就是这段文字。关闭的菜单窗口在 AX 树里依旧会暴露条目，但坐标是「停在屏幕某处」
///   的假位置——命中测试把它们全部滤掉，避免在屏幕角落堆一片幻影译文。
/// - 无效矩形（退化 / 完全离屏）的元素既不收录、也不向下递归。
final class AXTextExtractor {
    static let shared = AXTextExtractor()

    /// 是否需要「辅助功能」授权（TCC）。
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// 主动请求「辅助功能」授权：弹出系统提示并登记到隐私列表，便于用户在设置里拨开关。
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 上一个前台的非自身 app（用户从控制栏切回时用来继续翻译背后的 app）。
    private var lastForeignApp: NSRunningApplication?

    /// 启动前台 app 监听：记录「上一个非自身的常规 app」。
    /// 当译幕自身成为前台（用户操作控制栏 / 点了融按钮）时，用它作为取字目标，
    /// 避免镜头 / 融合态完全读不到文字。
    func startMonitoring() {
        // 启动即记录当前前台（若非自身）：通知只在「切换」时触发，
        // 若启动译幕后用户没再切过 app，回退目标会是空 → 镜头态一条字都读不到。
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           front.activationPolicy == .regular {
            lastForeignApp = front
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier, app.activationPolicy == .regular {
                self?.lastForeignApp = app
            }
        }
    }

    // MARK: - 目标 app 选择

    /// 当前应当翻译的目标 app（决定读谁的 AX 树、以及排除名单判谁）。
    ///
    /// 顺序：
    /// ① **前台 app**（非自身、常规）——最准，平时译幕就翻"用户正在看的那块屏"的 app。
    /// ② **屏幕最上层属于其他 app 的普通窗口**——融合态刚进入时前台是译幕自己、
    ///    或前台是输入法进程（中文拼音合成时 frontmostApplication 会返回输入法，非 regular）
    ///    时，按窗口叠放顺序取最上层外部窗口，立刻锁定眼前那个 app，不必等用户去点它。
    /// ③ **最近一个非自身 app**——最后的兜底（输入法 / 自身在前台时回退到这里）。
    ///
    /// 注：2026-10-12 曾试过「键盘焦点 app（AX focused application）」作为第一优先，
    /// 但实测场景下用户是「在 WorkBuddy 里打字、主屏看 Xcode」——键盘焦点会指向
    /// WorkBuddy，导致译幕改翻 WorkBuddy 而非用户正在看的 Xcode，故撤掉该优先级，
    /// 改以「前台 app + 窗口叠放兜底」为准，并用 CaptureEngine 的打字冻结逻辑
    /// 解决「打字时 Xcode 扫描偶发空 → 浮层被清空」的问题。
    func currentTarget() -> NSRunningApplication? {
        let myBundle = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != myBundle,
           front.activationPolicy == .regular {
            return front
        }
        if let top = topmostForeignApp() { return top }
        return lastForeignApp
    }

    /// 屏幕（按叠放顺序，最上层在前）第一个属于其他 app 的普通窗口所属的 app。
    /// 只认层号 0（普通窗口）且面积像窗口的项，滤掉状态栏图标、阴影、小浮层。
    private func topmostForeignApp() -> NSRunningApplication? {
        let list = Self.windowListSnapshot()
        let myPID = ProcessInfo.processInfo.processIdentifier
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNum = w[kCGWindowOwnerPID as String] as? Int,
                  pid_t(pidNum) != myPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = b["Width"], let bh = b["Height"], bw >= 200, bh >= 120,
                  (w[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.05,
                  let app = NSRunningApplication(processIdentifier: pid_t(pidNum)),
                  app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }

    // MARK: - 菜单采集（后台线程 + 节流）

    /// 作废菜单采集结果（停止 / 切模式时调用）。
    ///
    /// 为什么必须显式清（2026-10-13 修「退出模式后菜单残影」）：
    /// `CaptureEngine.runAX` 有一条「`menuItemsAt` 距今 2.5s 内就把 `menuItems` 直接
    /// append 进 `latestAX`」的门控（菜单采集频率低，靠它跨帧续命）。
    /// `stop()` 清了引擎自己的 `latestAX`，却没清 AX 侧这份 → 退出模式后 2.5s 内再进来，
    /// 上一轮的菜单条目会绕过全部过滤链直接混进新一帧，屏幕上出现与当前界面无关的译文块。
    func clearMenuCache() {
        menuItems = []
        menuItemsAt = 0
        menuEmptyStreak = 0
        lastMenuWindowFP = ""
        menuForced = false
    }

    /// 上一次采集到的菜单条目（主线程读写；CaptureEngine.runAX 的完成回调也会读，故放开为 internal）。
    var menuItems: [CapturedText] = []
    /// 菜单条目的采集时间：超过 2 秒未刷新就弃用（菜单已关闭 / 采集停摆时不残留旧条目）。
    var menuItemsAt: CFTimeInterval = 0
    private var menuBusy = false
    private var lastMenuHarvest: CFTimeInterval = 0
    /// 连续「读失败」的轮数：只有连续多轮都读不到（而菜单窗口仍在）才认定菜单真的没了，
    /// 避免单次命中测试抖动就把整屏菜单译文一次性抹掉（用户报的「译文经常自动消失」）。
    private var menuEmptyStreak = 0
    /// 菜单窗口指纹（所有弹出菜单窗口矩形的拼接）：菜单一切换/关闭/新开，指纹立刻变化。
    /// 用它做两件事：①旧菜单条目立即作废（否则旧译文会压在新菜单上，看着像"没刷新"）；
    /// ②绕过节流立刻重采一轮（切换菜单时不必等满一个采集周期）。
    private var lastMenuWindowFP: String = ""
    /// 下一轮采集是否跳过节流（菜单刚变化时为 true）。
    private var menuForced = false
    /// 最近一次判定为「菜单窗口」的窗口描述（仅窗口名与尺寸，不含任何文本），诊断用。
    ///
    /// 2026-10-13：此处**原本是一个 static var**，主线程写（`scheduleMenuHarvest`，且在
    /// `menuBusy` 闸门之前，故闸门挡不住）、后台 `menuQueue` 读（`harvestMenus` 的诊断行）
    /// → 跨线程共享可变 String，可能撕裂读（新指针 + 旧长度）→ EXC_BAD_ACCESS / over-release。
    /// 这与 OCR 侧当年那次事故同型。现在改为**值传递**：主线程算好，作为参数传进 harvestMenus，
    /// 后台只读自己那一份不可变副本，共享状态彻底消失。
    /// （保留本注释以免有人再把静态变量加回来。）
    private let menuQueue = DispatchQueue(label: "com.weilai.transcreen.ax.menu", qos: .utility)

    /// 窗口列表快照缓存：每拍有 3+ 处要枚举窗口（hasOpenMenuWindow / menuWindowList /
    /// topmostForeignApp），而 CGWindowListCopyWindowInfo 是与窗口服务器争用的 syscalls。
    /// 0.1s 内复用同一份快照，把每拍多次枚举降到 1 次，主线程争用明显下降（B 方案）。
    private static var cachedWindowList: [[String: Any]]?
    private static var cachedWindowListAt: CFTimeInterval = 0
    private static func windowListSnapshot() -> [[String: Any]] {
        let now = CACurrentMediaTime()
        if let c = cachedWindowList, now - cachedWindowListAt < 0.1 { return c }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        cachedWindowList = list
        cachedWindowListAt = now
        return list
    }

    /// 目标进程此刻是否有**真正在屏**的窗口（`.excludeDesktopElements`：Finder 的「桌面」本身不算窗口）。
    ///
    /// 为什么需要它（2026-10-13 用户报「桌面经常会有残影」）：
    /// 窗口内容的采集是**从 app 根节点整棵树遍历**（`scanFrontmostText`），
    /// 唯一几何过滤是「矩形与屏幕相交」——而 AX 对**最小化(⌘M) / ⌘H 隐藏 / 处在其它桌面空间**
    /// 的窗口，照样返回完整窗口树与坐标，采集端无从分辨，于是照常画块；
    /// 块落在「窗口本该在的位置」，而屏幕上那儿只有壁纸 → 用户看到的就是桌面上的残影。
    /// 单纯点一下桌面（Finder 无窗口）同理：桌面元素被当成窗口内容采了上来。
    ///
    /// 与 `windowListSnapshot()` 分开、**不复用它的缓存**：那份快照不带
    /// `.excludeDesktopElements`（菜单路径依赖原语义，属锁死零改动区），这里必须带。
    /// 只读、线程安全，可在后台线程调用。
    nonisolated static func hasOnScreenWindow(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            if (info[kCGWindowOwnerPID as String] as? Int32) == pid { return true }
        }
        return false
    }

    /// 仅前台 app 的常规界面文本（跳过菜单子树）。**线程安全**：只读 AX + NSScreen，
    /// 不碰 `menuItems` / 诊断状态，可在后台串行队列调用——这是「把重扫描搬离主线程、
    /// 鼠标移动时翻译仍持续刷新」的关键（CaptureEngine 在后台跑它）。
    /// `nonisolated`：本类为 @MainActor 隔离，标记后可在后台线程直接调用（不触发 actor 跳转而跑在后台）。
    nonisolated func scanFrontmostText(appEl: AXUIElement) -> [CapturedText] {
        guard AXIsProcessTrusted() else { return [] }
        let screenFrames = NSScreen.screens.map { $0.frame }
        let primaryH = Self.primaryDisplayHeight()
        var results: [CapturedText] = []
        Self.traverseRec(element: appEl, depth: 0, maxDepth: 12,
                         results: &results, maxCount: 600,
                         skipMenus: true, tagMenu: false,
                         screenFrames: screenFrames, primaryH: primaryH)
        return results
    }

    /// 菜单采集节流：**有打开的菜单时 0.15s 一轮，空闲时 0.5s 一轮**；菜单窗口一有变化立即重采。
    ///
    /// 为什么要在「节流」之外再加一条「菜单窗口指纹变化 → 立刻重采」：
    /// 用户移动到另一个点打开新菜单时，旧菜单的条目还在 `menuItems` 里（旧译文压在新菜单上，
    /// 主观就是「换了菜单却不刷新」）。指纹一变就当场作废旧条目并跳过节流重采，
    /// 新菜单译文只差一轮采集 + 一次翻译的往返。
    ///
    /// 命中测试是逐个 IPC，始终在后台线程做，不卡主线程。
    func scheduleMenuHarvest(_ appEl: AXUIElement, screenFrames: [NSRect], primaryH: CGFloat) {
        let now = CACurrentMediaTime()
        let wl = Self.menuWindowList(screenFrames: screenFrames, primaryH: primaryH)
        let windows = wl.map { $0.rect }
        // 诊断：把判定为「菜单窗口」的窗口名/尺寸落盘，好确认有没有再把自己或系统浮层算进来。
        // 主线程算好后**按值**传给 harvestMenus（见 lastMenuWindowDesc 处注释：绝不再用静态变量共享）。
        let ownDesc = wl.map { "\($0.name):\(Int($0.rect.width))x\(Int($0.rect.height))" }
            .joined(separator: ",")
        let fp = Self.menuWindowFingerprint(windows)
        if fp != lastMenuWindowFP {
            lastMenuWindowFP = fp
            menuItems = []          // 旧菜单条目立即作废，绝不残留到新菜单上
            menuEmptyStreak = 0
            menuForced = true       // 跳过节流：切换菜单的瞬间用户在等译文
        }
        guard !menuBusy else { return }
        let interval: CFTimeInterval = windows.isEmpty ? 0.5 : 0.15
        guard menuForced || now - lastMenuHarvest > interval else { return }
        menuForced = false
        menuBusy = true
        lastMenuHarvest = now
        let t0 = CACurrentMediaTime()
        menuQueue.async { [weak self] in
            guard let self else { return }
            let r = Self.harvestMenus(appEl, menuWindows: windows,
                                      screenFrames: screenFrames, primaryH: primaryH,
                                      ownDesc: ownDesc)
            DispatchQueue.main.async {
                let ms = (CACurrentMediaTime() - t0) * 1000
                NSLog("[YiMu] harvest %.0fms raw=%d ok=%d keep=%d", ms, r.rawCount, r.ok ? 1 : 0, r.items.count)
                // —— 关键：单次「读失败」绝不清空已有条目 ——
                // 命中测试是逐条 IPC，偶发一轮全灭（鼠标正悬停在某项上 / AX 瞬时繁忙）非常常见。
                // 旧实现把这种空结果直接写进 menuItems，屏幕上的菜单译文就会整片消失，
                // 隔一两拍又回来 —— 正是用户报的「翻译的内容经常会自动消失」。
                if r.ok {
                    self.menuItems = r.items
                    self.menuItemsAt = CACurrentMediaTime()
                    self.menuEmptyStreak = 0
                } else {
                    self.menuEmptyStreak += 1
                    if self.menuEmptyStreak >= 3 {
                        self.menuItems = []
                        self.menuItemsAt = CACurrentMediaTime()
                    }
                }
                self.menuBusy = false
                Self.diagLog("MENUITEMS ok=\(r.ok) total=\(r.items.count) titles=\(r.items.filter { $0.menuBarTitle }.count) wins=\(windows.count)")
            }
        }
    }

    /// 所有弹出菜单窗口矩形的指纹（排序后拼接），用于察觉「菜单切换 / 新开 / 关闭」。
    private static func menuWindowFingerprint(_ frames: [NSRect]) -> String {
        frames.map { "\(Int($0.origin.x.rounded())),\(Int($0.origin.y.rounded())),\(Int($0.width.rounded())),\(Int($0.height.rounded()))" }
            .sorted().joined(separator: "|")
    }

    /// 采集菜单栏 + 各级子菜单的条目，用命中测试过滤掉关闭菜单的幻影条目。
    ///
    /// 返回 `ok`：false 表示**这一轮没读成功**（而不是"屏幕上确实没有菜单"）。
    /// 调用方据此决定是更新还是保留上一轮结果 —— 这是「译文不再自动消失」的关键约定。
    private static func harvestMenus(_ appEl: AXUIElement,
                                     menuWindows: [NSRect],
                                     screenFrames: [NSRect],
                                     primaryH: CGFloat,
                                     ownDesc: String) -> (items: [CapturedText], ok: Bool, rawCount: Int) {
        var mbRef: CFTypeRef?
        let mbReadOK = AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &mbRef) == .success
        // 没有菜单栏的 app（少数自绘 UI / 辅助进程）也要能采应用内弹出菜单，故此处不提前返回失败。
        // 不裸 `as!`：AX 返回 .success 但值为空 / 类型不符（目标 app 正在退出时会发生），
        // `as!` 会当场 trap，而这里是每秒数千次的遍历热路径，必须零崩溃面。
        // CF 类型**不能**用 `as?`（编译器判定"条件转换总是成功"而报错），
        // 故用 `CFGetTypeID` 做运行时类型校验——这才是 CoreFoundation 的标准安全转换写法。
        let mbEl: AXUIElement? = (mbReadOK && CFGetTypeID(mbRef) == AXUIElementGetTypeID())
            ? (mbRef as! AXUIElement) : nil

        var mbItems: [CapturedText] = []
        if let mbEl {
            traverseRec(element: mbEl, depth: 0, maxDepth: 5,
                        results: &mbItems, maxCount: 400,
                        skipMenus: false, tagMenu: true,
                        screenFrames: screenFrames, primaryH: primaryH)
        }

        // —— 应用内弹出菜单采集（2026-10-13，新增）——
        // 菜单栏下拉菜单走上面的 AXMenuBar 子树；但**窗口里弹出的应用内菜单**
        // （工具栏弹出列表 / combo box 列表 / 右键菜单 / 段落元素选择器等）
        // 是挂在**窗口树**上的 AXMenu / AXMenuItem：
        //   ① 窗口扫描（scanFrontmostText）为防重复，遇到菜单角色整棵砍掉（skipMenus=true）；
        //   ② 它又不在菜单栏子树里，harvestMenus 也遍历不到。
        // 两路都够不着 → 用户看到「菜单栏下拉菜单翻译了，窗口内的下拉菜单完全没翻译」。
        // 这里从 app 根单独遍历菜单角色（跳过菜单栏分支避免重复），结果统一交给下面的
        // 菜单过滤链（菜单窗口 containment + 命中测试 / 幻影簇抑制）裁决。
        var popupRaw: [CapturedText] = []
        Self.collectPopupMenus(element: appEl, depth: 0, maxDepth: 10,
                               results: &popupRaw, maxCount: 60,
                               screenFrames: screenFrames, primaryH: primaryH)
        let popupCount = popupRaw.count

        guard !mbItems.isEmpty || !popupRaw.isEmpty else { return ([], false, 0) }

        // —— 弹出菜单窗口预过滤 ——
        // AXMenuBar 子树会把**没打开的菜单**条目也全部吐出来（假坐标），条目总量轻松超过
        // 采集上限 → 正打开的下拉菜单排在后面被截断（「下拉菜单好多条目不翻译」的根因之一）。
        // 真正打开的菜单/子菜单都是屏幕上层号 ≥ 101（kCGPopUpMenuWindowLevel）的窗口；
        // 不在这些窗口矩形里的下拉条目直接丢弃，既修截断、又把海量幻影挡在昂贵的命中测试之前。
        mbItems = mbItems.filter { item in
            if item.menuBarTitle { return true }   // 菜单栏标题只有十来个，全保留
            for w in menuWindows where w.contains(NSPoint(x: item.rect.midX, y: item.rect.midY)) {
                // 仅判「中心点在窗口内」会被过期条目蒙混过关（2026-10-12 左缘幻影根因）：
                // 已关闭菜单的条目 AX 仍报上一次打开时的假坐标（实测 Product 菜单关闭后
                // Test Plan 仍报 (0,492)），中心点恰好蹭进正开菜单窗口的左上角 → 过了过滤，
                // 再赶上命中率兜底整批放行 → 幻影译文漏到屏幕左缘。
                // 故要求条目**整体**落在窗口内（左右缘各 10pt 容差；真菜单行必然整行在面板内）。
                let tol: CGFloat = 10
                if item.rect.minX >= w.minX - tol && item.rect.maxX <= w.maxX + tol {
                    return true
                }
            }
            return false
        }
        // —— 应用内弹出菜单兜底（2026-10-13）——
        // 有菜单窗口、却一条下拉项都没落在窗口内 → 旧逻辑直接判「读失败」（保留上一轮结果）。
        // 但实测（Final Draft 13 工具栏的「Scene Heading」弹出菜单）正是这种情况：
        // CGWindowList 里确实检测到菜单窗口（日志 wins=1），但 AX 报出的条目坐标整体落在它之外
        // —— 这类「应用内弹出菜单」未必以「层号 ≥101 的独立窗口」形式出现（app 自绘弹层 / 子窗口），
        // 窗口矩形对它们不可信，于是这个菜单一个词都不翻译（用户报「窗口里突然出现的下拉菜单没被翻译」）。
        // 现在改为：把候选条目交回**命中测试**裁决 —— 命中测试是权威的
        // 「此刻该坐标最上层元素就是这个文本」，截前 80 条以约束逐条 IPC 的成本；
        // 幻影条目会在命中测试与幻影簇抑制两关被滤掉。
        var containmentMissed = false
        if !menuWindows.isEmpty && !mbItems.contains(where: { !$0.menuBarTitle }) {
            let nonTitle = mbItems.filter { !$0.menuBarTitle }
            if !nonTitle.isEmpty {
                mbItems = mbItems.filter { $0.menuBarTitle } + Array(nonTitle.prefix(80))
                containmentMissed = true
                // 诊断只记角色与矩形，**不含任何菜单文字**（隐私）。
                let sample = nonTitle.prefix(5).map {
                    "\($0.axRole)@\(Int($0.rect.minX)),\(Int($0.rect.minY)) "
                        + "\(Int($0.rect.width))x\(Int($0.rect.height))"
                }.joined(separator: " | ")
                Self.diagLog("CONTAIN_MISS n=\(nonTitle.count) cand=[\(sample)]")
            } else if popupRaw.isEmpty {
                // 菜单栏分支一条下拉项都没有、又没有应用内弹出菜单 → 是否判「读失败」，
                // **取决于菜单栏标题还在不在**（2026-10-13 修「抖动厉害」的根因）：
                // 旧代码这里无条件 `return ([], false, 0)`，连已经采到的 12 个菜单栏标题
                // 一起丢掉。实测证据：正常帧 26 项 = 12 标题 + 14 窗口项，每隔约 2.4s
                // 穿插一帧 `PIPE in=14`（标题批整批消失），下一帧又回来 ——
                // 调用方收到这帧后，items 条数从 26 掉到 14，渲染层按下标复用的
                // 「内容未变则不重排」判定全面失效 → 全盘重排 → 菜单栏整行闪一下。
                // 标题还在就说明菜单栏读到了（只是此刻没有打开的下拉菜单），应正常返回。
                if !mbItems.contains(where: { $0.menuBarTitle }) {
                    return ([], false, 0)
                }
            }
        }
        let rawCount = mbItems.count + popupCount

        // —— 菜单坐标校准（必须在命中测试**之前**做）——
        // Tahoe 下 AX 菜单矩形系统性偏移一行；若先做命中测试，测试点落在偏移后的
        // 位置上必然打不到对应元素 → 全部菜单条目被当幻影滤掉（「菜单一个都不翻译」的根因）。
        // 校准策略（确定性锚定，不再依赖平均偏移）：
        // ① 菜单栏标题：macOS 菜单栏文字**永远垂直居中于菜单栏**——把每个标题矩形
        //    逐个强制居中到真实菜单栏（mbRect）内，一锤定音修掉「上下没挡住」。
        // ② 下拉项：用标题的实测偏移 delta（标题应居中的位置 − AX 实测位置）整体平移。
        // 校准只作用于菜单栏分支：应用内弹出菜单不走这段（偏移修正是针对菜单栏的，
        // 套到普通窗口树里的菜单项上会把它推歪）。
        if let mbEl, let mbRect = elementGlobalRect(mbEl, primaryH: primaryH) {
            let titles = mbItems.filter { $0.menuBarTitle }
            if !titles.isEmpty {
                let titleMidY = titles.map { $0.rect.midY }.reduce(0, +) / CGFloat(titles.count)
                let expectedCenter = primaryH - mbRect.height / 2
                let delta = expectedCenter - titleMidY
                let hasOffset = delta.magnitude > 1 && delta.magnitude < 60
                let menuBarTop = primaryH - mbRect.height
                mbItems = mbItems.map { item in
                    if item.menuBarTitle {
                        // 逐标题锚定：垂直居中于真实菜单栏（无论 AX 给的 y 偏到哪）
                        let targetMid = menuBarTop + mbRect.height / 2
                        return item.shifted(dy: targetMid - item.rect.midY)
                    }
                    // 下拉项：按标题实测偏移整体平移（无显著偏移则不动）
                    return hasOffset ? item.shifted(dy: delta) : item
                }
            }
        }

        // 再按（已校准的）坐标做命中测试校验，滤掉关闭菜单的幻影条目。
        var validated = mbItems.filter { isTextVisible($0.text, at: $0.rect, primaryH: primaryH) }
        // —— 自适应兜底 ——
        // 命中测试的判据很严（该点最上层元素文本必须与目标**完全相等**），一旦发生
        // 系统性偏移就会整批误杀，表现为「菜单一个都不翻译 / 整片译文凭空消失」。
        // 判据：条目够多却通过率 < 60% → 判定为偏移误杀，改信「弹出菜单窗口过滤」的结果。
        // 幻影的主要来源（关闭菜单的假坐标）已由窗口矩形过滤挡住，此兜底风险可控，
        // 收益是菜单不会再整片失踪。
        let hitCount = validated.count
        var fallback = false
        // 兜底只在「确实有菜单窗口」时才放开，且放开的仍是经过窗口矩形过滤的集合：
        // 幻影之所以能漏到屏幕上，正是因为窗口过滤被自己/系统浮层污染了 —— 一旦过滤正确，
        // raw 里剩下的基本就是真菜单条目；没有菜单窗口时绝不整批放行。
        // 注意：containmentMissed 时**不放开**整批 —— 那种情况下 raw 里剩下的恰好是
        // 「没落在任何菜单窗口内」的候选项（可能就是关闭菜单的幻影），只信命中测试的结果。
        if !containmentMissed, !menuWindows.isEmpty,
           mbItems.count >= 3, validated.count * 10 < mbItems.count * 6 {
            validated = mbItems
            fallback = true
        }

        // 幻影簇抑制：放在最后一道，兜住窗口过滤与命中测试都没拦住的情况。
        // 只作用于**菜单栏分支**——簇抑制按 64pt 网格分桶、桶内超过 5 条就整桶丢弃，
        // 一个真正打开的应用内菜单（窄面板 × 多行）很容易同格超过 5 条而被误杀。
        let beforeCluster = validated.count
        validated = dropPhantomClusters(validated)

        // —— 应用内弹出菜单：只信命中测试，不做整批兜底 ——
        // 为什么：这类菜单的坐标来自普通窗口树（不像菜单栏那样存在系统性的整行偏移），
        // 命中率低就意味着大部分候选项是「已关闭菜单残留在树里的幻影条目」
        // ——宁可少翻，也绝不能把幻影译文放上屏（历史上整批兜底放过一次满屏幻影）。
        // wins 为空时（app 自绘弹层在 CGWindowList 里不算菜单窗口）同样由命中测试裁决。
        var popupHitCount = 0
        if popupCount > 0 {
            let candidates = menuWindows.isEmpty
                ? popupRaw
                : popupRaw.filter { Self.withinAnyMenuWindow($0, menuWindows) }
            // containment 全滤空但本身有候选 → 窗口矩形对这类弹层不可信，交命中测试裁决
            let pool = candidates.isEmpty ? popupRaw : candidates
            let hit = pool.filter { isTextVisible($0.text, at: $0.rect, primaryH: primaryH) }
            popupHitCount = hit.count
            validated.append(contentsOf: hit)
            Self.diagLog("POPUP_MENU cand=\(candidates.count) pool=\(pool.count) hit=\(hit.count)")
        }

        let winsStr = menuWindows
            .map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width))x\(Int($0.height))" }
            .joined(separator: " ")
        Self.diagLog("harvest raw=\(rawCount) wins=[\(winsStr)] own=[\(ownDesc)] "
                     + "hit=\(hitCount) fb=\(fallback ? 1 : 0) cm=\(containmentMissed ? 1 : 0) "
                     + "cluster=\(beforeCluster - validated.count) pm=\(popupHitCount) "
                     + "final=\(validated.count)")
        // 记录"泄漏到屏幕下半部"的条目数量与位置（幻影的典型特征），用于确认根因。
        // 只记数量与矩形，**不记文本**（隐私：日志里不落屏幕内容）。
        let low = validated.filter { !$0.menuBarTitle && $0.rect.midY < primaryH * 0.45 }
        if !low.isEmpty {
            let d = low.prefix(6)
                .map { "\(Int($0.rect.minX)),\(Int($0.rect.minY))" }
                .joined(separator: " | ")
            Self.diagLog("LOW n=\(low.count) [\(d)]")
        }
        return (validated, true, rawCount)
    }

    /// 当前是否有打开的弹出菜单/子菜单。用于给菜单采集与 AX 轮询定节拍。
    /// internal：CaptureEngine 需要据此在「菜单打开时」把整条链路提速。
    static func hasOpenMenuWindow() -> Bool {
        !menuWindowList(screenFrames: NSScreen.screens.map { $0.frame },
                        primaryH: Self.primaryDisplayHeight()).isEmpty
    }

    /// 屏幕上所有「弹出菜单窗口」（层号 ≥ 101，即 kCGPopUpMenuWindowLevel 及以上）的 AppKit 矩形。
    /// CG 窗口 bounds 与 AX position 同处 Quartz 全局坐标系（原点左上、Y 向下），换算基准一致。
    ///
    /// **必须过滤掉「不是菜单却挂在高层级」的窗口**（2026-10-12 修复，根因在实测日志里）：
    /// 关闭过的菜单窗口并不总是立刻从 CGWindowList 消失——它可能以 alpha≈0 留在列表里，
    /// 而它的矩形正是「菜单关闭时停在的那个位置」（常见于屏幕左缘/左下角）。
    /// 一旦把它当成"打开的菜单窗口"，关闭菜单的幻影条目就能靠"落在窗口内"通过过滤，
    /// 于是屏幕左下方堆出一大片不属于当前菜单的译文块。
    ///
    /// **更要命的是 App 自己的窗口**（2026-10-12 二次修复，实测确认）：
    /// 译幕的悬浮层本身就是「全屏 + 层级 2147483628」的窗口，必然满足 layer ≥ 101。
    /// 把它当成菜单窗口 → 它的矩形覆盖整块屏幕 → **每一条幻影都能通过"落在菜单窗口内"**，
    /// 前面所有过滤形同虚设。所以这里必须排除自身进程铺满屏幕的窗口。
    /// 真正的「弹出菜单窗口」：层号在菜单区间内、可见、尺寸像面板，
    /// 且**不是本 App 自己**、**不铺满整块屏幕**。返回矩形与窗口名（仅用于诊断）。
    /// （internal 级：目前供诊断与未来菜单级渲染复用；取色快照逻辑已移除，
    /// 译文块统一改为白色半透明毛玻璃，不再依赖此函数。）
    static func menuWindowList(screenFrames: [NSRect], primaryH: CGFloat) -> [(rect: NSRect, name: String)] {
        let list = Self.windowListSnapshot()
        let myPid = ProcessInfo.processInfo.processIdentifier
        var out: [(NSRect, String)] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int else { continue }
            // ① 层号区间：菜单面板（kCGPopUpMenuWindowLevel = 101）及其子菜单。
            //    上端封顶排除系统悬浮窗（实测「无障碍服务 hoverTextWindow」= 3002）
            //    以及任何把自己顶到极高层（214748xxxx）的常驻浮层。
            guard layer >= 101, layer <= 1000 else { continue }
            // ② 本 App 自己的窗口一律不算（悬浮层 / 控制条都是高层级）
            let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
            guard pid != myPid else { continue }
            // ③ 不可见窗口（alpha 极低）不算菜单窗口
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }
            // ④ 状态栏小图标（StatusIndicator，28×28）同样是 layer ≥ 101，不能当菜单面板
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let bx = b["X"], let by = b["Y"],
                  let bw = b["Width"], let bh = b["Height"],
                  bw >= 60, bh >= 20 else { continue }
            // ⑤ 铺满整块屏幕的窗口绝不是菜单面板（全屏浮层 / 壁纸 / 屏保）
            let coversScreen = screenFrames.contains {
                bw >= $0.width * 0.95 && bh >= $0.height * 0.95
            }
            guard !coversScreen else { continue }
            let appKitY = primaryH - by - bh
            let name = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            out.append((NSRect(x: bx, y: appKitY, width: bw, height: bh), name))
        }
        return out
    }

    /// 幻影簇抑制：关闭菜单的条目在 Tahoe 下会报出「停在屏幕某处」的假坐标，
    /// 不同菜单的一堆条目会叠在同一小片区域（实测就是屏幕左缘/左下角那一片）。
    /// 真菜单是**纵向等距排列**（行距约 20pt），任何 64×64 的格子里最多也就 3~4 条；
    /// 一格塞进 6 条以上，只可能是幻影。规则：整格丢弃（标题豁免）。
    private static func dropPhantomClusters(_ items: [CapturedText],
                                            grid: CGFloat = 64, limit: Int = 5) -> [CapturedText] {
        let popup = items.indices.filter { !items[$0].menuBarTitle }
        guard popup.count > limit else { return items }
        var buckets: [String: [Int]] = [:]
        for i in popup {
            let r = items[i].rect
            let key = "\(Int((r.midX / grid).rounded(.down)))_\(Int((r.midY / grid).rounded(.down)))"
            buckets[key, default: []].append(i)
        }
        var drop = Set<Int>()
        for (_, members) in buckets where members.count > limit { drop.formUnion(members) }
        guard !drop.isEmpty else { return items }
        return items.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }

    /// 诊断落盘（临时）：追加一行到 /tmp/yimu_diag.log。
    /// 为什么不用 NSLog：本机 `log stream` 在本会话 shell 里起不来（zsh watch 模块报错），
    /// 诊断必须能可靠拿到。每行追加写、不重写整个文件，开销可忽略。
    /// 只记计数、矩形与文本前缀（≤12 字），不落整屏文本；验收后整块删除。
    static func diagLog(_ s: String) {
        let line = String(format: "%.2f %@\n", Date().timeIntervalSince1970, s)
        guard let data = line.data(using: .utf8) else { return }
        // 隐私红线（2026-10-13 收口）：不再写 `/tmp`（全局可读）。
        // 本日志不含屏幕文本（只有计数 / 矩形 / 字符数），但仍含用户正在用哪个 app、
        // 因此一并迁到 0700 目录、以 0600 创建。验收后连同整个函数一起删。
        guard let dir = AppDelegate.privacySafeLogDir() else { return }
        let path = dir.appendingPathComponent("diag.log").path
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

    // MARK: - 递归遍历

    private static func traverseRec(element: AXUIElement, depth: Int, maxDepth: Int,
                                    results: inout [CapturedText], maxCount: Int,
                                    skipMenus: Bool, tagMenu: Bool,
                                    screenFrames: [NSRect], primaryH: CGFloat,
                                    noRectRun: Int = 0, inControl: Bool = false,
                                    inToolbar: Bool = false) {
        guard depth <= maxDepth, results.count < maxCount else { return }
        // 角色只取一次，后面三个判定全部复用——省掉每个元素 3 次多余的跨进程 IPC。
        let role = Self.roleOf(element)
        if skipMenus, Self.isMenuRole(role) { return }   // 菜单子树交给 harvestMenus 单独处理
        if Self.isIconRole(role) { return }   // 桌面 / 文件图标（AXIcon）不进默认扫描：默认不翻译桌面上文件
        // 是否「控件内文字」：自身是控件，或祖先是控件（如 AXButton 里的 AXStaticText）。
        // 用于行内合并判定——控件标签必须独立成块，绝不与相邻按钮拼成一句。
        let isCtrl = inControl || Self.isControlRole(role)

        // —— 矩形无效时「不收录，但继续向下遍历」（2026-10-12 重大修复）——
        // 旧逻辑是「矩形无效就 return」，结果**整棵子树被砍掉**。实测证据（独立探针）：
        // Final Draft 13 的根节点 AXApplication **根本没有 position/size**
        // （pos=false size=false），旧逻辑在根上直接返回 → 全树 908 个元素、
        // 726 个带标题的界面文字（窗口标题、工具栏、状态栏、剧本区）一条都收不到，
        // 表现就是融合态「窗口及窗口内容完全没翻译」，而菜单因走 harvestMenus
        // （从 AXMenuBar 起遍历，它有 2048x30 的矩形）不受影响 → 只有菜单翻译正常。
        // 现在：无矩形只跳过收录；收录仍要求矩形有效，故不会引入无坐标的垃圾块。
        // noRectRun 限制「连续无矩形」层数 ≤2，避免穿透隐藏/幻影子树无限下钻。
        let rect = elementGlobalRect(element, primaryH: primaryH)
        let usable = rect.map { isValidRect($0, screenFrames: screenFrames) } ?? false
        if depth == 0, !usable {
            Self.diagLog("ROOT_NO_RECT skipMenus=\(skipMenus ? 1 : 0) — 根节点无矩形，旧逻辑会砍掉整棵树")
        }
        guard usable || noRectRun < 2 else { return }

        // —— 临时诊断（2026-10-13，「Split / Views 没翻译」定位用，验收后整块删除）——
        // 只记：角色 / 属性**字符数** / 矩形 / 各闸判定 / 是否真的收录。**不记任何文本**（隐私红线）。
        // 窗口内容路径专用（!tagMenu）；菜单栏与下拉菜单采集路径一字不动。
        let probeBefore = results.count

        // 元素文字：title / value 优先（`elementText`）。两者都空时，**窗口内容路径**允许回退到
        // AXDescription ——前提是过得了 `visibleDescLabel` 的几道闸（见其注释）。
        // 只在真的空的时候才去读 description：省掉每个元素一次多余的跨进程 IPC。
        var elementLabel: String? = usable ? elementText(element) : nil
        if usable, !tagMenu, (elementLabel?.isEmpty ?? true), let r0 = rect {
            elementLabel = Self.visibleDescLabel(element, role: role, rect: r0)
        }

        if usable, let r = rect, let text = elementLabel, !text.isEmpty,
           !Self.isShellContainer(role), !Self.dropAsIcon(r, inToolbar: inToolbar) {
            // —— 「双行控件」：同一控件上第二行可见文字（AXDescription）——
            // 实测 Final Draft 13 工具栏的段落元素按钮：AXValue = 当前值「General」（画在按钮上半）、
            // AXDescription = 按钮名「Elements」（画在按钮下半），两行**都可见**。
            // 而 elementText 只取 title/value（刻意不取 description，防容器占位文案），
            // 于是下半那行永远采不到 → 用户看到「上下都有英文，只翻译了上面的」。
            // 这里把它补成两个独立条目（上半 / 下半各一条），各自翻译、各自贴合原文渲染。
            // 仅窗口内容扫描生效（!tagMenu）——菜单栏与下拉菜单路径不受任何影响。
            if !tagMenu, let two = Self.twoLineLabel(element, role: role, value: text, rect: r) {
                results.append(CapturedText(id: UUID(), text: text, rect: two.upper,
                                            source: .ax, isMenu: false, menuBarTitle: false,
                                            axRole: role ?? "", isControl: true))
                results.append(CapturedText(id: UUID(), text: two.label, rect: two.lower,
                                            source: .ax, isMenu: false, menuBarTitle: false,
                                            axRole: role ?? "", isControl: true))
            } else {
                results.append(CapturedText(id: UUID(), text: text, rect: r,
                                            source: .ax, isMenu: tagMenu,
                                            menuBarTitle: tagMenu && depth == 1,
                                            axRole: role ?? "", isControl: isCtrl))
            }
        }

        if usable, !tagMenu, let r0 = rect, Self.isCtrlProbeCandidate(role: role, rect: r0) {
            Self.probeCtrl(element, role: role, rect: r0, used: results.count > probeBefore)
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            let nextNoRect = usable ? 0 : noRectRun + 1
            for child in children {
                traverseRec(element: child, depth: depth + 1, maxDepth: maxDepth,
                            results: &results, maxCount: maxCount,
                            skipMenus: skipMenus, tagMenu: tagMenu,
                            screenFrames: screenFrames, primaryH: primaryH,
                            noRectRun: nextNoRect, inControl: isCtrl,
                            inToolbar: inToolbar || role == "AXToolbar")
            }
        }
    }

    /// 「双行控件」的第二行可见文字（AXDescription）。
    ///
    /// 背景（2026-10-13 实测 Final Draft 13，探针 axprobe5/6）：
    /// 工具栏段落元素按钮的 AX 属性是 `AXValue="General"` + `AXDescription="Elements"`，
    /// 按钮 129x42 内**两行都画在屏幕上**：上半是当前值、下半是按钮名。
    /// `elementText` 刻意不读 description（防止把无标题容器填成「菜单选项」这类占位文案），
    /// 所以下半那行永远采不到 → 用户报「上下都有英文，但只翻译了上面的」。
    ///
    /// 判据收紧到只认真正的双行控件，避免误伤（实测同一工具栏上的反例全部被挡掉）：
    ///   ① 必须是具体控件角色（按钮 / 弹出按钮 / 复选框…）；
    ///   ② `AXTitle` 必须为空——有 title 的控件（如 `AXButton "Title Page"` + `description "Title Page"`）
    ///      description 只是 title 的重复，不是第二行；
    ///   ③ `AXValue` 必须非空——只有 description 的图标按钮（`AXButton` d="Dictation" / "Search"、
    ///      `AXCheckBox` d="Focus Mode"）其 description 是**无障碍说明、屏幕上不可见**，必须排除；
    ///   ④ description 与 value、与 roleDescription 都不同；
    ///   ⑤ 矩形高度 ≥ 30pt——装得下两行文字（反例 `AXPopUpButton v="100%" d="Zoom the view"` 仅 47x20，
    ///      是缩放控件的说明文字，高度就把它挡掉了）。
    ///
    /// 返回「上半矩形（value）+ 下半矩形（description）+ 第二行文本」；不构成双行时返回 nil。
    private static func twoLineLabel(_ element: AXUIElement, role: String?, value: String,
                                     rect: NSRect) -> (upper: NSRect, lower: NSRect, label: String)? {
        guard let role, Self.isControlRole(role) else { return nil }
        // ② title 必须为空
        var tRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &tRef) == .success,
           let t = tRef as? String,
           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        // ⑤ 高度够放两行
        guard rect.height >= 30, rect.width >= 20 else { return nil }
        // ③④ description 非空、与 value / roleDescription 均不同
        var dRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &dRef) == .success,
              let d = (dRef as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !d.isEmpty, d != value else { return nil }
        var rdRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &rdRef) == .success,
           let rd = rdRef as? String, rd == d { return nil }
        let half = (rect.height / 2).rounded()
        let lower = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: half)
        let upper = NSRect(x: rect.minX, y: rect.minY + half,
                           width: rect.width, height: rect.height - half)
        return (upper, lower, d)
    }

    /// 控件角色：这些角色的文字是**控件自身的标签/标题**，不是正文内容。
    /// 行内合并必须跳过它们——否则并排按钮的标签会被拼成一句（实测：
    /// Final Draft 工具栏 Split / Views / Beat Board → 「分割视图节拍板」一个横跨三键的块）。
    private static func isControlRole(_ role: String?) -> Bool {
        guard let role else { return false }
        switch role {
        case "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
             "AXComboBox", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
             "AXSegmentedControl", "AXToolbarButton", "AXToggle", "AXSearchField":
            return true
        default:
            return false
        }
    }

    /// 菜单相关的角色（菜单栏 / 菜单 / 菜单项）。
    private static func isMenuRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXMenuBar" || role == "AXMenu" || role == "AXMenuItem"
    }

    /// 应用内弹出菜单采集（2026-10-13 新增）。
    ///
    /// 背景（用户报「窗口内的下拉菜单没被翻译」）：这类菜单挂在**窗口树**上，于是两头不靠——
    ///   ① 窗口扫描 `scanFrontmostText` 传 `skipMenus: true`，遇菜单角色整棵砍掉（防与菜单栏重复）；
    ///   ② 它又不在 AXMenuBar 子树里，`harvestMenus` 遍历不到。
    ///
    /// 实现要点：
    /// - 沿窗口树只找 **AXMenu / AXMenuItem**；遇到菜单栏分支（AXMenuBar / AXMenuBarItem）返回，
    ///   避免与菜单栏那条已验证的路径重复。
    /// - 关闭状态的菜单同样留在这棵树里（幻影的主要来源），所以只收录**矩形有效且在屏幕内**
    ///   的条目，再由调用方统一交给「菜单窗口 containment + 命中测试」裁决，不在此处自行放行。
    /// - 独立于 `traverseRec`：窗口扫描与菜单栏采集两条已验证路径均不受影响。
    private static func collectPopupMenus(element: AXUIElement, depth: Int, maxDepth: Int,
                                          results: inout [CapturedText], maxCount: Int,
                                          screenFrames: [NSRect], primaryH: CGFloat) {
        guard depth <= maxDepth, results.count < maxCount else { return }
        let role = Self.roleOf(element)
        if let role, (role == "AXMenuBar" || role == "AXMenuBarItem") { return }
        if let role, (role == "AXMenu" || role == "AXMenuItem"),
           let r = Self.elementGlobalRect(element, primaryH: primaryH),
           Self.isValidRect(r, screenFrames: screenFrames),
           let text = Self.elementText(element), !text.isEmpty {
            results.append(CapturedText(id: UUID(), text: text, rect: r,
                                        source: .ax, isMenu: true, menuBarTitle: false,
                                        axRole: role, isControl: false))
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectPopupMenus(element: child, depth: depth + 1, maxDepth: maxDepth,
                                  results: &results, maxCount: maxCount,
                                  screenFrames: screenFrames, primaryH: primaryH)
            }
        }
    }

    /// 条目是否**整体**落在任一弹出菜单窗口内（与菜单栏下拉项同口径的 containment 判据）。
    private static func withinAnyMenuWindow(_ item: CapturedText, _ windows: [NSRect]) -> Bool {
        let tol: CGFloat = 10
        for w in windows where w.contains(NSPoint(x: item.rect.midX, y: item.rect.midY)) {
            if item.rect.minX >= w.minX - tol, item.rect.maxX <= w.maxX + tol { return true }
        }
        return false
    }

    /// 图标角色（桌面文件 / app 图标 / 网页图片）：默认扫描里直接跳过整棵子树。
    /// - `AXIcon`：这样「桌面上文件」默认不会被翻译（用户此前的需求）。
    /// - `AXImage`（2026-10-13 新增）：**网页图标**。它的「文字」来自 aria-label
    ///   （如 "Search" / "IMDb Logo" / "Watchlist"），**屏幕上根本没画出这些字**；
    ///   此前被当正文翻译并画成块（实测 role=AXImage 64×64、21 字符 → 170×64 的块），
    ///   即用户报的「网页上的一些图标也会被翻译出来」。
    /// Control 悬停翻译走独立的 textAtPoint，不经过此过滤，故桌面文件 / 图片仍可被悬停翻译。
    private static func isIconRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXIcon" || role == "AXImage"
    }

    /// 近似正方形的「图标按钮」：不收录它自身的文字（aria-label），但**继续向下遍历**——
    /// 按钮里若真有 AXStaticText 文字节点，仍会被正常收录。
    /// 为什么需要它：网页/工具栏上的图标按钮角色常是 AXButton（不是 AXImage），
    /// 走不到 isIconRole 那一闸，可它的文字同样是给读屏用的替代文本，屏幕上没有。
    /// 判据：外接边长 ≤ 80pt 且宽高差 ≤ max(6, 边长×25%) —— 真正的文字块几乎不会这么方。
    private static func isSquareIcon(rect: NSRect) -> Bool {
        let side = max(rect.width, rect.height)
        guard side <= 80 else { return false }
        return abs(rect.width - rect.height) <= max(6, side * 0.25)
    }

    /// 是否要把一个元素当成「图标按钮」、丢弃它的文字（判据见 `isSquareIcon`）。
    ///
    /// **原生工具栏（AXToolbar）子树内不套用这条判据**（2026-10-13 用户拍板方案 A）：
    /// 工具栏按钮的排版是「图标在上、短标签在下」，标签越短按钮越窄——实测 Final Draft 13
    /// Split / Views 两个 `AXMenuButton` 只有 54×42（Δ=12 ≤ 边长×25%=13.5），被判成方形图标，
    /// 文字不收录 → 用户看到「整排都翻了，偏偏这两个没翻」；同排标签 ≥8 字母的按钮（宽 65–84）
    /// Δ 远超阈值，所以全都正常。
    /// 用 **AX 语义**（祖先是不是 AXToolbar）而不是再调尺寸阈值来区分，换 app 也不会翻车：
    /// 网页里没有 AXToolbar 节点，10-13 修的「网页图标按钮 aria-label 被翻译成块」不会回退；
    /// 而原生工具栏里纯图标按钮（实测 26×26、`AXTitle`/`AXValue` 均为空、只有 description）
    /// 本来就拿不到 `elementText`，不受此次改动影响。
    private static func dropAsIcon(_ rect: NSRect, inToolbar: Bool) -> Bool {
        !inToolbar && isSquareIcon(rect: rect)
    }

    /// 「只有 AXDescription、没有 title / value」的控件，屏幕上到底有没有字？
    ///
    /// 背景（2026-10-13 用户报 Xcode 欢迎窗 `Open…` / `Clone…` 不翻译，探针 AXCTRL 实证）：
    /// 这两个按钮是 `AXButton t="" v="" d="Open…"` 107×36 —— **可见标签只挂在 description 上**；
    /// 而 `elementText` 刻意不读 description（防图标按钮的读屏说明变成怪块），于是整条漏掉，
    /// 同排有 title 的 `New Project`（t=11）却翻得好好的。
    ///
    /// 这里补一条**带闸门的回退**，下列条件缺一不可：
    ///   ① 角色是具体控件（按钮类…），且 description 与 roleDescription 不同 ——
    ///      挡掉「按钮 / 菜单选项」这类角色名；
    ///   ② 形态必须**宽扁**（宽 ≥ 高 × 1.25）—— 方形 / 竖长的是图标按钮（实测 36×36、36×52
    ///      的纯图标按钮 description 就是读屏说明，屏幕上没有字），一律不认；
    ///   ③ description 要像**一个标签**：2–24 字符、含 ≥2 个字母、13pt 下一行放得下；
    ///   ④ 该控件内**没有带 title/value 的子孙** —— 有的话说明标签由子节点承载，
    ///      再收一条描述会造成同一处两块叠着。
    /// 仅窗口内容路径（!tagMenu）走这条；菜单栏 / 下拉菜单采集路径一字不动。
    private static func visibleDescLabel(_ element: AXUIElement, role: String?, rect: NSRect) -> String? {
        guard isControlRole(role) else { return nil }
        guard rect.width >= rect.height * 1.25 else { return nil }                       // ②
        guard let raw = stringAttr(element, kAXDescriptionAttribute) else { return nil }
        let d = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        if let rd = stringAttr(element, kAXRoleDescriptionAttribute), rd == d { return nil }  // ①
        guard d.count >= 2, d.count <= 24 else { return nil }                            // ③
        let letters = d.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2 else { return nil }
        let w = (d as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        guard w <= rect.width - 8 else { return nil }                                    // ③ 一行放得下
        guard !hasTextChild(element) else { return nil }                                 // ④
        return d
    }

    /// 该控件（限深 2 层）内是否存在带 title/value 文字的子节点。
    private static func hasTextChild(_ element: AXUIElement, depth: Int = 0) -> Bool {
        guard depth < 2 else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let children = ref as? [AXUIElement] else { return false }
        for c in children {
            if let t = elementText(c), !t.isEmpty { return true }
            if hasTextChild(c, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - 临时诊断：控件元素属性快照（「Split / Views 没翻译」定位用，验收后整块删除）

    /// 候选筛选：只盯**工具栏按钮尺寸**的控件（高 26–70、宽 26–220），
    /// 这类元素在整棵 AX 树里只有十几个，不会淹没日志，也不会触碰菜单路径。
    private static func isCtrlProbeCandidate(role: String?, rect: NSRect) -> Bool {
        guard isControlRole(role) else { return false }
        return rect.height >= 26 && rect.height <= 70 && rect.width >= 26 && rect.width <= 220
    }

    private static var probeBuf: [String] = []
    private static var probeBufAt: CFTimeInterval = 0
    private static var probeFlushAt: CFTimeInterval = 0

    /// 每 2 秒最多落一行；一行里最多 12 个控件。**只记字符数，不记文本**。
    private static func probeCtrl(_ element: AXUIElement, role: String?, rect: NSRect, used: Bool) {
        let now = CACurrentMediaTime()
        guard now - probeFlushAt > 2 else { return }
        let t = stringAttr(element, kAXTitleAttribute) ?? ""
        let v = stringAttr(element, kAXValueAttribute) ?? ""
        let d = stringAttr(element, kAXDescriptionAttribute) ?? ""
        guard !(t.isEmpty && v.isEmpty && d.isEmpty) else { return }
        let par = parent(of: element).flatMap { roleOf($0) } ?? "-"
        let entry = "role=\(role ?? "-") par=\(par) t=\(t.count) v=\(v.count) d=\(d.count) "
            + "sq=\(isSquareIcon(rect: rect) ? 1 : 0) shell=\(isShellContainer(role) ? 1 : 0) "
            + "used=\(used ? 1 : 0) r=[\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))]"
        if probeBuf.isEmpty { probeBufAt = now }
        probeBuf.append(entry)
        if probeBuf.count >= 12 || now - probeBufAt > 2 {
            diagLog("AXCTRL n=\(probeBuf.count) | " + probeBuf.joined(separator: " | "))
            probeBuf.removeAll()
            probeFlushAt = now
        }
    }

    /// 取任意 AX 字符串属性（诊断专用）。
    private static func stringAttr(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        return ref as? String
    }

    /// 结构性外壳角色：它们的 title 是「整片区域的名字」——窗口标题的矩形是**整个窗口**
    /// （实测 Final Draft 主窗口 870x1195），照它渲染会盖住整屏，属灾难性错误。
    /// 故**不收录**它们的文本，但**继续向下遍历**（真正的文字都在子节点里）。
    /// 只含纯外壳；AXTable/AXRow/AXCell/AXTextArea/AXOutline 等「承载内容」的角色不在此列，
    /// AXStaticText / AXButton / AXCheckBox / AXPopupButton 等具体控件也照常收录。
    private static func isShellContainer(_ role: String?) -> Bool {
        guard let role else { return false }
        switch role {
        case "AXApplication", "AXWindow", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem",
             "AXScrollArea", "AXGroup", "AXToolbar", "AXSheet", "AXDrawer",
             "AXPopover", "AXTabGroup":
            return true
        default:
            return false
        }
    }

    /// 有效矩形：有实际面积且与任一屏幕相交。
    private static func isValidRect(_ r: NSRect, screenFrames: [NSRect]) -> Bool {
        guard r.width >= 2, r.height >= 2 else { return false }
        return screenFrames.contains { $0.intersects(r) }
    }

    // MARK: - 命中测试（防幻影）

    /// 该屏幕位置最上层元素（或其祖先）是否正好是这段文字。
    /// 关闭的菜单条目在 AX 里会报出「停在屏幕上某处」的假坐标，靠这层校验全部滤掉。
    /// 多点采样：Tahoe 下 AX 矩形有系统性偏移，只测正中心一个点稍有偏差就把真条目
    /// 误杀成幻影（「下拉菜单好多条目没遮挡」的另一根因）。这里横向测「中心 + 左 1/4
    /// （菜单标题左对齐）」、纵向测「中心 + 上 6pt」，任一点命中即算可见。
    ///
    /// 采样点从 6 个降到 3 个：每次采样是一次跨进程 AX IPC，一个 30 项的下拉菜单
    /// 6 点就是 180 次 IPC —— 这正是「换到另一个菜单后要好一会儿才翻译出来」的主因。
    /// 坐标校准已消除大部分系统偏移，剩下的偏差交给 harvestMenus 的自适应兜底整体救回。
    private static func isTextVisible(_ text: String, at rect: NSRect, primaryH: CGFloat) -> Bool {
        let probes: [(CGFloat, CGFloat)] = [
            (rect.midX, rect.midY),
            (rect.minX + rect.width * 0.25, rect.midY),
            (rect.midX, rect.midY + 6),
        ]
        for (x, y) in probes where hitTextEquals(text, x: x, y: y, primaryH: primaryH) {
            return true
        }
        return false
    }

    /// 单点命中测试：该点最上层元素（向上最多 5 层）的文本是否正好等于 `text`。
    private static func hitTextEquals(_ text: String, x: CGFloat, y: CGFloat, primaryH: CGFloat) -> Bool {
        // AX 坐标原点在左上、Y 向下；rect 是 AppKit 坐标（原点左下）。
        let fx = Float(x)
        let fy = Float(primaryH - y)

        var hitRef: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(systemWide, fx, fy, &hitRef) == .success,
              let hit = hitRef else { return false }

        var cur: AXUIElement? = hit
        var level = 0
        while let e = cur, level < 5 {
            if let t = elementText(e), t == text { return true }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentRef {
                cur = CFGetTypeID(parentRef) == AXUIElementGetTypeID()
                    ? (parentRef as! AXUIElement) : nil   // 类型不符即当无父节点，绝不 trap
            } else {
                cur = nil
            }
            level += 1
        }
        return false
    }

    // MARK: - 指针取词（Control 悬停翻译用）

    /// 取「光标处所指的单词 / 句子」文本（AppKit 全局坐标，原点左下）。
    /// 用于按住 Control 键时「只翻译指针所指」——整屏其他文字都不翻，桌面文件也包含在内。
    /// 实现：AXUIElementCopyElementAtPosition 取光标下最深层元素，再向上最多 4 层
    /// 找文本，优先取更长（句子）但 ≤140 字的有意义文本；命中自身窗口则返回 nil。
    func textAtPoint(_ point: NSPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let primaryH = Self.primaryDisplayHeight()
        let x = Float(point.x)
        let y = Float(primaryH - point.y)
        let systemWide = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, x, y, &hitRef) == .success,
              let hit = hitRef else { return nil }
        // 命中自身窗口（翻译层/设置页）→ 不翻译
        if let pid = Self.elementPID(hit), pid == ProcessInfo.processInfo.processIdentifier { return nil }

        // 从命中元素向上爬，收集「矩形包含光标点」且文本有意义的元素；
        // 选其中矩形最小（最深、最具体）的——这样绝不会把光标落点附近的大容器
        // （如下载栈标题、整张卡片、整段 Web 区域）当成"光标处词"，
        // 避免「所有文件夹都显示下载 / 翻译太深」这类误读。
        var cur: AXUIElement? = hit
        var candidates: [(text: String, area: CGFloat)] = []
        for _ in 0..<8 {
            guard let e = cur else { break }
            let role = Self.roleOf(e)
            if role == "AXApplication" { break }
            if let r = role, !Self.shouldSkipText(r) {
                if let t = Self.elementText(e),
                   let trimmed = Optional.some(t.trimmingCharacters(in: .whitespacesAndNewlines)),
                   !trimmed.isEmpty, trimmed.count <= 140,
                   let rect = Self.elementGlobalRect(e, primaryH: primaryH),
                   rect.contains(point) {
                    candidates.append((trimmed, rect.width * rect.height))
                }
            }
            cur = Self.parent(of: e)
        }
        // 优先取「光标处、最小矩形」的元素（最具体的词）。
        if let best = candidates.min(by: { $0.area < $1.area }) {
            return best.text
        }
        // 兜底：光标直接命中容器非文字区（如链接留白 / 分组），向下找最近的可见文本节点，
        // 且要求该节点矩形包含光标点，否则丢弃（避免误取邻近文字）。
        if let d = Self.firstTextDescendantContaining(hit, point: point, primaryH: primaryH) {
            return d
        }
        return nil
    }

    /// AX 元素角色（用于 textAtPoint 的容器标题过滤）。
    private static func roleOf(_ element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return nil }
        return role
    }

    /// 取 AX 元素的父元素（AXParentAttribute），无则 nil。
    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let p = parentRef else { return nil }
        return CFGetTypeID(p) == AXUIElementGetTypeID() ? (p as! AXUIElement) : nil
    }

    /// 这些角色的「文本」是子节点聚合出来的（链接 accessibleName=目标页标题/描述、
    /// 分组/Web 区域=整块/整段、应用/窗口=标题、图片=alt 常是链接目的说明）。
    /// 指译只取光标处的真实文字，绝不读它们的聚合文本，否则「翻译太深」。
    private static func shouldSkipText(_ role: String) -> Bool {
        switch role {
        case "AXApplication", "AXWindow", "AXLink", "AXGroup", "AXWebArea",
             "AXScrollArea", "AXDiv", "AXRow", "AXCell", "AXTable", "AXColumn",
             "AXList", "AXLayoutArea", "AXLayoutItem", "AXSplitGroup", "AXTabGroup",
             "AXToolbar", "AXSheet", "AXDrawer", "AXPopover", "AXImage",
             "AXTextArea", "AXScrollBar", "AXBusyIndicator", "AXProgressIndicator",
             "AXSlider", "AXSwitch", "AXDisclosureTriangle", "AXOutline",
             "AXBrowser", "AXMap", "AXCanvas", "AXVideo":
            return true
        default:
            return false
        }
    }

    /// 向下找最近的文本节点（限深 3）：用于直接命中链接留白等容器、
    /// 向上爬不到文本时的兜底。只接受「矩形包含光标点」且非「聚合角色」的文本，
    /// 绝不会返回链接/分组等的 accessibleName，也不会误取光标旁的文字。
    private static func firstTextDescendantContaining(_ element: AXUIElement,
                                                      point: NSPoint,
                                                      primaryH: CGFloat,
                                                      depth: Int = 0) -> String? {
        guard depth <= 3 else { return nil }
        let role = Self.roleOf(element)
        if let r = role, !Self.shouldSkipText(r),
           let t = Self.elementText(element),
           let trimmed = Optional.some(t.trimmingCharacters(in: .whitespacesAndNewlines)),
           !trimmed.isEmpty,
           let rect = Self.elementGlobalRect(element, primaryH: primaryH),
           rect.contains(point) {
            return trimmed
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let t = Self.firstTextDescendantContaining(child, point: point, primaryH: primaryH, depth: depth + 1) {
                return t
            }
        }
        return nil
    }

    /// 取 AX 元素所属的进程 PID（用于判断是不是译幕自身）。
    private static func elementPID(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    // MARK: - 元素属性

    private static func elementText(_ element: AXUIElement) -> String? {
        // 只取真正的可见文本：标题 / 值。
        // 不回退到 kAXDescription / kAXRoleDescription——它们会把无标题的菜单、
        // 容器元素填成同一个占位文案（如「菜单选项」），造成大量重复垃圾块。
        let attrs: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXValueAttribute as CFString,
        ]
        for attr in attrs {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success, let ref else { continue }
            if let str = ref as? String, !str.isEmpty { return str }
            if let num = ref as? NSNumber { return num.stringValue }
        }
        return nil
    }

    /// AX 坐标为 Quartz（原点左上、Y 向下）→ 转 AppKit（原点左下、Y 向上）。
    /// 基准统一用「零号屏」（CG 坐标原点所在的主显示器）高度，避免多屏错位。
    private static func elementGlobalRect(_ element: AXUIElement, primaryH: CGFloat) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pos = posRef, let size = sizeRef else { return nil }

        var cgPoint = CGPoint.zero
        var cgSize = CGSize.zero
        // 同上：`CFGetTypeID` 运行时校验后再 `as!`。每个元素取矩形都要走这里，
        // 是整个采集链路调用最频繁的一行。
        guard CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(pos as! AXValue, .cgPoint, &cgPoint),
              AXValueGetValue(size as! AXValue, .cgSize, &cgSize) else { return nil }

        let appKitY = primaryH - cgPoint.y - cgSize.height
        return NSRect(x: cgPoint.x, y: appKitY, width: cgSize.width, height: cgSize.height)
    }

    /// 零号屏（带菜单栏、CG 坐标原点那块）的完整高度。
    static func primaryDisplayHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }
}
