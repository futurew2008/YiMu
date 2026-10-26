import AppKit
import Foundation

/// 取字引擎：协调 AX（常驻）与 OCR（按需兜底），合并去重后推给覆盖层。
///
/// 关键修复（对用户报告的 BUG）：
/// - **容差去重**：同文本 + 位置接近(≤16pt) 视为同一项，消除 AX 轮询亚像素抖动产生的重复块。
/// - **容差复用**：currentItems 按文本 + 位置(≤8pt)复用，译文稳定不抖、块不会无限堆积。
/// - **融合态纯 AX**：只译前台 app 的菜单栏 + 界面（不跑 OCR），桌面文件靠 AX 跳过
///   AXIcon 实现「默认不翻」，OCR 整屏跑会反把桌面文件名扫出来。OCR 仅镜头/区域态兜底。
final class CaptureEngine {
    static let shared = CaptureEngine()

    /// 最新一批捕捉结果推送给覆盖层。
    var onUpdate: (([CapturedText]) -> Void)?

    /// 当前捕获区域（AppKit 全局），由 AppDelegate 实时提供（窗口移动/缩放时随之更新）。
    var regionProvider: (() -> NSRect)?

    /// 目标语言是否为中文：决定「已是中文的文本直接跳过」这条过滤是否生效。
    /// 由 AppDelegate 在语言方向变化时同步写入（避免在采集回调里跨线程读 @MainActor 模型）。
    var targetIsChinese = true

    /// 抓屏 OCR 时应排除的窗口（本 app 的主覆盖窗口 + 融合态各分屏覆盖窗口），
    /// 避免把译文块二次识别造成反馈堆积。
    var excludeWindowIDs: [CGWindowID] = []

    private var axTimer: Timer?
    private var running = false
    private var paused = false
    private var mode: AppState = .settings
    private var latestAX: [CapturedText] = []
    private var latestOCR: [CapturedText] = []
    private var currentItems: [CapturedText] = []
    private var pending = Set<String>()
    /// 文本 → 已尝试翻译的次数（只对"仍在屏幕上"的文本保留，条目重现时重新给机会）。
    private var attempts: [String: Int] = [:]
    /// 文本 → 下次允许重试的时间点（失败退避）。
    /// 为什么需要它：只看"次数上限"会让瞬时失败在一瞬间打满次数、
    /// 该文本此后在屏幕上停留多久都不再翻（用户报的「经常有的不翻译」）。
    private var retryAfter: [String: Date] = [:]
    /// 文本 → 译文（仅当前语言方向内有效；切换语言时由 invalidateTranslations() 清空）。
    private var translations: [String: String] = [:]
    /// 译文表的插入顺序，用于 LRU 淘汰。
    /// 为什么需要：旧实现是「超过 4000 条就 removeAll()」——那一刻**屏幕上所有译文会同时
    /// 失去缓存**，要等重新翻译才回来，用户看到的就是「翻译的内容自动消失了」。
    /// 现在改成按插入顺序淘汰最旧的四分之一，屏幕上正在用的译文不受影响。
    private var translationOrder: [String] = []
    /// 最近一次合并后的原始条目（render 的输入）。
    private var lastRaw: [CapturedText] = []
    private var lastFingerprint: String?
    private var ocrActive = false
    /// 后台取字是否正在跑：防止重扫描在后台堆积（重活已搬离主线程，见 runAX）。
    private var scanBusy = false
    /// 主线程心跳：直接测量主线程被阻塞的时长。快速移动鼠标时若出现大 Δt，
    /// 即证明卡在主线程（而非后台扫描）——这是定位「快移鼠标就宕机」的关键探针。
    private var hbLast: CFTimeInterval = 0
    private var heartbeat: Timer?
    /// 上一轮 runAX 的时刻（用于算节拍间隔）。
    private var lastRunAt: CFTimeInterval = 0
    /// 诊断：上一轮取字目标 bid（抓「快速移动鼠标时目标在多个 app 间抖动」导致浮层清空）。
    private var lastTargetBid: String?
    /// 诊断节流：行内合并日志最多每 2 秒一条（只记角色/间距/行高，不含屏幕文本）。
    private var lastMergeDiagAt: CFTimeInterval = 0
    /// 临时诊断节流：MENUSKIP（菜单栏前两项识别结果）最多每 2 秒一条。验收后删。
    private var lastMenuSkipDiagAt: CFTimeInterval = 0
    /// —— 菜单栏标题「分批粘滞」状态（2026-10-13 修「抖动厉害」）——
    /// 实测证据（/tmp/yimu_diag.log）：`RENDER_TITLES n=12 total=26` 稳定输出，
    /// 每约 8 帧穿插一条 `n=0 total=14`（26 − 12），下一帧又整批回来。
    /// 即目标 app 的 AXMenuBar 属性偶有一拍读不到 → 标题批瞬间消失又回来，
    /// 条目数一变，渲染层按下标复用的「内容未变则不重排」判定全面失效
    /// （SHAKE 探针 reconfig 恒等于 n、orderChanged 每帧 +1 正是这一现象的读数）。
    /// 这里给标题组单独开 0.6s 消失宽限：短时缺失用上一帧的标题补齐，
    /// 持续缺失才真的认定菜单栏没了（切换 app / 退出融合态时自然过期）。
    // —— 菜单「常驻」缓存（2026-10-13 用户拍板：菜单栏与窗口分成两块独立区域，先保菜单栏稳定）——
    // macOS 菜单栏**永远在屏幕上**：它"消失"从来不是真消失，只是某一拍 AX 没读到。
    // 旧逻辑是「本帧读不到就当它没了」→ 每拍重新判定是否在场 → 用户看到「不停显示和隐藏」。
    // 实测根因：同一 app 菜单栏标题数在 11 ↔ 5 之间反复跳（AX 间歇返回部分集），
    // 上一版按「最近出现时刻 + 1.2s 窗口」粘滞无效——实测掉帧周期约 3s，超过窗口就过期。
    // 新逻辑（对应"两块区域"）：菜单栏标题**只增不删** —— 读到就按内容键更新，
    // 读不到就**保持上一次渲染原地不动**，绝不参与「是否还存在」的逐帧判定。
    // 唯一能让它消失的是**阳性证据**：① 切换目标 app ② 无取字目标 ③ 换模式 ④ 退出。
    // 下拉条目与标题**规则不同**：它是临时弹出的，不能"只增不删"。
    // 生死由「最近是否还被采到」裁决（逐条 TTL 淘汰，见 applyMenuHold 第 2 步）——
    // 菜单开着就一直被刷新、菜单关了 1.2s 内自动退场，既不闪也不留鬼影、也不会跨菜单累积。
    // 菜单项 id 每帧是随机 UUID（traverseRec 563 行），故只能按内容键粘滞，不能按 id。
    // 只改合并/保持策略，完全不碰 AX 采集路径。
    private var stickyTitles: [String: CapturedText] = [:]
    private var stickyDropdowns: [String: CapturedText] = [:]
    /// 每个常驻下拉条目「最近一次被采到」的时刻：逐条 TTL 淘汰的依据。
    /// 有了它，下拉条目既不会因单帧掉帧消失，也不会跨菜单累积成灾（实测曾涨到 132 条）。
    private var dropdownSeenAt: [String: CFTimeInterval] = [:]
    /// 菜单栏标题「最近一次被采到」的时刻。标题虽是「只增不删」（用户拍板），
    /// 但**不能真的是永久**：实测 app 菜单 suites 会变（Xcode 上下文菜单），旧标题会永久挂着
    /// 变成鬼影（日志里 `MENU_STICKY refill n=1 titles=12` 反复出现，而实际只有 11 个标题）。
    /// 15s 足够覆盖任何掉帧（菜单栏不会消失仍读不到超过 15s），又不会永久残留。
    private var titleSeenAt: [String: CFTimeInterval] = [:]
    private let menuTitleTTL: CFTimeInterval = 15.0
    /// 下拉条目存活时长：**单一值，彻底不看 `hasOpenMenuWindow()`**（2026-10-13 四修）。
    ///
    /// 【为什么废弃双档】旧版是 `菜单窗口还在场 → 1.2s / 已消失 → 0.12s`。
    /// 但 `hasOpenMenuWindow()` 依赖 CGWindowList 快照，**菜单关闭后它仍长期返回 true**
    /// （CGWindowList 里关闭过的菜单窗口不会立即消失，历史实测卡过 25s）。
    /// 于是：菜单关了 `win` 还是 1 → 走长档 1.2s → 兜底硬上限 2.5s 才强杀
    /// → 用户看到的正是「菜单已收回，译文还挂 2.5 秒」。硬上限成了实际退场时间。
    ///
    /// 【为什么 0.35s 够安全】重写信分析打开期的空档：之前认为"最长 0.9s 必须容忍"，
    /// 但那些长空档多为**子菜单切换**（旧菜单确实该消失，保留反而是鬼影）。
    /// 真纯掉帧只有单帧~双帧（0.15~0.3s）。故取 0.35s：容忍两帧缺失，真正的关闭立即退场。
    private let menuDropdownTTL: CFTimeInterval = 0.35
    /// 兜底硬上限（纯保险，正常走不到）：连续这么久一条下拉都没采到就强制清空。
    /// 不应再依赖它做常规治理——上面 0.35s 的逐条淘汰才是主力。
    // 0.6s（原 1.0s）：逐条淘汰已是主力，硬上限只做保险；收窄后最坏情况也更快清空。
    private let menuDropdownHardCap: CFTimeInterval = 0.6
    /// 最近一次**采到**下拉条目的时刻：硬上限的计时依据（0 表示从未采到）。
    private var lastDropdownSeenAt: CFTimeInterval = 0
    /// 「菜单快档冷却」截止时刻：在此之前，AX 轮询保持 0.15s 快档。
    ///
    /// 为什么需要它（实测 bottleneck，见日志 `SCAN sinceLast`）：
    /// `axTickFire` 原本是「有菜单打开 → 0.15s；否则 → 0.3s」。于是**菜单一关，
    /// 采集立刻降频到 0.3s**——恰恰在需要最快检测到"菜单没了"的这一刻慢了一倍。
    /// 实测下拉译文退场延迟 0.28~0.32s，几乎全部来自这个降频。
    /// 现在：只要刚采到过下拉条目，就在随后 0.6s 内保持快档，让"关闭"被及时看见，
    /// 译文撤离后才自然退回 0.3s 省 CPU。
    private var menuFastUntil: CFTimeInterval = 0
    /// 上述快档的维持时长（覆盖"关闭 → 采集到空 → 推送清空"的一整段）。
    private let menuFastHold: CFTimeInterval = 0.6
    private var lastMenuHoldDiagAt: CFTimeInterval = 0
    /// 「下拉条目被清空」专用节流时间戳：必须与 refill 分开，否则会被 refill 饿死
    /// （它每 2s 刷新一次共用时间戳），导致清空这件事在日志里彻底看不见。
    private var lastDropdownClosedDiagAt: CFTimeInterval = 0
    /// 下拉链路探针（MENU_HOLD）的独立节流时间戳。
    private var lastDropProbeAt: CFTimeInterval = 0
    /// 「换菜单立刻清」探针（MENU_SWITCH）的独立节流时间戳。
    private var lastMenuSwitchDiagAt: CFTimeInterval = 0
    private let maxItems = 500

    /// 推送合并：多次变化在 120ms 内合并为一次，避免重绘风暴导致抖动。
    private var pushTimer: Timer?
    private var pendingItems: [CapturedText]?
    /// 最近一次「非空」推送的时刻。
    /// 用途：采集出现瞬时空窗（菜单切换那一两拍、AX 抖动）时，不立刻清空覆盖层，
    /// 而是短暂保持上一帧 —— 这是「翻译的内容经常会自动消失」的最后一道兜底。
    private var lastNonEmptyPushAt: Date = .distantPast
    /// 空窗确认定时器：延时后若仍为空才真正推空。
    private var emptyHoldTimer: Timer?
    /// 空窗粘滞时长：这段时间内屏幕上的译文保持不变，等采集自愈。
    private let emptyHoldWindow: TimeInterval = 0.6
    /// 空窗确认延时：过了粘滞窗口再等这么久仍为空，才认定内容真的没了。
    private let emptyHoldConfirm: TimeInterval = 0.35
    /// 持续空窗计时器：AX 偶发空扫（快速移动鼠标时窗口服务器繁忙，scanFrontmostText 瞬时返回 0）
    /// 时启动；超过 staleTimeout 仍无任何内容才认定"真没内容"并清空。
    /// 关键：区分「瞬时抖动（保留上一帧，浮层不消失）」与「真无内容（清空）」，
    /// 直接修掉"快速移动鼠标 → 浮层被清空 → 只剩原文"的体感（用户报"像宕机、没翻译"）。
    private var staleTimer: Timer?
    private let staleTimeout: TimeInterval = 2.0
    /// AX 轮询节拍计数（配合 0.15s 定时器实现「空闲 0.3s / 有菜单 0.15s」）。
    private var axTick = 0
    /// 本轮是否检测到打开的下拉菜单（由 runAX 更新，供推送去抖复用）。
    private var menuOpenNow = false

    /// 最近一次键盘活动时刻（由 AppDelegate 的全局 keydown 监听写入）。
    /// 用于「打字冻结」：用户在别的 app 里打字时，被查看的 app（如 Xcode）的 AX 扫描
    /// 会偶发返回空（SCAN_EMPTY），若照常清空浮层会主观"打字就不翻译了"；
    /// 检测到近期有键盘活动就冻结上一帧，松手即恢复，打字期间屏幕保持上次译文。
    static var lastKeyAt: CFTimeInterval = 0
    /// 打字判定窗口：距上次按键 < 该时长即视为「正在打字」。
    private let typingWindow: CFTimeInterval = 0.7

    // MARK: - 生命周期

    func start(mode: AppState, region: NSRect) {
        self.mode = mode
        running = true
        // **不要**在这里清 `paused`（旧实现的 `paused = false` 是 BUG）：
        // 用户暂停后切换任何模式 → 采集被静默恢复，而菜单栏仍写「恢复翻译」、设置页仍显示
        // 「已暂停」，主观就是「灯灭着但还在采」；更糟的是此时点「恢复翻译」毫无反应，
        // 必须再点一次才真的暂停。暂停是用户意图，只能由 setPaused 解除。
        latestAX = []
        latestOCR = []
        currentItems = []
        lastRaw = []
        lastFingerprint = nil
        clearMenuSticky("modeChange")   // 换模式即作废上一模式的菜单缓存，避免跨模式残留在菜单栏上
        // 切模式必须先掐掉上一模式遗留的 OCR 流：镜头态会为「每块屏幕」各起一路流，
        // 切到融合态若不停，这些流继续往 latestOCR 吐结果 → 融合态实则仍在整屏 OCR，
        // 表现为「扫多个屏幕 + 把桌面文件翻出来」（融合态必须纯 AX、只译前台 app）。
        OCRTextExtractor.shared.stop()
        ocrActive = false
        // 暂停中切模式：只做状态清理，**不启动任何采集**。
        // 等 setPaused(false) 时（此时 running 已为 true）会正常把 AX/OCR 拉起。
        guard !paused else { return }
        if mode == .region {
            startOCR()                 // 区域态：仅 OCR 裁到选区，不读整屏 AX
        } else {
            startAXTimer()
            // 融合态改为「仅前台 app」策略：不再整屏 OCR（这是整屏持续重扫、画面跳动的根因）。
            // 镜头 / 区域态保留 OCR 兜底（框内 / 选区内可能含自绘 UI、游戏等 AX 读不到的内容）。
            if mode == .lens || mode == .region {
                if !OCRTextExtractor.shared.hasPermission {
                    OCRTextExtractor.shared.requestPermission()
                }
                startOCR()
            }
        }
    }

    func stop() {
        running = false
        axTimer?.invalidate(); axTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        ocrActive = false
        OCRTextExtractor.shared.stop()
        latestAX = []
        latestOCR = []
        currentItems = []
        lastRaw = []
        pending.removeAll()
        attempts.removeAll()
        retryAfter.removeAll()
        lastFingerprint = nil
        pushTimer?.invalidate(); pushTimer = nil; pendingItems = nil
        // 停止是用户主动动作（切模式 / 退出），必须立刻清屏，不能走空窗粘滞。
        emptyHoldTimer?.invalidate(); emptyHoldTimer = nil
        staleTimer?.invalidate(); staleTimer = nil
        lastNonEmptyPushAt = .distantPast
        clearMenuSticky("stop")
        // AX 侧缓存的菜单条目一并作废：否则 2.5s 内重进模式会被门控直接注入旧条目（残影）。
        AXTextExtractor.shared.clearMenuCache()
        onUpdate?([])
    }

    /// 语言方向变化后必须清空译文表，否则会沿用另一种语言的旧译文。
    func invalidateTranslations() {
        translations.removeAll()
        translationOrder.removeAll()
        pending.removeAll()
        attempts.removeAll()
        retryAfter.removeAll()
        lastFingerprint = nil
        // 语言切换必须立刻换掉屏幕上的旧译文（它们是另一种语言的结果），
        // 不能被空窗粘滞留住。
        emptyHoldTimer?.invalidate(); emptyHoldTimer = nil
        staleTimer?.invalidate(); staleTimer = nil
        lastNonEmptyPushAt = .distantPast
        if running { render() }
    }

    func setPaused(_ p: Bool) {
        paused = p
        if p {
            // 暂停必须**把所有采集相关的定时器都停掉**，不能只停 axTimer：
            // 旧实现漏了 heartbeat（0.1s，每 100ms 唤醒主线程写一次诊断日志）、
            // pushTimer / emptyHoldTimer / staleTimer，于是「暂停」之后主线程仍在 10Hz 空转。
            axTimer?.invalidate(); axTimer = nil
            heartbeat?.invalidate(); heartbeat = nil
            pushTimer?.invalidate(); pushTimer = nil; pendingItems = nil
            emptyHoldTimer?.invalidate(); emptyHoldTimer = nil
            staleTimer?.invalidate(); staleTimer = nil
            ocrActive = false
            OCRTextExtractor.shared.stop()
            pending.removeAll()
        } else if running {
            lastFingerprint = nil
            startAXTimer()
            // 融合态是「仅前台 app」策略：纯 AX、不跑 OCR。OCR 会在主屏整屏 ~1fps 跑，
            // 既把桌面文件名当文字扫出来（桌面文件被翻），又可能在菜单栏所在屏单独成一路
            // 流（表现为「扫多屏」）。OCR 只留给镜头 / 区域态兜底（框内/选区可能含自绘 UI）。
            if mode == .lens || mode == .region { startOCR() }
        }
    }

    // MARK: - AX 轮询

    private func startAXTimer() {
        axTimer?.invalidate()
        startHeartbeat()
        // 定时器固定 0.15s，由 axTickFire 决定这一拍是否真的取字：
        // - **有下拉菜单打开**：每拍都取（0.15s）—— 菜单是人正在盯着等译文的地方，最快档；
        // - **空闲**：隔拍取（等效 0.3s）—— 常规界面刷新够用，也把 CPU 让出来。
        // 旧实现固定 0.3s：换菜单、菜单项高亮移动这些瞬间都要等满 0.3s 才被看见，
        // 再叠上翻译往返，主观就是「迟钝」。
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.axTickFire() }
        RunLoop.main.add(t, forMode: .common)
        axTimer = t
        axTick = 0
        runAX()
    }

    private func axTickFire() {
        axTick += 1
        let menuOpen = AXTextExtractor.hasOpenMenuWindow()
        // **菜单刚关也照样跑快档**：刚才还在采下拉条目（menuFastUntil 内）就别降频，
        // 否则"菜单已关"这件事要等多到 0.3s 才被下一次扫描看见 → 译文迟迟不撤。
        let fast = menuOpen || CACurrentMediaTime() < menuFastUntil
        if !fast, axTick % 2 != 0 { return }   // 真正空闲才降频到 0.3s
        runAX()
    }

    /// 主线程心跳探针（临时诊断）：每 0.1s 打一次，若两次实际触发间隔 >200ms，
    /// 说明主线程被某段同步工作堵了那么久——这是「快移鼠标就宕机」最直接的证据。
    private func startHeartbeat() {
        heartbeat?.invalidate()
        hbLast = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            let now = CACurrentMediaTime()
            let dt = now - (self?.hbLast ?? now)
            self?.hbLast = now
            if dt > 0.2 {
                AXTextExtractor.diagLog("HEARTBEAT mainBlocked=\(Int(dt * 1000))ms")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t
    }

    private func runAX() {
        guard running, !paused else { return }
        let t0 = CACurrentMediaTime()
        let sinceLast = t0 - lastRunAt
        lastRunAt = t0
        // 本轮是否有下拉菜单打开：一路传给「AX 节拍 / 推送去抖 / 翻译攒批」，
        // 菜单场景整条链路提速一次判定的结果复用，避免反复枚举窗口列表。
        menuOpenNow = AXTextExtractor.hasOpenMenuWindow()
        // 菜单打开 → 翻译引擎进极速档（攒批 40ms / 批 16）：菜单是「盯着等译文」的场景。
        // `Translator.shared` 是 @MainActor 隔离的静态属性，Swift 6 下从 nonisolated 上下文
        // 直接写是硬错误。runAX 只在主 RunLoop 定时器上被调用（见 startAXTimer / axTickFire），
        // 先确认在主线程再声明隔离；万一不在主线程就跳过这一拍（下一拍 0.15s 后补上），绝不 trap。
        if Thread.isMainThread {
            MainActor.assumeIsolated { Translator.shared.turbo = menuOpenNow }
        }

        // 取字目标 app（前台 → 屏幕最上层外部窗口 → 最近非自身 app）。
        // 无目标说明无前台 AX app / 译幕自身在前台且无回退 → 清空并退出。
        guard let target = AXTextExtractor.shared.currentTarget() else {
            clearAndPush()
            AXTextExtractor.diagLog("CLEARPUSH reason=nilTarget")
            AXTextExtractor.shared.menuItems = []
            return
        }
        // 诊断：取字目标 bid 抖动检测（快速移动鼠标时窗口服务器繁忙 → 目标在 app 间跳 → 浮层清空）
        let bid = target.bundleIdentifier
        if bid != lastTargetBid {
            AXTextExtractor.diagLog("TARGET_SWITCH from=\(lastTargetBid ?? "nil") to=\(bid ?? "nil")")
            lastTargetBid = bid
            // 换 app = 菜单栏换了一整套：必须作废常驻缓存，否则旧 app 的标题块会压在新菜单栏上。
            // 这是「菜单栏可以消失」的少数阳性证据之一（其余：无目标 / 换模式 / 退出）。
            clearMenuSticky("targetSwitch")
        }
        // 排除名单（所有模式一致）：被排除的 app（如 Xcode / 终端）完全不取字、不翻译。
        guard Preferences.shared.shouldTranslate(bid) else {
            clearAndPush()
            AXTextExtractor.diagLog("CLEARPUSH reason=excluded bid=\(bid ?? "nil")")
            AXTextExtractor.shared.menuItems = []
            return
        }

        // —— A 方案核心：重活（最多 600 次 AX IPC 的递归遍历）搬到后台队列 ——
        // 主线程不再被取字阻塞，鼠标移动(60~120Hz)与 UI 刷新不再和取字抢同一线程，
        // 于是「动鼠标时翻译也持续刷新、不会卡停」。后台扫完再回主线程做菜单合并 / 裁剪 / 上屏。
        let appEl = AXUIElementCreateApplication(target.processIdentifier)
        let screenFrames = NSScreen.screens.map { $0.frame }
        let primaryH = AXTextExtractor.primaryDisplayHeight()
        let extractor = AXTextExtractor.shared   // 主线程取实例引用，后台闭包不再碰 @MainActor 的 `shared`
        let targetBid = target.bundleIdentifier   // 主线程捕获，后台完成回调里用于诊断空扫描

        // —— 可见性闸：目标 app 必须有「真正在屏」的窗口，否则窗口内容不上屏（2026-10-13）——
        // 用户报「桌面经常会有残影」，根因（详见 AXTextExtractor.hasOnScreenWindow）：
        // 采集是从 app 根节点整棵树遍历，唯一几何过滤是「矩形与屏幕相交」，
        // 而 AX 对**最小化(⌘M) / ⌘H 隐藏 / 其它桌面空间**里的窗口照样返回完整窗口树和坐标，
        // 于是照常画块，块落在「窗口本该在的位置」——屏幕上那儿只有壁纸，就是"残影"。
        // 单纯点桌面（Finder 无窗口）同理被采。
        // 这道闸只关**窗口内容**：菜单栏 / 下拉菜单此刻仍显示在屏幕顶部，照旧翻译，路径一字未动。
        let windowVisible = mode != .fusion || AXTextExtractor.hasOnScreenWindow(pid: target.processIdentifier)
        if !windowVisible {
            AXTextExtractor.diagLog("NOWIN bid=\(bid ?? "nil") — 目标 app 无在屏窗口（最小化/隐藏/其它空间），窗口内容不上屏")
        }
        guard !scanBusy else {
            AXTextExtractor.diagLog("SCAN skipped busy sinceLast=\(Int(sinceLast * 1000))ms")
            return
        }
        scanBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s0 = CACurrentMediaTime()
            // windowVisible 为 false 时（目标 app 无在屏窗口）直接不扫，省掉最多 600 次 AX IPC。
            let ax = windowVisible ? extractor.scanFrontmostText(appEl: appEl) : []
            let scanMs = (CACurrentMediaTime() - s0) * 1000
            Task { @MainActor in
                let enqueueMs = (CACurrentMediaTime() - s0) * 1000 - scanMs   // 扫描完到主线程回调被排到的等待
                guard let self else { return }
                self.scanBusy = false
                guard self.running, !self.paused else { return }
                self.latestAX = ax
                if ax.isEmpty {
                    AXTextExtractor.diagLog("SCAN_EMPTY bid=\(targetBid ?? "nil")")
                }
                // 菜单采集（节流 + 命中测试）仍在主线程做，只碰 menuItems（主线程态）。
                AXTextExtractor.shared.scheduleMenuHarvest(appEl,
                                                           screenFrames: screenFrames, primaryH: primaryH)
                let menuGateOpen = CACurrentMediaTime() - AXTextExtractor.shared.menuItemsAt < 2.5
                if menuGateOpen {
                    self.latestAX.append(contentsOf: AXTextExtractor.shared.menuItems)
                }
                let mn = AXTextExtractor.shared.menuItems.filter { $0.menuBarTitle }.count
                AXTextExtractor.diagLog("MERGE gate=\(menuGateOpen ? 1 : 0) menuItemsTotal=\(AXTextExtractor.shared.menuItems.count) titles=\(mn)")
                // 镜头态：AX 结果裁剪到镜头框内（框外不翻译）。OCR 在 combineAndPush 统一裁。
                if self.mode == .lens, let region = self.regionProvider?(), !region.isEmpty {
                    self.latestAX = self.latestAX.compactMap { item -> CapturedText? in
                        let c = item.rect.intersection(region)
                        guard c.width > 4, c.height > 4 else { return nil }
                        return item.clipped(to: region)
                    }
                }
                // OCR 自愈：镜头态 OCR 停掉（或屏幕录制授权刚获批）后，下一轮轮询自动重启。
                if self.mode == .lens, !self.ocrActive {
                    self.startOCR()
                }
                let c0 = CACurrentMediaTime()
                self.combineAndPush()
                let combineMs = (CACurrentMediaTime() - c0) * 1000
                AXTextExtractor.diagLog("SCAN sinceLast=\(Int(sinceLast * 1000)) scan=\(Int(scanMs)) "
                    + "enqueue=\(Int(enqueueMs)) combine=\(Int(combineMs))ms")
                self.logDiag()
            }
        }
    }

    /// 清空全部取字结果并推空（排除名单 / 无目标场景复用）。
    private func clearAndPush() {
        clearMenuSticky("clearAndPush")   // 无目标 / 被排除：菜单栏整体撤离（阳性证据）
        latestAX = []
        latestOCR = []
        ocrActive = false
        OCRTextExtractor.shared.stop()
        combineAndPush()
    }

    /// 诊断日志（每 2 秒最多一条）：AX 授权状态 + 当前取字目标 + 各阶段条数。
    ///
    /// 为什么需要它：真机观察发现「菜单采集一次都没执行过」（harvest 日志 0 条），
    /// 说明问题出在比菜单采集更上游的地方——AX 是否授权、取字目标 app 选没选出来。
    /// 只打印数字与 bundle id，不含任何屏幕文本。
    private var lastDiagAt: Date = .distantPast
    private func logDiag() {
        let now = Date()
        guard now.timeIntervalSince(lastDiagAt) > 2 else { return }
        lastDiagAt = now
        let target = AXTextExtractor.shared.currentTarget()
        let msg = "diag trusted=\(AXTextExtractor.shared.isTrusted ? 1 : 0) "
            + "target=\(target?.bundleIdentifier ?? "nil") "
            + "ax=\(latestAX.count) ocr=\(latestOCR.count) raw=\(lastRaw.count) out=\(currentItems.count)"
        NSLog("[YiMu] %@", msg)
        AXTextExtractor.diagLog(msg)   // 同时落盘：本机 log stream 不稳，文件才是可靠通道
    }

    // MARK: - OCR 兜底 / 融合整屏

    private func startOCR() {
        guard !ocrActive else { return }
        // 无屏幕录制授权时不置位：runAX 的自愈逻辑每 0.4s 重试，
        // 授权一通过 OCR 即自动启动，无需重进模式或重启 app。
        guard OCRTextExtractor.shared.hasPermission else { return }
        ocrActive = true

        let displays: [(frame: NSRect, id: CGDirectDisplayID, scale: CGFloat)]
        if mode == .fusion {
            // 融合态只译主屏（用户指定）：仅零号屏（菜单栏所在屏）起一路 OCR 流。
            let s = NSScreen.screens.first ?? NSScreen.main!
            let id = s.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
            displays = [(s.frame, id, s.backingScaleFactor)]
        } else if mode == .lens {
            // 镜头态：所有屏幕各起一路（镜头框可拖到任一屏），由引擎统一裁到框内。
            displays = NSScreen.screens.compactMap { s in
                let id = s.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return (s.frame, id, s.backingScaleFactor)
            }
        } else {
            // 区域态：只取包含区域中心的那块屏（裁剪在 combineAndPush 统一做）。
            let region = regionProvider?() ?? .zero
            let disp = Self.displayContaining(region: region)
            let scale = NSScreen.screens.first(where: { $0.frame == disp.frame })?.backingScaleFactor ?? 1
            displays = [(disp.frame, disp.displayID, scale)]
        }

        OCRTextExtractor.shared.onResult = { [weak self] items in
            guard let self, self.running, !self.paused else { return }
            self.latestOCR = items
            DispatchQueue.main.async { self.combineAndPush() }
        }
        // 镜头/区域态是交互式取字，用 6fps 让译文更快跟上拖动；融合态只整屏兜底，3fps 省 CPU。
        let ocrFps = (mode == .lens || mode == .region) ? 6 : 3
        OCRTextExtractor.shared.start(displays: displays,
                                     cropRect: nil,
                                     frameRate: ocrFps,
                                     excludeWindowIDs: excludeWindowIDs)
    }

    // MARK: - 合并 / 去抖 / 去重

    private func combineAndPush() {
        var merged = latestAX
        merged.append(contentsOf: latestOCR)
        // 兜底过滤：退化矩形或完全在屏幕外的项直接丢弃（角落垃圾块的最后一道闸）。
        let screenFrames = NSScreen.screens.map { $0.frame }
        merged = merged.filter { item in
            item.rect.width >= 2 && item.rect.height >= 2
                && screenFrames.contains { $0.intersects(item.rect) }
                && !Self.isInvisibleLabel(item)     // 屏幕画不下的 aria-label（图标按钮的替代文本）
                && isTranslatable(item.text, isMenu: item.isMenu, isOCR: item.source == .ocr)
        }
        let snapped = merged.map { snap($0) }      // 吸附到整数像素，消除亚像素抖动
        let deduped = dedup(snapped)
        let axPreferred = preferAX(deduped)        // AX 优先：丢弃与 AX 明显重叠的 OCR 项
        let cleaned = dropRedundantOCR(axPreferred) // OCR 冗余抑制：同处文字的碎片框只留最完整的一个
        let lines = mergeIntoLines(cleaned)
        lastRaw = clipToRegion(lines)              // 行内合并后裁到镜头框 / 区域内
        lastRaw = applyMenuHold(lastRaw)          // 菜单项（标题+下拉）掉帧兜底（防不停显示/隐藏）
        // 管道探针：每一环的存活数 + 镜头框实际值，定位「几乎没翻译」丢在哪一环。
        AXTextExtractor.diagLog("PIPE in=\(merged.count) dedup=\(deduped.count) axPref=\(axPreferred.count) cleaned=\(cleaned.count) lines=\(lines.count) final=\(lastRaw.count) region=\(regionProvider?() ?? .zero)")
        render()
    }

    // 注：融合态现已改为「仅前台 app」——前台 app 的窗口在哪块屏就翻译哪块屏，
    // 不再强制只译主屏（之前的「主屏过滤」已移除）。

    /// AX 优先：融合态 AX 与 OCR 双路并行，同一处文字会各出一个矩形——
    /// OCR 行框更松、位置常偏移几像素、文本偶有分词差异，同文本容差去重拦不住，
    /// 渲染出来就是「同一行两块、宽窄不一、互相压盖」（下拉菜单最明显）。
    /// 规则：OCR 项与任一 AX 项纵向重叠过半且横向相交 → 判定为同一处文字，丢弃 OCR 项。
    private func preferAX(_ items: [CapturedText]) -> [CapturedText] {
        // 镜头态反过来：镜头框里大量内容是 AX 读不到的（图片/视频/游戏/自绘 UI），
        // OCR 才是真正的取字来源；若 AX 返回的是旧/错的文字，会盖掉正确 OCR 结果。
        // 故镜头态改用 preferOCR：非菜单类的 AX 项若与 OCR 重叠则丢弃，菜单类 AX 仍保留。
        if mode == .lens { return preferOCR(items) }
        let axItems = items.filter { $0.source == .ax }
        guard !axItems.isEmpty else { return items }
        return items.filter { item in
            guard item.source == .ocr else { return true }
            return !axItems.contains { ax in
                let inter = ax.rect.intersection(item.rect)
                guard inter.width > 0, inter.height > 0 else { return false }
                return inter.height > min(ax.rect.height, item.rect.height) * 0.5
            }
        }
    }

    /// 镜头态专用：OCR 优先。AX 与 OCR 同处文字时丢弃非菜单 AX（保留菜单栏/菜单 AX，
    /// 它们通常准且 OCR 对菜单未必稳），避免旧/错 AX 文字盖掉正确 OCR 识别。
    private func preferOCR(_ items: [CapturedText]) -> [CapturedText] {
        let ocrItems = items.filter { $0.source == .ocr }
        guard !ocrItems.isEmpty else { return items }
        return items.filter { item in
            guard item.source == .ax, !item.isMenu else { return true }
            return !ocrItems.contains { o in
                let inter = o.rect.intersection(item.rect)
                guard inter.width > 0, inter.height > 0 else { return false }
                return inter.height > min(o.rect.height, item.rect.height) * 0.5
            }
        }
    }

    /// OCR 冗余抑制：Vision 偶尔对同一处文字给出多个重叠/包含的观察框（文本还略有差异，
    /// 同文本去重拦不住），渲染出来就是同一行叠好几块。规则：一个框 70% 以上面积被另一个
    /// OCR 框覆盖时视为碎片，只保留文本更完整的一个（同长取先到者），杜绝互相压盖。
    private func dropRedundantOCR(_ items: [CapturedText]) -> [CapturedText] {
        guard items.count > 1 else { return items }
        var drop = Set<Int>()
        for j in items.indices {
            guard items[j].source == .ocr else { continue }
            let b = items[j].rect
            let bArea = b.width * b.height
            guard bArea > 0 else { continue }
            for i in items.indices where i != j {
                guard items[i].source == .ocr else { continue }
                let inter = items[i].rect.intersection(b)
                guard inter.width > 0, inter.height > 0 else { continue }
                let covered = (inter.width * inter.height) / bArea
                guard covered > 0.7 else { continue }
                let sameOrBetter = items[i].text.count > items[j].text.count
                    || (items[i].text.count == items[j].text.count && i < j)
                if sameOrBetter { drop.insert(j); break }
            }
        }
        guard !drop.isEmpty else { return items }
        return items.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }

    /// 内容是否值得翻译——只放行「像自然语言」的文本，挡掉会变成怪块的噪声。
    ///
    /// 真机日志实证（`/tmp/yimu_translate_debug.txt`）：镜头态把 Xcode 源码注释、
    /// 文件路径、窗口标题、桌面 OCR 乱码（`tIEX.` / `] (Z Z*) . Xcoe` /
    /// `RB1₺extapp DeskCalendar` / `( ) oe Version 27.0`）统统抓来翻译，渲染成
    /// 「不是翻译的内容」的怪块。这里在源头逐条拦截。
    private func isTranslatable(_ text: String, isMenu: Bool, isOCR: Bool) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        let scalars = t.unicodeScalars
        let latin = scalars.filter { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }.count
        let cjk = scalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        // 假名 / 谚文：有它们就不是「已是中文」，日文、韩文源文本照样要翻。
        let kana = scalars.filter { (0x3040...0x30FF).contains($0.value) }.count
        let hangul = scalars.filter { (0xAC00...0xD7AF).contains($0.value) }.count
        // 任意文字系统的字母（西里尔 / 希腊 / 阿拉伯 / 泰文…都要算数，
        // 否则俄语、泰语这类非拉丁源文本会被整类误杀）。
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count

        // ① 已经是中文的文本：目标语言是中文时无需翻译。
        //    引擎收到中文会「翻」出中文夹杂物（日志里 `/// F（辅助功能/AX）应用程序 Apple` 这类），
        //    既白耗引擎、又在屏幕上留下半中半英的怪块。
        if targetIsChinese, cjk >= 2, kana == 0, hangul == 0 { return false }
        // ② 纯符号 / 单字符：不值得翻（"98"、"⌘Z"、"·"）。
        if letters < 2 { return false }

        // ③ 路径 / 文件名：Xcode 窗口标题、标签栏、Finder 列表里全是这些。
        if t.contains("~/") || t.contains("/Users/") || t.contains("/tmp/") { return false }
        if t.filter({ $0 == "/" }).count >= 2 { return false }
        if t.range(of: #"\.(swift|png|pdf|docx|xlsx|app|md|json|txt|log|jpg|jpeg|plist|zip|mp4|csv|html|css|js|ts|dmg|pkg|rtf|pages|key|numbers)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return false }

        // ④ 代码 / 标记语言：源码注释、diff 行、Markdown 强调、面板分隔线。
        if t.filter({ $0 == "|" }).count >= 2 { return false }
        if t.contains("**") || t.contains("///") || t.contains("=>")
            || t.contains("->") || t.contains("::") { return false }
        if t.hasPrefix("//") || t.hasPrefix("•") || t.hasPrefix("*") || t.hasPrefix("@ ") { return false }

        // ⑤ 乱码特征符号：Vision 用英文模型读中日韩文字时会吐这些字符。
        if scalars.contains(where: { "₺Æ₴¾½²³‰⁄©®™·•".unicodeScalars.contains($0) }) { return false }

        // ⑥ 拉丁字母密度过低（数字 / 符号为主），如 `( ) oe Version 27.0`。
        //    阈值 0.45：正常含数字的界面文字（"Total: 1,234 items" ≈ 0.53）要放行。
        if latin >= 3 {
            let nonSpace = t.filter { !$0.isWhitespace }.count
            if Double(latin) / Double(max(nonSpace, 1)) < 0.45 { return false }
        }

        // ⑦ OCR 碎片（只查拉丁文本，西里尔/泰文等不受影响）：
        //    a) 至少要有 2 个「真单词」（≥3 个字母），否则是识别噪声；放宽为
        //       「或单个 ≥4 字母且大小写形态正常的单词也放行」——镜头里大量是单字标签
        //       （"Open" / "Settings" / "Continue"）。≥5 门槛曾把 4 字母的 "Open..." 整类误杀
        //       （同屏 "Clone..."(5) 却能翻，用户 19:30 截图实证）。大小写约束保底：
        //       Open=首字母大写 ✓、settings=全小写 ✓、tIEX=混杂 ✗ 仍挡。
        //    b) 字母中间夹数字的怪 token（"RB1textapp" / "A2EEEAtET" / "PDF2KEN"）——
        //       OCR 把相邻文字黏成一团的典型特征；正常写法是数字在两端（"10bit" / "iPhone15"）。
        //    只对 OCR 来源生效：AX 读到的文本是准的，单词按钮不能被误杀；
        //    菜单项也豁免（菜单项本来就短："Console"、"Detach"）。
        if isOCR, !isMenu, latin >= 3 {
            let words = t.split(whereSeparator: { !$0.isLetter })
                .filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII } }
            if words.count < 2, !words.contains(where: { Self.isCleanWord(String($0)) }) { return false }
            let glued = t.split(whereSeparator: { $0.isWhitespace }).contains { tok -> Bool in
                guard tok.count >= 5 else { return false }
                let cs = Array(tok)
                guard let first = cs.firstIndex(where: { $0.isNumber }),
                      let last = cs.lastIndex(where: { $0.isNumber }),
                      cs.contains(where: { $0.isLetter }) else { return false }
                return first > 0 && last < cs.count - 1
            }
            if glued { return false }
        }

        // ⑧ 不是「人类语言」的数据值 / 系统元信息 —— 一律不翻、不画块（2026-10-13 用户拍板）。
        //    用户原话：「这是一个翻译软件，是从人类的一种语言翻译成另外一种语言」。
        //    所以判据只有一个：**这是不是"人写的话"**。机器产出的数据值不是语言，翻了就是怪块。
        //    实证（缓存 SHA-256 反查，2026-10-13）：
        //      `1.3 MB`→「1.3兆字节」、`832 KB`→「832 千字节」（同类 47 条）、
        //      UTI 描述→「可携式文件格式」、`AX…`→「AX 排序顺序方向」。
        //    这些块盖在桌面文件信息 / Finder 列表元信息上，正是用户报的「不需要翻译的给翻译出来了」。
        //    注：`1.3 MB` 之所以能钻过上面 ⑦ —— 它的拉丁字母只有 2 个（MB），
        //    触发不了第⑥条的密度检查（要求 latin >= 3）。
        //   a) AX 内部标识：`AXSortOrderDirection` 这类 accessibility 属性名，不是给人看的文本。
        if t.hasPrefix("AX"), t.dropFirst(2).first?.isUppercase == true { return false }
        //   b) 尺寸 / 容量 / 频率 / 百分比：`1.3 MB` `832 KB` `12 kHz` `60 fps` `99%`
        if t.range(of: #"^\s*[\d.,]+\s*(B|[KMGTP]i?B|[KMG]?Hz|fps|dpi|px|pt|%)?\s*$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil { return false }
        //   c) 数字主导且几乎没字母：`2026-10-13` `192.168.1.1` `v2.1.0` `10:30`
        let digits = scalars.filter { (0x30...0x39).contains($0.value) }.count
        if letters < 3 && digits >= letters { return false }
        //   d) 系统 UTI / 文件种类描述（**仅窗口内容**：菜单里的 "Document" 是真菜单项，绝不误杀）。
        //      形态：≥3 个词、全 Title Case、末词是类型名 ——
        //      `Portable Document Format` / `Rich Text Format` / `JPEG Image` / `MP4 Video`。
        //      要求 ≥3 词是为了不误杀 `Untitled Document` 这类两词的窗口标题。
        if !isMenu {
            let utiTail: Set<String> = [
                "document", "format", "image", "text", "video", "audio", "archive",
                "folder", "presentation", "spreadsheet", "package", "application",
                "alias", "bitmap", "graphics", "quicktime", "movie", "pdf", "photo",
            ]
            let ws = t.split(separator: " ")
            if ws.count >= 3, let last = ws.last?.lowercased(), utiTail.contains(last),
               ws.allSatisfy({ $0.first?.isUppercase == true }) { return false }
        }
        return true
    }

    /// 单词是否「形态正常」：≥5 字母直接放行；4 字母要求大小写形态自然
    /// （首字母大写+余小写 / 全小写 / 全大写），挡掉 `tIEX` 这类大小写混杂的识别噪声。
    private static func isCleanWord(_ w: String) -> Bool {
        guard w.allSatisfy({ $0.isLetter }) else { return false }
        if w.count >= 5 { return true }
        guard w.count == 4 else { return false }
        let lower = w.map { $0.isLowercase }
        let allLower = lower.allSatisfy { $0 }
        let allUpper = !lower.contains(true)
        let capitalized = lower[0] == false && lower.dropFirst().allSatisfy { $0 }
        return allLower || allUpper || capitalized
    }

    /// 行内合并：同一行内垂直重叠、水平间距很小的相邻文本合并为整句，
    /// 使译文呈现为一个完整句子块，而不是一排逐词碎片；间距大的独立单词保持单独成块。
    ///
    /// 2026-10-13 修复「词汇没有断开、混合排在一起」：
    /// 并排控件的标签天然同行、间距又小（Final Draft 工具栏 Split / Views / Beat Board），
    /// 旧规则把它拼成「Split Views Beat Board」一整句 → 译成「分割视图节拍板」→
    /// 再用并集矩形渲染成一个横跨三个按钮的大块。现在两道闸：
    /// ① **控件内文字（isControl）绝不参与合并**（自身是控件，或位于控件内部）；
    /// ② 正间距阈值由 `max(10, 行高×1.1)` 收紧到 `max(4, 行高×0.6)`——
    ///    真实被拆开的词间距约等于一个空格（13pt 字 ≈ 3–6pt），控件之间的留白通常 ≥10pt。
    private func mergeIntoLines(_ items: [CapturedText]) -> [CapturedText] {
        guard items.count > 1 else { return items }
        // —— 排序必须是「严格弱序」（2026-10-13 修「抖动厉害」）——
        // 旧写法：`if abs(a.midY - b.midY) > 4 { return a.midY > b.midY } return a.minX < b.minX`
        // 混用了两套判据，不满足传递性（可出现 A<B、B<C、C<A 的循环），Swift 的 sort 结果
        // 因此不确定：相邻两项 midY 的亚像素抖动一旦跨过那个 4pt 阈值，名次就翻转，
        // items 顺序逐帧变化 → 渲染层按 slot 下标复用的「内容未变则不重排」判定全部失效
        // → 每帧全盘重新布局并重置悬停高亮，主观就是「抖动厉害」。
        // 现在：行键量化到 4pt 网格构成一个全序（行间按 midY 降序、行内严格按 minX 升序），
        // 比较具备传递性 → 同样输入必然同样顺序，轻微抖动不会再打乱整个序列。
        let rowKey = Self.renderingSort
        let sorted = items.sorted(by: rowKey)
        var out: [CapturedText] = []
        var mergedPairs: [String] = []
        for item in sorted {
            guard let last = out.last,
                  !last.isMenu, !item.isMenu,          // 菜单栏 / 菜单条目独立成块，绝不拼接
                  !last.isControl, !item.isControl,     // 控件标签独立成块，绝不与邻居拼接
                  !last.didMerge, !item.didMerge,       // 合并产物不再被吸收：禁止级联拼长串
                  last.source == item.source,
                  abs(last.rect.midY - item.rect.midY) <= max(4, min(last.rect.height, item.rect.height) * 0.6),
                  Self.mergeableHorizontal(last.rect, item.rect,
                                           allowOverlap: last.source == .ocr && item.source == .ocr),
                  Self.linkGapOK(last, item),           // 链接之间更严（见注释）
                  (last.text + " " + item.text).count <= 90
            else {
                out.append(item)
                continue
            }
            // 诊断只记「角色 + 间距 + 行高」，不含任何屏幕文本（隐私：日志里不落用户内容）。
            mergedPairs.append(String(format: "%@+%@ gap=%.1f h=%.1f",
                                      last.axRole.isEmpty ? "ocr" : last.axRole,
                                      item.axRole.isEmpty ? "ocr" : item.axRole,
                                      item.rect.minX - last.rect.maxX,
                                      min(last.rect.height, item.rect.height)))
            let text = last.text + " " + item.text
            out[out.count - 1] = CapturedText(id: last.id,
                                              text: text,
                                              rect: last.rect.union(item.rect),
                                              source: last.source,
                                              displayText: text,
                                              isMenu: last.isMenu,
                                              menuBarTitle: last.menuBarTitle,
                                              didMerge: true)   // 标记：不再被后续合并吸收
        }
        if !mergedPairs.isEmpty, CACurrentMediaTime() - lastMergeDiagAt > 2 {
            lastMergeDiagAt = CACurrentMediaTime()
            AXTextExtractor.diagLog("MERGE_LINES in=\(items.count) out=\(out.count) "
                + "pairs=\(mergedPairs.count) [\(mergedPairs.prefix(6).joined(separator: " | "))]")
        }
        return out
    }

    /// 镜头态 / 区域态：所有条目裁剪到框内（框外不翻译、不显示）。
    /// OCR 整屏跑、在此统一裁——窗口/框拖动缩放时天然实时跟随，不存在"裁剪框过期"问题。
    private func clipToRegion(_ items: [CapturedText]) -> [CapturedText] {
        guard mode == .lens || mode == .region, let region = regionProvider?(), !region.isEmpty else {
            return items
        }
        var out: [CapturedText] = []
        for it in items {
            let c = it.rect.intersection(region)
            guard c.width > 4, c.height > 4 else { continue }
            out.append(it.clipped(to: region))
        }
        return out
    }

    /// 横向可合并：同行相邻碎片（正间距 ≤ 行高容差），或真正横向互相压边的碎片框。
    ///
    /// 关键修复（镜头态串屏幻影）：旧判断 `item.minX - last.maxX <= gap` 没有取绝对值，
    /// 本意是"横向重叠的碎片间距为负也该合并"；但跨屏条目恰好落进这个负数陷阱——
    /// 副屏 OCR 文字（如聊天里的"Accsoon See REC"，x≈2268）排在主屏条目（x≈810）
    /// 之后时，`810 - 2400` 为大负数，被误判成横向重叠 → 两屏文字拼成一个块，
    /// union 矩形横跨两屏，裁剪到镜头框后残段落在镜头内 → 副屏文字出现在主屏镜头里。
    /// 现在：正间距走行高容差；负间距必须是两框真横向相交（item.maxX > last.minX）。
    /// 两块屏幕坐标区间不相交，跨屏条目永远过不了这道闸。
    ///
    /// 2026-10-13：正间距容差由 `max(10, 行高×1.1)` 收紧到 `max(4, 行高×0.6)`。
    /// 实测证据：工具栏并排按钮标签的间距约 10–15pt（行高 14pt 时旧阈值 15.4pt 恰好放行），
    /// 于是三个按钮被拼成一句再整体翻译。一个空格在 13pt 字下只有 3–6pt，
    /// 真正「被拆开的同一句话」依旧能合并，控件之间的留白则过不了闸。
    /// 链接（AXLink）参与合并时的额外闸（2026-10-13）。
    ///
    /// 为什么单给链接加闸：网页工具栏上并排的链接（IMDb 顶部的 "IMDb Pro" / "Watchlist" /
    /// "Sign in"）间距 8–17pt，而通用阈值是 `行高×0.6`（36pt 行高 → 21.6pt）——正好放行，
    /// 于是三个独立链接被拼成「观察列表登录」一块（实测 MERGE_LINES `AXLink+AXLink gap=17.0`）。
    /// 而正文里的行内链接间距通常只有 2–5pt（一个空格），收紧到 4pt 不会拆散正常句子。
    private static func linkGapOK(_ last: CapturedText, _ item: CapturedText) -> Bool {
        guard last.axRole == "AXLink" || item.axRole == "AXLink" else { return true }
        return item.rect.minX - last.rect.maxX <= 4
    }

    /// 2026-10-13 重写：负间距（两矩形**重叠**）不再合并 AX 项。
    ///
    /// 旧规则对负间距是「横向相交就合并」，本意是接住 OCR 把同词切成两半的碎片框。
    /// 但 AX 项矩形重叠根本不含"拼句"语义 —— 那是同一个链接/按钮被报成了嵌套或重复元素
    /// （实测 IMDb 顶部 `AXLink+AXLink gap=-1.0`、`AXStaticText+AXStaticText gap=-53.0`）。
    /// 照旧规则合并，两个独立按钮（Watchlist / Sign in）就被焊成一块，译文挤在一起
    /// （用户截图：「观察列表登录st」后面还露着 Sign in 原文）。
    /// 现在：只有**两侧都是 OCR** 时才允许重叠合并（保留碎片拼接能力）。
    private static func mergeableHorizontal(_ last: NSRect, _ item: NSRect,
                                            allowOverlap: Bool) -> Bool {
        let gap = item.minX - last.maxX
        if gap >= 0 { return gap <= max(4, min(last.height, item.height) * 0.6) }
        return allowOverlap && item.maxX > last.minX
    }

    /// 「屏幕上不可能画出这么长的文字」的替代文本（aria-label）判据。
    ///
    /// 为什么需要它（2026-10-13 用户：「翻译的内容已经牵扯到深层内容了」）：
    /// HTML 的 `aria-label` 会被 AX 映射进 **AXTitle**，与真正画在屏幕上的文字**无法靠属性区分**
    /// （我们只能取到「Open Navigation Drawer Menu」这个字符串，和标题文字长得一模一样）。
    /// 但几何能区分：那个汉堡按钮的矩形只有 42×42，**根本画不下 24 个字符**
    /// （至少需要 4 行，而框高只够 2 行半）—— 说明这行字只存在于无障碍树里，屏幕上没有。
    /// 判据（面积版，不用"宽度比"——那会误杀窄栏里的长段落）：
    /// 这段文字的排版所需面积（按 13pt 估）**大于**矩形可用面积 × 1.2
    /// —— 即这块矩形里**物理上装不下**这些字 → 它只存在于无障碍树里，屏幕上没有。
    /// 校验：汉堡按钮 42×42 / 24 字符 → 1.55 > 1.2 ✓ 命中；
    /// 正文段落 896×85 / 319 字符 → 0.48 ✓ 安全；窄高的侧栏长文比值更低，同样安全。
    private static func isInvisibleLabel(_ item: CapturedText) -> Bool {
        guard item.rect.width > 1, item.rect.height > 1, !item.text.isEmpty else { return false }
        let pt: CGFloat = 13
        let lineH = pt * 1.25
        let srcW = (item.text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: pt)]).width
        return srcW * lineH > item.rect.width * item.rect.height * 1.2
    }

    /// 文本里是否含 Unicode 私有区字符（U+E000–U+F8FF / 平面15 / 平面16）。
    /// 为什么要查（2026-10-13 用户截图 `Xco🍎de`）：苹果菜单的 AX 标题常是 `\u{F8FF}`
    /// ——私有区里的苹果标，系统字体没有这个字形，渲染出来就是**黑苹果／豆腐块**，
    /// 而且它的块会压到紧邻的 App 名上，把 "Xcode" 的字母盖掉。
    /// 这种字符既谈不上「复制原文」（屏幕上本来画的就不是字，是图标），也不能翻译。
    /// 苹果标志字形 U+F8FF（菜单栏最左一格用）。
    /// 本地 CoreText 实测：系统字体**有**这个字形（glyph 2601），渲染为纯黑白，不是彩色 emoji、也不是豆腐块。
    private static let appleGlyph = "\u{F8FF}"
    /// 苹果菜单格相对所在屏左缘的内缩量（实测 19 个 app × 2 块屏，恒为 10）。
    private static let appleCellInset: CGFloat = 10
    /// 苹果菜单格宽度（实测恒为 34）。
    private static let appleCellWidth: CGFloat = 34
    /// 合成苹果标块用的固定 id：帧间保持一致，避免每帧新建 UUID。
    private let appleSyntheticId = UUID()

    private static func hasPrivateUseChar(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            let v = u.value
            if v >= 0xE000 && v <= 0xF8FF { return true }
            if v >= 0xF0000 && v <= 0xFFFFD { return true }
            if v >= 0x100000 && v <= 0x10FFFD { return true }
        }
        return false
    }

    /// 「上屏顺序」的唯一定义：行按 midY 降序（4pt 量化成全序），行内按 minX 升序。
    /// 抽出来是为了让 mergeIntoLines 与标题补帧走**完全相同**的顺序——
    /// 顺序一旦两处不一致，同一批条目在「补帧 / 正常帧」之间的排列就不同，
    /// 渲染层按下标复用块，会被判成内容全变 → 每帧全盘重排 → 肉眼抖动。
    private static func renderingSort(_ a: CapturedText, _ b: CapturedText) -> Bool {
        let ka = (a.rect.midY / 4).rounded(.down), kb = (b.rect.midY / 4).rounded(.down)
        if ka != kb { return ka > kb }
        return a.rect.minX < b.rect.minX
    }

    /// 菜单项（菜单栏标题 + 下拉条目）掉帧兜底（2026-10-13 修「菜单翻译不停显示和隐藏」）。
    ///
    /// 根因（实测 /tmp/yimu_diag.log）：同一 app 的菜单项本应静态，但 AX 对菜单的读取
    /// 会间歇返回「部分集」（Final Draft 菜单栏标题在 11 ↔ 5 之间反复跳；下拉条目
    /// 整批出现又消失）。旧逻辑（applyTitleHold）只护菜单栏标题、且用「部分集覆盖全集」
    /// —— 当前帧只要采到 5 个标题就用这 5 个覆盖掉缓存的 11 个 → 缺的 6 个永远回不来；
    /// 下拉条目则完全没人护，于是闪。
    ///
    /// 新逻辑（2026-10-13 用户拍板「菜单栏与窗口分成两块独立区域，先保菜单栏稳定」）：
    /// 菜单栏**只增不删** —— 读到就用最新实地值覆盖；读不到就**保持上一次渲染原地不动**，
    /// 绝不参与「这一拍还在不在」的判定。因为它本来就在屏幕上，不刷新也远好过闪。
    /// 唯一能让它消失的是**阳性证据**：换 app / 无目标 / 换模式 / 退出（见 clearMenuSticky）。
    /// **下拉条目规则不同**：它不因单帧缺席消失（容忍采集空档），但按「最近是否还被采到」
    /// 逐条 TTL 淘汰 —— 菜单关了 0.35s 内自动退场，绝不留鬼影（见第 2 步的长注释）。
    /// 只改合并/保持策略，完全不碰 AX 采集路径。
    private func applyMenuHold(_ raw: [CapturedText]) -> [CapturedText] {
        let now = CACurrentMediaTime()
        // 1) 本帧读到的菜单项并入常驻缓存：读到就覆盖为最新实地值；
        //    读不到的**一律保留原样**（这正是"只增不删"——不因单帧缺席当它没了）。
        //    菜单项 id 每帧随机 UUID，故按内容键（文本 + 粗量化 midY）索引。
        let dropIn = raw.filter { $0.isMenu && !$0.menuBarTitle }.count
        for it in raw where it.isMenu {
            let k = Self.menuHoldKey(it)
            if it.menuBarTitle {
                stickyTitles[k] = it
                titleSeenAt[k] = now          // 标题也是到期即失效，防止永久鬼影
            } else {
                stickyDropdowns[k] = it
                dropdownSeenAt[k] = now      // 逐条淘汰用的「最近出现时刻」
            }
        }
        // 1b) 菜单栏标题的**过期剔除**（15s）。
        //     「只增不删」指的是**不因单帧缺席判定它没了**，不是字面永久保存。
        //     实测 app 菜单会动态增减（Xcode 上下文相关菜单），旧标题永久挂着就成了鬼影
        //     ——日志里反复出现 `refill n=1 titles=12`，而实际标题只有 11 个，正是这条多出来的。
        //     15s 远超任何掉帧周期，菜单栏正常工作时不会被误剔除。
        var titleDead: [String] = []
        for (k, t) in titleSeenAt where now - t > menuTitleTTL { titleDead.append(k) }
        for k in titleDead {                    // 两趟走（同下拉，避开独占性崩溃）
            stickyTitles.removeValue(forKey: k)
            titleSeenAt.removeValue(forKey: k)
        }
        // 2) 下拉条目的生死裁决：**逐条 TTL 淘汰**（2026-10-13 三修）。
        //
        // 【为什么不用 hasOpenMenuWindow() 兜底】实测它在下拉菜单打开期间**恒为 1**，
        // 菜单关闭后仍长期为 1（CGWindowList 里关闭过的菜单窗口不会立即消失）。
        // 上一版让 `menuWinOpen || dropIn > 0` 参与豁免并重置计时，结果计时被无限重置
        // → 常驻下拉**永不清空** → 菜单关了屏幕上一大片译文块残留
        // （用户截图 + 日志 `sticky=93 out=93` 持续几十秒不清）。
        //
        // 【为什么不用"整体清空"】内容键含 midY/10，鼠标划过菜单条目、条目位置微动都会
        // 产生新键，旧键从不淘汰 → 实测 sticky 从 36 单调涨到 132；而 `out` 直接等于
        // sticky，屏幕上就画了 132 个块（真实菜单只有 13~23 条）。
        //
        // 【逐条淘汰】菜单开着 → 条目持续被采到、lastSeen 不断刷新 → 不会被淘汰；
        // 菜单关闭 → 本帧采不到 → TTL 到点逐条淘汰 → 屏幕及时清空、且永不膨胀。
        // 【TTL 取单一值 0.35s，废弃双档】旧版用 `win ? 1.2s : 0.12s`，但 hasOpenMenuWindow()
        // 在菜单**关闭后仍长期返回 true**（CGWindowList 快照滞后），于是实际走的永远是长档，
        // 只能靠 2.5s 硬上限强杀 → 用户感知「菜单已收回，译文还挂 2.5 秒」。
        // 重写信分析打开期空档：所谓"最长 0.9s"多发生在**子菜单切换**（旧菜单本就该消失，
        // 留着反而是鬼影）；真正纯掉帧只有 1~2 帧（0.15~0.3s）。0.35s 足以容忍。
        // TTL 档位：**单一值，不看 win**（win 会在菜单关闭后卡 true，见字段注释）。
        // 这里的 hasOpenMenuWindow() **仅供探针记录**，不再参与任何生死判定。
        let menuWinOpen = AXTextExtractor.hasOpenMenuWindow()
        var dropTTL = menuDropdownTTL
        if dropIn > 0 {
            lastDropdownSeenAt = now
            // 刚采到下拉条目 → 保住 0.15s 快档。这样菜单关闭的下一拍就能被扫描看见，
            // 不必等降频后的 0.3s；0.6s 后自然失效，退回省电节奏。
            menuFastUntil = now + menuFastHold
        }
        // 兜底硬上限：连续这么久一条下拉都没采到 → 当场清空，**不再看 win 的脸色**。
        // 防的是 hasOpenMenuWindow() 卡在 true 的老毛病（曾让关闭后的译文残留 25s 才消失）。
        if dropIn == 0, lastDropdownSeenAt > 0, now - lastDropdownSeenAt > menuDropdownHardCap {
            dropTTL = 0
        }
        // 2b) 「换菜单立刻清」（2026-10-13 用户报：旧菜单译文不走，撞上旁边菜单的新译文）
        //     TTL 只是**时间**判据：File→Edit 这种切换里，旧菜单的条目早已不在屏幕上，
        //     却要等 0.35s TTL 走完才消失 —— 正好压在旁边菜单刚翻出来的译文上。
        //     这里补一条**空间**判据：本帧确实采到了下拉条目（dropIn > 0）时，
        //     凡左缘不在本帧菜单簇范围内的常驻条目，立即淘汰（不等 TTL）。
        //     · 子菜单与父菜单会被**同一帧**采到，各自成簇且都在 [lo,hi] 内 → 不会互相误杀；
        //     · 本帧一条都没采到（AX 整帧掉空）时**一律不动**，仍由 TTL 兜底 ——
        //       那才是防闪的底线，这条只做「有确凿新证据」时的加速。
        if dropIn > 0 {
            var lo = CGFloat.greatestFiniteMagnitude
            var hi = -CGFloat.greatestFiniteMagnitude
            for it in raw where it.isMenu && !it.menuBarTitle {
                lo = min(lo, it.rect.minX)
                hi = max(hi, it.rect.minX)
            }
            let tol: CGFloat = 30
            var switchDead: [String] = []
            for (k, it) in stickyDropdowns where it.rect.minX < lo - tol || it.rect.minX > hi + tol {
                switchDead.append(k)
            }
            for k in switchDead {
                stickyDropdowns.removeValue(forKey: k)
                dropdownSeenAt.removeValue(forKey: k)
            }
            if !switchDead.isEmpty, now - lastMenuSwitchDiagAt > 2 {
                lastMenuSwitchDiagAt = now
                AXTextExtractor.diagLog(String(format: "MENU_SWITCH clear=%d left=%d x=[%.0f,%.0f]",
                                               switchDead.count, stickyDropdowns.count, lo, hi))
            }
        }

        var dropDead: [String] = []
        for (k, t) in dropdownSeenAt where now - t > dropTTL { dropDead.append(k) }
        // **两趟走**：遍历 dropdownSeenAt 期间绝不修改它（Swift 独占性检查，今天已被它崩过）。
        for k in dropDead {
            stickyDropdowns.removeValue(forKey: k)
            dropdownSeenAt.removeValue(forKey: k)
        }
        if !dropDead.isEmpty, now - lastDropdownClosedDiagAt > 2 {
            lastDropdownClosedDiagAt = now
            AXTextExtractor.diagLog("MENU_STICKY dropdownExpire n=\(dropDead.count) "
                + "left=\(stickyDropdowns.count) hard=\(dropTTL == 0 ? 1 : 0) "
                + "win=\(menuWinOpen ? 1 : 0)")
        }
        guard !stickyTitles.isEmpty || !stickyDropdowns.isEmpty else {
            // 常驻缓存全空：原样透传，本帧下拉条目数即是 dropIn。
            menuHoldProbe(dropIn: dropIn, menuWinOpen: menuWinOpen, dropOut: dropIn, now: now)
            return raw
        }
        // 3) 输出 = 本帧实有项 + 常驻缓存里本帧没读到的项（把缺帧那份原地补回，菜单因此不闪）。
        var outKeys = Set(raw.map { Self.menuHoldKey($0) })
        var out = raw
        var filled = 0
        for src in [stickyTitles, stickyDropdowns] {
            for (k, it) in src where !outKeys.contains(k) {
                out.append(it); outKeys.insert(k); filled += 1
            }
        }
        if filled > 0, now - lastMenuHoldDiagAt > 2 {
            lastMenuHoldDiagAt = now
            AXTextExtractor.diagLog("MENU_STICKY refill n=\(filled) "
                + "titles=\(stickyTitles.count) drops=\(stickyDropdowns.count)")
        }
        // 必须与正常帧走同一套排序（见 renderingSort 注释）：否则补帧与正常帧的
        // 条目排列不一致，下标↔内容映射每帧翻转，反而抖得更凶。
        let sorted = out.sorted(by: Self.renderingSort)
        let dropOut = sorted.filter { $0.isMenu && !$0.menuBarTitle }.count
        menuHoldProbe(dropIn: dropIn, menuWinOpen: menuWinOpen, dropOut: dropOut, now: now)
        return sorted
    }

    /// 下拉链路专用探针（独立节流 0.4s，不与 refill 抢时间戳）。
    /// 把「下拉条目在合并层到底有几条」全程摊开：`in`（本帧 raw 里的）→
    /// `sticky`（常驻缓存里的）→ `out`（最终上屏的），外加菜单窗口检测值 `win`。
    /// 任一段为 0 都能一眼看出丢在哪一环。只记计数，**不落任何屏幕文本**（隐私红线）。
    private func menuHoldProbe(dropIn: Int, menuWinOpen: Bool, dropOut: Int, now: CFTimeInterval) {
        guard now - lastDropProbeAt > 0.12 else { return }
        lastDropProbeAt = now
        AXTextExtractor.diagLog("MENU_HOLD in=\(dropIn) win=\(menuWinOpen ? 1 : 0) "
            + "sticky=\(stickyDropdowns.count) out=\(dropOut) titles=\(stickyTitles.count)")
    }

    /// 作废菜单常驻缓存（**阳性证据**驱动，绝不用"一段时间没读到"来清空）。
    /// 调用点：`TARGET_SWITCH`（换 app）/ `clearAndPush`（无目标·被排除）/ 换模式 / `stop`。
    private func clearMenuSticky(_ reason: String) {
        let n = stickyTitles.count + stickyDropdowns.count
        if n > 0 { AXTextExtractor.diagLog("MENU_STICKY clear reason=\(reason) n=\(n)") }
        stickyTitles = [:]
        stickyDropdowns = [:]
        dropdownSeenAt = [:]
        titleSeenAt = [:]
        lastDropdownSeenAt = 0
        menuFastUntil = 0
    }

    /// 菜单项粘滞用的内容键：与渲染层菜单 contentKey 同构（归一化文本 + 粗量化 midY）。
    /// 用文本而非 id：菜单项 id 每帧是随机 UUID（traverseRec 563 行），跨帧不稳定。
    private static func menuHoldKey(_ it: CapturedText) -> String {
        "\(it.text)|\(Int(it.rect.midY / 10))"
    }

    /// 坐标吸附：把矩形吸附到整数像素，从源头消除 AX/OCR 的亚像素抖动，
    /// 避免指纹误变、块位抖动。
    private func snap(_ item: CapturedText) -> CapturedText {
        var r = item.rect
        r.origin.x = r.origin.x.rounded()
        r.origin.y = r.origin.y.rounded()
        r.size.width = max(1, r.size.width.rounded())
        r.size.height = max(1, r.size.height.rounded())
        return CapturedText(id: item.id, text: item.text, rect: r,
                            source: item.source, displayText: item.displayText,
                            isMenu: item.isMenu, menuBarTitle: item.menuBarTitle,
                            axRole: item.axRole, isControl: item.isControl)
    }

    /// 仅当内容指纹真正变化时才推送，避免每帧重绘导致的闪烁。
    /// 多次变化在 80ms 内合并为一次（取最后状态），消除重绘风暴。
    /// 80ms（原 120ms）：这段是**串在首字延迟上**的固定等待，缩短后译文更"跟手"。
    private func pushUpdate(_ items: [CapturedText]) {
        let fp = fingerprint(items)
        if fp == lastFingerprint {
            // 内容与上次相同 → 不需要新的推送。
            // **但绝不能顺手清掉 pendingItems / 取消 pushTimer**（2026-10-13 修「译文迟迟不撤」）：
            // 那 0.04~0.08s 正是「内容已变化、去抖定时器还没送出去」的窗口期，
            // 此时清掉就等于把这一次更新**永久丢弃** —— 屏幕停在上一帧的旧内容，
            // 直到屏幕内容**下一次**变化才被救回来。
            // 实测（1791895494.15→1791895509.49）：引擎侧 RENDER_TITLES 早已变成 21 项
            // （菜单 sticky 在 0.35s 内就清空了），overlay 却仍挂着 33 个菜单块，整整 15 秒。
            return
        }
        lastFingerprint = fp

        // —— 空窗粘滞（修复「翻译的内容经常会自动消失」）——
        // 采集链路偶尔会有一两拍读不到东西：菜单切换的那一瞬（旧条目已作废、新条目还没回来）、
        // AX 命中测试抖动、目标 app 的 AX 树瞬间不可读。旧实现只要收到空就立刻清屏，
        // 于是屏幕上的译文「闪一下就没了」，隔一两秒又回来。
        // 现在：刚还有内容却突然变空 → 先不动屏幕，等 0.35s 确认；确认仍空才真的清屏。
        if items.isEmpty {
            if Date().timeIntervalSince(lastNonEmptyPushAt) < emptyHoldWindow {
                pendingItems = nil
                pushTimer?.invalidate(); pushTimer = nil
                scheduleEmptyConfirm()
                return
            }
        } else {
            lastNonEmptyPushAt = Date()
            emptyHoldTimer?.invalidate(); emptyHoldTimer = nil
        }

        pendingItems = items
        if pushTimer == nil {
            // 菜单打开时去抖压到 0.04s：菜单是「盯着等」的场景，每一拍都要尽快上屏。
            // 菜单**刚关**的冷却期内同样用快档 —— 这一段正是要尽快把译文撤下来的时候，
            // 若此刻退回 0.08s 就等于在用户还在看的页面上多赖半拍。
            let delay = (menuOpenNow || CACurrentMediaTime() < menuFastUntil) ? 0.04 : 0.08
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.pushTimer = nil
                if let items = self.pendingItems {
                    self.pendingItems = nil
                    self.onUpdate?(items)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pushTimer = t
        }
    }

    /// 空窗确认：延时后再看一眼，仍为空才真的清空覆盖层。
    private func scheduleEmptyConfirm() {
        guard emptyHoldTimer == nil else { return }
        let t = Timer(timeInterval: emptyHoldConfirm, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.emptyHoldTimer = nil
            if self.currentItems.isEmpty {
                AXTextExtractor.diagLog("OVERLAY_CLEARED bid=\(AXTextExtractor.shared.currentTarget()?.bundleIdentifier ?? "nil")")
                // 必须顺手作废指纹，否则「同一屏内容回来」会被去抖拦掉（见下方 staleTimer 处注释）。
                self.lastFingerprint = nil
                self.onUpdate?([])
            }
        }
        RunLoop.main.add(t, forMode: .common)
        emptyHoldTimer = t
    }

    /// 内容指纹：显示文本 + 圆整坐标，用于去抖（译文到达时触发一次重绘）。
    private func fingerprint(_ items: [CapturedText]) -> String {
        items.map { "\($0.displayText)|\(Int($0.rect.origin.x.rounded())):\(Int($0.rect.origin.y.rounded()))" }
            .sorted().joined(separator: ";")
    }

    /// 容差去重：同文本且位置接近 视为同一项。消除 AX 抖动重复与 AX/OCR 双重识别。
    ///
    /// 2026-10-13 收紧（用户报 IMDb 顶部「观察列表 观察列表」同一处译文叠了两遍）：
    /// 旧判据只看「原点相距 < 16pt」。但网页里**父元素与子元素文本天然重复**：
    /// `AXLink` 的矩形含前面的图标（宽）→ 它和里面的 `AXStaticText`（只含文字）原点
    /// 相差恰好一个图标宽（实测 ≈40pt）→ 漏过 → 两个条目都被翻译 → 两块译文叠在一起。
    /// 新判据：文本相同**或互为子串**，只要**矩形相交**（同处文字）即去重；
    /// 否则退回原来的 16pt 邻近判据（兼容 AX/OCR 抖动）。
    /// 保留先出现的那条（遍历顺序：父在前、子在后）→ 留下矩形更大的父元素，
    /// 块能盖住「图标 + 文字」整块，不再露出 `ro` / `n in` 这类残字。
    private func dedup(_ items: [CapturedText]) -> [CapturedText] {
        var out: [CapturedText] = []
        for it in items {
            let dup = out.contains { prev in
                let sameText = prev.text == it.text
                    || prev.text.contains(it.text)
                    || it.text.contains(prev.text)
                guard sameText, !it.text.isEmpty else { return false }
                let inter = prev.rect.intersection(it.rect)
                if !inter.isNull, inter.width > 1, inter.height > 1 { return true }
                return abs(prev.rect.origin.x - it.rect.origin.x) < 16
                    && abs(prev.rect.origin.y - it.rect.origin.y) < 16
            }
            if dup { continue }
            out.append(it)
        }
        return out
    }

    // MARK: - 翻译合并

    /// 渲染：始终基于「当前屏幕内容（lastRaw）」上屏，浮层不再因翻译缓存未命中而消失。
    ///
    /// 两条铁律（修"快速移动鼠标 → 浮层清空 → 只剩原文"）：
    /// ① lastRaw 非空 → 每一项都上屏：已翻译且译文≠原文显示译文；
    ///    其余（缓存未命中 / 引擎回退为原文）一律「原文占位」立即上屏。
    ///    这样 currentItems 在快速移动时始终保持非空 → 不会触发清空逻辑，
    ///    且块始终盖在当前屏幕的原词上（不串位）。译文到位后由 applyTranslation→render 原地替换。
    /// ② lastRaw 为空（AX 偶发空扫）→ 保留上一帧、不推送、不清空；
    ///    仅当持续空窗超过 staleTimeout 才认定真无内容并清空（见 staleTimer）。
    private func render() {
        // —— ② 真·空扫：AX 瞬时返回 0（快速移动 / 在别的 app 打字时窗口服务器繁忙常见）——
        // 保留上一帧浮层（currentItems 不变），启动持续空窗计时；
        // 下一拍正常扫描即作废该计时，浮层继续正常刷新，绝不会"闪一下没了"。
        guard !lastRaw.isEmpty else {
            // 打字冻结：用户在别的 app 里打字时，被查看的 app（如 Xcode）AX 扫描偶发空，
            // 照常清屏会主观"打字就不翻译了"。打字期间（近期有键盘活动）直接冻结上一帧，
            // 不启动清空计时；松手 >typingWindow 后下一拍正常扫描恢复，译文随鼠标/界面刷新。
            let typing = CACurrentMediaTime() - CaptureEngine.lastKeyAt < typingWindow
            if typing {
                AXTextExtractor.diagLog("FREEZE typing bid=\(AXTextExtractor.shared.currentTarget()?.bundleIdentifier ?? "nil") lastItems=\(currentItems.count)")
                return
            }
            if staleTimer == nil {
                staleTimer = Timer.scheduledTimer(withTimeInterval: staleTimeout, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.staleTimer = nil
                    if self.lastRaw.isEmpty {
                        AXTextExtractor.diagLog("OVERLAY_CLEARED_STALE bid=\(AXTextExtractor.shared.currentTarget()?.bundleIdentifier ?? "nil")")
                        // —— 清屏必须同时作废内容指纹（2026-10-13 修「翻译内容自动消失」）——
                        // `pushUpdate` 是唯一写 `lastFingerprint` 的地方，且指纹相同就**直接 return 不推送**。
                        // 这里绕过了 pushUpdate 直接清屏，若不作废指纹，就会出现：
                        //   内容 X 正常显示（指纹 = fp(X)）→ 空窗 >2s 触发清屏（指纹仍是 fp(X)）
                        //   → 采集恢复、**回来的还是同一屏 X** → pushUpdate(X) 指纹相同 → 永不推送
                        //   → 覆盖层空白，直到屏幕内容发生任何一次变化。
                        // 这正是「翻译经常自动消失」里最难复现的那一支（要求内容完全不变地回来）。
                        // 其余四处（start / stop / invalidateTranslations / setPaused(false)）都已重置，唯独漏了这两处。
                        self.lastFingerprint = nil
                        self.currentItems = []
                        self.onUpdate?([])
                    }
                }
            }
            return
        }
        staleTimer?.invalidate(); staleTimer = nil

        // —— ① 基于当前内容上屏：译文或原文占位 ——
        var out: [CapturedText] = []
        var seen = Set<String>()
        // —— 菜单栏最左两项：照常遮挡，但**不翻译、块里直接放原文**（2026-10-13 用户拍板）——
        // ① 最左 = 苹果菜单：AX 吐出的描述文字会被误译成「App」；
        // ② 第二左 = App 名菜单（如 Xcode）：应用自己的名字，没有翻译的必要。
        // 用户原话：「改回遮挡，这样风格统一，只是前两个直接复制原文就好」。
        // 所以这两项**照常画毛玻璃块**（与其余菜单标题视觉一致），内容不送翻译引擎。
        //
        // 判据演进（三次回归，别再走回头路）：
        // ·「标题数 ≥ 2 才打标」已失效（实测 Safari）：中文系统下其余中文标题
        //   会被 isTranslatable 判为「无需翻译」过滤掉，常常**只剩苹果菜单孤零零一项**
        //   （日志 MENUITEMS titles=10 → RENDER_TITLES n=1），`count >= 2` 不成立
        //   → 苹果标被当普通文本翻译 → 用户看到左上角显示「App」。
        // ·「minX < 60 就是苹果菜单」也已弃用：App 名菜单的起点同样可能落在最左，
        //   于是被当成苹果菜单 → 显示成私有区字符 → 用户报「软件名那个不见了」。
        // ·现判据（用户 2026-10-13 拍板「改成精确相等」）：**菜单栏标题文本 == 目标 app 名**
        //   （归一化：去空格 + 小写）。用 == 而非 contains，是为了避免 app 名 "Finder"
        //   把菜单 "Find" 也吃掉、令其永远不翻译。代价：localizedName 与菜单标题差版本号时
        //   （"Final Draft" ↔ "Final Draft 13"）认不出，该项按普通菜单翻译——
        //   **宁可漏认，也不错杀真菜单**。
        let mbTitles = lastRaw.filter { $0.menuBarTitle }.sorted { $0.rect.minX < $1.rect.minX }
        var appleMenuId: UUID?
        var keepOriginalIds = Set<UUID>()
        // —— 苹果菜单那一格的几何（供「没被 AX 采集到时合成块」使用）——
        // 实测（2026-10-13 只读 AX 探针，19 个 app × 2 块屏）：AXMenuBar 的第 0 个子项
        // 恒为苹果菜单，frame = {屏幕左缘 + 10, 宽 34}；第 1 个子项（App 名）恒从
        // 屏幕左缘 + 43 起，跨 app、跨屏幕完全一致（副屏 app 同样是 2048+10 / 2048+43）。
        // 定位方式：拿**任意一个已采集到的菜单栏标题**找它所在的那块屏，再按常量推苹果格，
        // 于是与「最左那项究竟是苹果菜单还是 App 名」无关——中文 App 名常被判为无需翻译
        // 而被过滤掉，不能拿它当锚点（否则会算出错误位置）。
        var appleCell: NSRect?
        if let first = mbTitles.first {
            let scr = NSScreen.screens.first { s in
                first.rect.minX >= s.frame.minX - 1 && first.rect.minX <= s.frame.maxX + 1
            } ?? NSScreen.main
            if let s = scr {
                let x = s.frame.minX + Self.appleCellInset
                // 宽度取实测 34，但若最左标题正好是紧邻的 App 名，就收到它的左缘，
                // 避免与 App 名块重叠 1pt（系统自身这两格就有 1pt 交叠）。
                let w = max(8, min(Self.appleCellWidth, first.rect.minX - x))
                appleCell = NSRect(x: x, y: first.rect.minY, width: w, height: first.rect.height)
            }
        }
        let norm: (String) -> String = { $0.lowercased().replacingOccurrences(of: " ", with: "") }
        let appKey = norm(AXTextExtractor.shared.currentTarget()?.localizedName ?? "")
        let isAppNameItem = { (t: CapturedText) -> Bool in
            guard !appKey.isEmpty else { return false }
            return norm(t.text) == appKey            // 精确相等（用户拍板）
        }
        if let first = mbTitles.first {
            if isAppNameItem(first) {
                // 苹果菜单没进列表（它的标题通常不可显示、不被收录），最左就是 App 名。
                keepOriginalIds.insert(first.id)
            } else if let ac = appleCell, abs(first.rect.minX - ac.minX) <= 6 {
                // 位置正落在苹果格上 → 只可能是苹果菜单（AX 偶尔会把它的标题报出来）。
                // 判据收紧到「几何命中」（旧版 minX < 45 会把位于 x≈43 的 App 名也当成苹果菜单，
                // 于是 App 名位置被画成   ——这正是更早那次「软件名那个不见了」的成因）。
                appleMenuId = first.id
                keepOriginalIds.insert(first.id)
                // 第二左 = App 名（按名字确认，认不出就不动它）
                if mbTitles.count >= 2, isAppNameItem(mbTitles[1]) { keepOriginalIds.insert(mbTitles[1].id) }
            } else if mbTitles.count >= 2, isAppNameItem(mbTitles[1]) {
                // 位置判据不成立但第二项确实是 App 名 → 最左那项一律不当成苹果菜单，
                // 只保留 App 名的原文。绝不把 File / Edit 这些真菜单当苹果标吃掉。
                keepOriginalIds.insert(mbTitles[1].id)
            }
        }
        // 临时诊断（验收后删）：菜单栏前两项的识别结果。
        // 只记数量、位置与长度，**不落任何菜单文字**（隐私红线）。
        if CACurrentMediaTime() - lastMenuSkipDiagAt > 2, !mbTitles.isEmpty {
            lastMenuSkipDiagAt = CACurrentMediaTime()
            let kinds = mbTitles.prefix(5)
                .map { "\(Int($0.rect.minX)):\($0.text.count)" }
                .joined(separator: " ")
            AXTextExtractor.diagLog("MENUSKIP titles=\(mbTitles.count) keep=\(keepOriginalIds.count) "
                + "apple=\(appleMenuId != nil ? 1 : 0) appKeyLen=\(appKey.count) "
                + "firstIsApp=\(mbTitles.first.map { isAppNameItem($0) ? 1 : 0 } ?? -1) "
                + "cell=\(appleCell.map { "\(Int($0.minX))x\(Int($0.width))" } ?? "nil") "
                + "synth=\((appleMenuId == nil && appleCell != nil) ? 1 : 0) "
                + "in=[\(kinds)]")
        }

        for item in lastRaw {
            seen.insert(item.text)
            if keepOriginalIds.contains(item.id) {
                // 苹果菜单 / App 名：**照常遮挡，只是不翻译**（用户 2026-10-13 拍板：
                // 「改回遮挡，这样风格统一，只是前两个直接复制原文就好」）。
                // 与其余菜单标题画**一模一样的毛玻璃块**，块里直接放原文，且不发起翻译请求。
                //
                // —— 苹果菜单：照常遮挡，块里直接放着  标志（2026-10-13 用户拍板）——
                // 旧版因为标题是 Unicode 私有区字符（U+F8FF）就**整个跳过不画块**，
                // 于是菜单栏最左一格永远空着。2026-10-13 实测澄清了两件事：
                //   ① 系统字体**有**这个字形（glyph 2601，与块内实际用的
                //      `.AppleSystemUIFontMedium` 同族，2 个子路径＝苹果身 + 叶子，
                //      8.98×9.85pt），渲染出来是**纯黑白**（位图只有白底 + 黑灰像素），
                //      不是彩色 emoji、也不是豆腐块；
                //   ② 菜单栏标题块的宽度恒等于 AX 标题矩形宽、字居中（见 TranslationBlock），
                //      所以块正好盖住标志那一格，不会再压到隔壁 App 名（旧 `Xco🍎de` 的根因
                //      是那时块宽随估宽乱扩，现已由「块宽 = 矩形宽」这条铁律锁住）。
                // 故：画与其它标题一模一样的毛玻璃块，块里**只放这一个标志字符**——
                // 不管 AX 返回的标题里还夹了什么，也不发翻译请求。
                if item.id == appleMenuId {
                    var it = item
                    it.displayText = Self.appleGlyph
                    out.append(it)
                    continue
                }
                // 其余含私有区字符的项（极端情况下的怪标题）：仍不画块，维持旧行为。
                if Self.hasPrivateUseChar(item.text) { continue }
                var it = item
                it.displayText = item.text
                out.append(it)
                continue
            }
            let tr = translations[item.text]
            if let tr, tr != item.text {
                var it = item
                it.displayText = tr
                out.append(it)
            } else {
                // 未翻译：原文占位立即上屏（块盖在原词上，视觉一致）；
                // 同时发起翻译请求，到位后原地替换为译文。
                if tr == nil { requestTranslation(text: item.text) }
                var it = item
                it.displayText = item.text
                out.append(it)
            }
        }
        // —— 苹果菜单没被 AX 采集到时：合成一个苹果标块（用户 2026-10-13 拍板）——
        // 实测 harvestMenus 不收录苹果菜单（Xcode / IINA / Final Draft… 采集结果一律从
        // 位于 x≈43 的 App 名起头，日志 MENUSKIP apple=0），所以上面的 `item.id == appleMenuId`
        // 分支绝大多数时候根本轮不到 → 菜单栏最左一格永远空着（用户报「苹果标没有显示」）。
        // 这里按实测常量几何补一个块：与其它菜单标题画**一模一样的毛玻璃块**，
        // 块里只放   这一个字符，且不发起翻译请求。
        if appleMenuId == nil, let ac = appleCell {
            out.append(CapturedText(id: appleSyntheticId, text: Self.appleGlyph, rect: ac,
                                    source: .ax, displayText: Self.appleGlyph,
                                    isMenu: true, menuBarTitle: true,
                                    axRole: "AXMenuBarItem", isControl: true))
        }
        // 重试机会只保留给"仍在屏幕上"的文本：条目消失后再出现时重新给机会（防历史失败占坑）
        attempts = attempts.filter { seen.contains($0.key) }
        retryAfter = retryAfter.filter { seen.contains($0.key) }
        currentItems = out
        if currentItems.count > maxItems { currentItems = Array(currentItems.prefix(maxItems)) }
        let tn = currentItems.filter { $0.isMenu && $0.menuBarTitle }.count
        AXTextExtractor.diagLog("RENDER_TITLES n=\(tn) total=\(currentItems.count) lastRaw=\(lastRaw.count)")
        pushUpdate(currentItems)
    }

    private func requestTranslation(text: String) {
        // 同一次出现期间：失败退避重试（0.4s 起指数增长），总次数上限 20 次。
        // 次数放宽 + 时间冷却的意义：会话重建 / 引擎瞬时繁忙造成的失败，等一会儿就能补上；
        // 旧实现 6 次上限会在几百毫秒内被瞬间打满，文本就永久不翻了。
        guard (attempts[text] ?? 0) < 20, !pending.contains(text) else { return }
        if let at = retryAfter[text], at > Date() { return }   // 冷却中，下一轮再试
        pending.insert(text)
        Task { [weak self] in
            let tr = await Translator.shared.translate(text)
            // CaptureEngine 不符合 Sendable（内含大量仅主线程访问的可变状态），
            // 直接捕获进 @Sendable 闭包在 Swift 6 是硬错误。这里把 weak self 转存为
            // nonisolated(unsafe) 局部量：下文只在主队列里用它，与既有线程模型完全一致。
            nonisolated(unsafe) let engine = self
            DispatchQueue.main.async {
                engine?.pending.remove(text)
                engine?.applyTranslation(text: text, translation: tr)
            }
        }
    }

    /// 译文到位：成功才写入译文表；失败（回退原文）只记次数，下一轮渲染自动再试。
    private func applyTranslation(text: String, translation: String) {
        evictTranslationsIfNeeded()
        if translation == text {
            let n = (attempts[text] ?? 0) + 1
            attempts[text] = n
            // 失败退避（关键修复）：旧实现只数「次数上限 6」，而失败会在一瞬间连续打满——
            // 每轮 tick 都重新请求、一次往返仅百余毫秒，于是文本在屏幕上停留多久都再也不翻
            // （用户报的「经常有的不翻译」）。现在改成**时间冷却 + 指数退避**：
            // 0.4s → 0.8 → 1.6 → 3.2 → 6.4（上限 6s），把重试摊在时间轴上。
            // 这样瞬时失败（会话重建中 / 引擎忙）能自动恢复，不会把一条文本永久钉死。
            let delay = min(0.4 * pow(2, Double(min(n - 1, 4))), 6)
            retryAfter[text] = Date().addingTimeInterval(delay)
        } else {
            attempts[text] = nil
            retryAfter[text] = nil
            if translations[text] == nil { translationOrder.append(text) }
            translations[text] = translation
        }
        render()
    }

    /// 译文表 LRU 淘汰：超过 4000 条时丢掉最旧的四分之一。
    /// 绝不再用 `removeAll()` —— 那会让屏幕上正在显示的译文**同时**失去缓存，
    /// 表现就是「翻译的内容突然全没了」，要等一轮重新翻译才回来。
    private func evictTranslationsIfNeeded() {
        guard translations.count > 4000 else { return }
        let dropCount = 1000
        let dropped = Set(translationOrder.prefix(dropCount))
        for k in dropped { translations.removeValue(forKey: k) }
        translationOrder.removeFirst(min(dropCount, translationOrder.count))
    }

    // MARK: - 工具

    /// 找到包含给定区域中心的显示器。
    static func displayContaining(region: NSRect) -> (frame: NSRect, displayID: CGDirectDisplayID) {
        let center = CGPoint(x: region.midX, y: region.midY)
        for s in NSScreen.screens {
            if s.frame.contains(center) {
                let id = s.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
                return (s.frame, id)
            }
        }
        let m = NSScreen.main!
        let id = m.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return (m.frame, id)
    }
}
