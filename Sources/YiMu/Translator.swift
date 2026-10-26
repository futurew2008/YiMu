import Foundation
import SwiftUI
import Translation
import NaturalLanguage
import Combine
import CryptoKit

/// 隐藏的 SwiftUI 桥接：通过 `.translationTask` 拿到框架提供的 TranslationSession。
/// 原因：Translation 框架在纯 AppKit 下需要 SwiftUI 环境才能创建会话（WWDC24 限制），
/// 用一个 1×1 隐藏 hosting 视图挂载到主窗口即可解锁，从而把离线翻译能力暴露给 AppKit 层。
private final class TranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var onSession: ((TranslationSession) -> Void)?
}

private struct TranslationBridgeView: View {
    @ObservedObject var model: TranslationBridgeModel
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                model.onSession?(session)
            }
    }
}

/// 离线翻译封装：基于 Apple 原生 Translation 框架（完全本地、零外发，契合隐私铁律）。
///
/// - 用隐藏的 SwiftUI 宿主通过 `translationTask` 获取 `TranslationSession`；source 传 nil 表示自动识别源语言。
/// - 首次翻译若语言包未下载，框架会请求下载（需用户在系统设置同意）；失败时回退原文，不崩溃。
/// - 译文走内存 LRU 缓存（纯本地），同文不重翻、越用越快。
@MainActor
final class Translator {
    static let shared = Translator()

    private let model = TranslationBridgeModel()
    private var hosting: NSHostingController<TranslationBridgeView>?
    private var session: TranslationSession?
    private var preparedSource: Locale.Language?
    private var preparedTarget: Locale.Language?

    // 译文缓存：内存为主、磁盘兜底。运行时命中内存即秒回；磁盘在启动时预热、去抖落盘，
    // 实现跨会话复用——这就是"快速调出翻译"的关键。
    private var cache = [String: String]()
    private var order: [String] = []
    private let cacheLimit = 5000
    private var saveTimer: Timer?
    private var sessionContinuation: CheckedContinuation<Void, Never>?

    /// 落盘缓存路径：~/Library/Application Support/YiMu/translationCache.json
    private let cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YiMu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("translationCache.json")
    }()

    private init() {
        model.onSession = { [weak self] s in
            guard let self else { return }
            self.session = s
            self.sessionContinuation?.resume()
            self.sessionContinuation = nil
        }
        loadCacheFromDisk()
    }

    /// 启动时从磁盘预热 LRU（保持顺序，保证淘汰正确）。
    ///
    /// 顺带完成**明文缓存的一次性迁移**：磁盘上若还是旧格式（key 里是原文明文），
    /// 就地转成哈希 key 保留译文，然后立即写回——**抹掉磁盘上的明文**，
    /// 而不是让它们继续躺在那里。迁移只跑一次（下次启动 key 都带 `h1:` 前缀）。
    private func loadCacheFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL),
              let arr = try? JSONDecoder().decode([[String]].self, from: data) else { return }
        var migrated = false
        for kv in arr where kv.count == 2 {
            let key = kv[0]
            let val = kv[1]
            if Self.isHashedKey(key) {
                cache[key] = val
                order.append(key)
                continue
            }
            // —— 旧格式（key 内是原文明文）——
            guard let idx = key.firstIndex(of: "|") else { continue }
            let dirPrefix = String(key[..<idx])
            let plain = String(key[key.index(after: idx)...])
            // 历史 BUG 兜底：旧版本把翻译失败的原文也写进了缓存（值 == 原文），
            // 这些词会被"永久钉死不翻译"。迁移时（此刻手里还有明文）直接丢弃。
            if plain == val { continue }
            let nk = Self.hashedKey(dirPrefix: dirPrefix, text: plain)
            cache[nk] = val
            order.append(nk)
            migrated = true
        }
        // 立刻用新格式覆盖，磁盘上不再留明文。
        if migrated { saveNow() }
    }

    /// 把隐藏的 SwiftUI 宿主挂到主窗口内容视图，激活翻译环境（AppDelegate 初始化后调用一次）。
    func attachHosting(to parent: NSView) {
        guard hosting == nil else { return }
        let hc = NSHostingController(rootView: TranslationBridgeView(model: model))
        hc.view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        hc.view.isHidden = true
        parent.addSubview(hc.view)
        hosting = hc
    }

    /// 创建/复用翻译会话。source 为 nil 表示用户选了「自动识别」。
    ///
    /// **铁律 1：绝不给系统传 nil 源。** 系统的自动识别失败时会弹模态「选择语言」框，
    /// 卡死整条翻译链。改用本地检测决定源语言（见 translateBatch）。
    /// **铁律 2：绝不碰未安装的语言包。** 语言包未下载时，SwiftUI translationTask
    /// 会对每个新语言方向自动弹「Download Languages to Translate」下载框——
    /// 屏幕上出现几种语言就弹几次，疯狂循环。故先用 `LanguageAvailability` 预检：
    /// 非 `.installed` 一律跳过（返回 false），宁可这批不翻，也绝不弹下载框。
    /// 用户可到 设置 → 通用 → 语言与地区（或系统「翻译」App）手动下载语言包。
    /// 由 UI 层在**语言方向变化**时调用一次，记录"用户选定的源语言"与目标语言。
    ///
    /// 为什么不写在 `prepare` 里（这是个真 BUG）：`prepare` 在每批翻译前都会按
    /// **检测出的语言分组**被调用一次。在那里写 `preferredCode`，就会被"当前这一组的语言"
    /// 覆盖——后续所有低置信度短词（菜单项大多是短词）都回退到这个被污染的语言，
    /// 若该语言包未安装，整组直接回落原文 → 用户看到的「经常有的不翻译」。
    func setDirection(sourceCode: String?, targetCode: String) {
        preferredCode = sourceCode
        self.targetCode = targetCode
    }

    @discardableResult
    func prepare(source: Locale.Language?, target: Locale.Language) async -> Bool {
        // 预热用确定源语言；自动模式下先用英语占位，实际翻译按批内检测结果重定向
        let effective = source ?? Locale.Language(identifier: "en")

        // —— 语言包预检 ——
        // 未安装的方向直接放弃，绝不触发框架的下载 sheet（否则每个新语言方向弹一次下载框）。
        // 结果带缓存：`LanguageAvailability().status` 是跨进程 async 查询，每批每组都查会明显拖慢；
        // 成功结果长期有效，失败结果只缓存 60 秒——用户随后在系统里下好语言包能自动恢复翻译。
        let key = "\(effective.minimalIdentifier)>\(target.minimalIdentifier)"
        let now = Date()
        var installed: Bool
        if let c = availabilityCache[key], c.ok || now.timeIntervalSince(c.at) < 60 {
            installed = c.ok
        } else {
            installed = await LanguageAvailability().status(from: effective, to: target) == .installed
            availabilityCache[key] = (installed, now)
        }
        if !installed {
            missingNotice = "\(displayName(effective)) → \(displayName(target)) 语言包未下载，该方向暂不翻译"
            return false
        }
        missingNotice = nil

        guard effective != preparedSource || target != preparedTarget || session == nil else { return true }
        preparedSource = effective
        preparedTarget = target
        // 连续切换语言时，若上一次的 continuation 还没被回调，必须先放行，
        // 否则它会被覆盖后永久挂起（表现为「切换语言后翻译再也不出结果」）。
        if let stale = sessionContinuation {
            sessionContinuation = nil
            stale.resume()
        }
        await withCheckedContinuation { cont in
            sessionContinuation = cont
            // 铁律：Configuration 必须用 effective（非空源），绝不能透传 nil——
            // 之前这里传了原始 source（自动模式 = nil），导致预热的会话就是 nil 源；
            // 而 translateBatch 按组 re-prepare 时 guard 又因 preparedSource 已是
            // effective 而提前返回 → 永远在用 nil 源会话翻译 → 系统检测失败即弹
            // 模态 Choose Language 框，并把整条翻译队列卡死（菜单全灭的元凶）。
            model.configuration = TranslationSession.Configuration(source: effective, target: target)
        }
        return true
    }

    /// 状态栏菜单提示：当前缺失的语言包（nil = 一切就绪）。
    private(set) var missingNotice: String?

    /// 语言显示名（本地化到系统语言）。
    private func displayName(_ lang: Locale.Language) -> String {
        Locale.current.localizedString(forLanguageCode: lang.languageCode?.identifier ?? "") ?? lang.minimalIdentifier
    }

    // MARK: - 批量翻译队列

    /// 离线翻译引擎不支持高并发：进入融合瞬间几十条请求一起砸过去，
    /// 只有最先几条成功、其余瞬时失败（表现就是"很多单词永远不翻译"）。
    /// 但纯串行逐条又太慢——整屏 60 条文本要几十秒才陆续出齐，观感就是"很多没翻译"。
    /// 折中方案：**攒批** —— 120ms 窗口内到达的请求合成一批（≤24 条），
    /// 用 `translations(for:)` 一次引擎调用整批翻完；批量失败再逐条兜底（带重试）。
    private var queue: [(text: String, cont: CheckedContinuation<String, Never>)] = []
    private var pumping = false
    /// 极速档开关：有下拉菜单打开时置真（由 CaptureEngine 每轮写入）。
    /// 生效点只有两个——攒批窗口 70ms→40ms、批上限 12→16，其余逻辑完全不变。
    /// `nonisolated(unsafe)`：写入方在 AX 轮询（非 actor 上下文，但实为主线程）里，
    /// 读取方都在 MainActor 上；一个 Bool 的读写无需隔离保护，加隔离反而要每次包 Task。
    nonisolated(unsafe) var turbo = false

    /// 翻译一段文本：命中缓存立即返回；未命中排队攒批走离线翻译；失败回退原文且**不写缓存**。
    func translate(_ text: String) async -> String {
        // 纯符号 / 图标字符（如 Apple Logo U+F8FF、"⌘"）不进引擎：
        // 系统框架会把  特判翻成「苹果」，出现莫名其妙的译文块。
        // 原样返回 → render 层「译文 == 原文则静默」规则会让块彻底消失。
        var hasLetter = false
        for ch in text.unicodeScalars {
            if CharacterSet.letters.contains(ch) || (ch.value >= 0x4E00 && ch.value <= 0x9FFF) {
                hasLetter = true
                break
            }
        }
        guard hasLetter else { return text }
        // 术语表优先于缓存：官方译法直出，且能把历史上被污染的错误缓存（Find→「突破」）直接绕开。
        if let fixed = terminologyOverride(text) { return fixed }
        let key = cacheKey(text)
        if let cached = cache[key] { return cached }
        // 注意：session 为 nil（预热失败/语言包未装）也放行入队——
        // translateBatch 每批都会重新预检语言包状态，包一装好自动恢复翻译（自愈）。
        return await withCheckedContinuation { cont in
            queue.append((text, cont))
            pump()
        }
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task { [weak self] in
            // 攒批窗口 70ms（原 120ms）：这段是**串在首字延迟上的固定等待**。
            // 窗口仍足够让同一帧涌入的请求聚成一批，但整体更快"跟手"。
            // 菜单打开时（turbo）压到 40ms：人正盯着菜单等译文，这点等待最刺眼。
            try? await Task.sleep(nanoseconds: (self?.turbo == true) ? 40_000_000 : 70_000_000)
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            // 取一批：同批去重，命中缓存的直接返回
            var batch: [(text: String, cont: CheckedContinuation<String, Never>)] = []
            var seen = Set<String>()
            // 批上限 12（原 24）：引擎的 `translations(from:)` 是等整批翻完才返回的，
            // 批越大"第一屏译文"出现得越晚。切成小批让结果更快滚动出来，
            // 主观上从"半天没反应"变成"一行行陆续出现"。
            // 菜单打开时（turbo）放宽到 16：菜单一次涌入的条目多（常见 20~40 项），
            // 批太小会让最后几项多等好几轮 —— 这时"整体翻完"比"首行多快"更重要。
            let batchCap = turbo ? 16 : 12
            while !queue.isEmpty, batch.count < batchCap {
                let job = queue.removeFirst()
                if seen.contains(job.text) {
                    job.cont.resume(returning: job.text)
                    continue
                }
                seen.insert(job.text)
                if let cached = cache[cacheKey(job.text)] {
                    job.cont.resume(returning: cached)
                    continue
                }
                batch.append(job)
            }
            guard !batch.isEmpty else { continue }
            await translateBatch(batch)
        }
        pumping = false
    }

    /// 一次引擎调用翻整批；失败降级为逐条（每条自带 1 次重试）。
    ///
    /// **云端分支（2026-10-14）**：后端不是 `.apple` 时整批交给 `CloudTranslator`，
    /// 不经 Apple 会话、不做语言包预检（云端自带自动检测）。原文会发往对应服务商。
    ///
    /// **语言策略（修复两个用户报告的 BUG）**
    /// - 反复弹「选择语言」：根因是用 nil 源建会话，系统检测失败就弹模态框。
    ///   现改为本地 `NLLanguageRecognizer` 逐条检测、按语言分组，每组用**确定源语言**的会话翻。
    /// - 选定源语言后其他语言不翻：选定源语言现在只是「首选」（低置信回退），
    ///   检测出其他受支持语言的文本照样分组翻译，不再被限定。
    /// - 检测结果 == 目标语言 → 无需翻译，直接原文返回（上层静默不显示）。
    private func translateBatch(_ batch: [(text: String, cont: CheckedContinuation<String, Never>)]) async {
        // —— 云端分支（2026-10-14）——
        // 非 Apple 后端：整批交给云端翻译，跳过 Apple 会话与语言包预检。
        if Preferences.shared.translationBackend != .apple {
            await translateBatchCloud(batch)
            return
        }

        // 1) 本地语言检测，按源语言分组（全部本地完成，零弹窗、零外发）
        var groups: [String: [(text: String, cont: CheckedContinuation<String, Never>)]] = [:]
        let dominant = dominantLanguage(of: batch.map { $0.text })
        for job in batch {
            guard let code = sourceCode(for: job.text, dominant: dominant) else {
                job.cont.resume(returning: job.text)   // 测不出且无回退 → 静默跳过
                continue
            }
            if code == targetCode {
                job.cont.resume(returning: job.text)   // 已是目标语言，无需翻译
                continue
            }
            groups[code, default: []].append(job)
        }
        // 2) 每组用确定源语言的会话翻译；语言包缺失的组整组静默跳过（绝不弹下载框）
        let target = preparedTarget ?? Locale.Language(identifier: "zh-Hans")
        for (code, jobs) in groups {
            var ok = await prepare(source: Locale.Language(identifier: code), target: target)
            if !ok, let dom = dominant, dom != code {
                // 该语言包未安装 —— 大概率是短词被检测误判成了小众语言（菜单项极易发生，
                // 例如某些短词会被判成法语/德语）。界面文本几乎同属一种语言，
                // 回退到本批主流语言再试一次，不因一个误判词丢掉整组（「经常有的不翻译」）。
                ok = await prepare(source: Locale.Language(identifier: dom), target: target)
            }
            guard ok else {
                for job in jobs { job.cont.resume(returning: job.text) }   // 原文返回 → 渲染层静默，不显示块
                continue
            }
            await runGroup(jobs)
        }
    }

    // MARK: - 云端批量翻译（非 Apple 引擎）

    /// 把整批直接发给云端翻译器；输入/输出按下标对齐。
    /// 失败（无 key / 网络 / 限流）时整批回退原文，绝不卡死队列。
    private func translateBatchCloud(_ batch: [(text: String, cont: CheckedContinuation<String, Never>)]) async {
        let backend = Preferences.shared.translationBackend
        let target = preparedTarget?.minimalIdentifier ?? targetCode
        let texts = batch.map { $0.text }
        // 用本批主流语言作 source；若等于目标语言则让云端自动检测（传 nil）。
        let dominant = dominantLanguage(of: texts)
        let source: String? = (dominant == target) ? nil : dominant

        let results: [String]
        do {
            let key = KeychainHelper.get(backend.keychainService) ?? ""
            if backend == .microsoft {
                results = try await CloudTranslator.translate(texts, from: source, to: target,
                                                            backend: backend, apiKey: key,
                                                            region: Preferences.shared.microsoftRegion)
            } else {
                results = try await CloudTranslator.translate(texts, from: source, to: target,
                                                            backend: backend, apiKey: key)
            }
        } catch {
            for job in batch { job.cont.resume(returning: job.text) }
            return
        }

        for (i, job) in batch.enumerated() {
            let out = (i < results.count && !results[i].isEmpty) ? results[i] : job.text
            if out != job.text { store(cacheKey(job.text), out) }
            job.cont.resume(returning: out)
        }
    }

    private func runGroup(_ jobs: [(text: String, cont: CheckedContinuation<String, Never>)]) async {
        guard let session else {
            for job in jobs { job.cont.resume(returning: job.text) }
            return
        }
        let texts = jobs.map { $0.text }
        do {
            // 一次引擎调用翻整批（官方批量接口），速度提升一个数量级
            let requests = texts.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            // —— 按下标配对，**不用 zip**（2026-10-13 修「某条文本永久不再翻译」）——
            // 引擎返回的响应数少于请求数时（批量接口部分失败 / 会话中途被 prepare 重建），
            // `zip` 会按较短者截断 → 多出来的 job 的 CheckedContinuation **永不 resume** →
            // 调用方（CaptureEngine.requestTranslation）的 `pending.remove(text)` 永不执行 →
            // 该文本被判定「已在队列中」→ 此后在屏幕上停留多久都不再翻译，**只能重启 app**。
            // 按下标逐条处理，保证每一条 job 恰好 resume 一次；拿不到结果的回退原文（下一轮会重试）。
            for (i, job) in jobs.enumerated() {
                let out: String
                if i < responses.count {
                    out = responses[i].targetText.isEmpty ? job.text : responses[i].targetText
                } else {
                    out = job.text
                }
                if out != job.text { store(cacheKey(job.text), out) }
                job.cont.resume(returning: out)
            }
            return
        } catch {
            // 批量接口失败（个别引擎版本不支持 / 会话失效）→ 逐条兜底，保证不出局
        }
        for job in jobs {
            let out = await performTranslate(job.text)
            job.cont.resume(returning: out)
        }
    }

    // MARK: - 本地语言检测

    private let recognizer = NLLanguageRecognizer()
    /// 用户选定的源语言 code（nil = 自动）：低置信度检测的回退目标，而非硬性限定。
    private var preferredCode: String?
    /// 目标语言 code。
    private var targetCode = "zh-Hans"
    /// 语言包预检结果缓存：key "源>目标"。成功长期有效；失败 60 秒内不重复查询。
    private var availabilityCache: [String: (ok: Bool, at: Date)] = [:]

    /// NLLanguage → 受支持的翻译 code。不在表内 = 离线引擎不支持，跳过（避免垃圾输出）。
    private static let supportedCode: [NLLanguage: String] = [
        .english: "en", .simplifiedChinese: "zh-Hans", .traditionalChinese: "zh-Hant",
        .japanese: "ja", .korean: "ko", .french: "fr", .german: "de", .italian: "it",
        .spanish: "es", .portuguese: "pt-BR", .russian: "ru", .arabic: "ar",
        .indonesian: "id", .dutch: "nl", .polish: "pl", .thai: "th", .turkish: "tr",
        .ukrainian: "uk", .vietnamese: "vi", .hindi: "hi",
    ]

    /// 检测一段文本的语言；返回 (code, 是否高置信)。
    private func detectCode(_ text: String) -> (code: String, confident: Bool)? {
        recognizer.reset()
        recognizer.processString(text)
        // languageHypotheses 返回字典（无序），必须取最高分
        guard let best = recognizer.languageHypotheses(withMaximum: 5).max(by: { $0.value < $1.value }),
              let code = Self.supportedCode[best.key] else { return nil }
        return (code, best.value >= 0.35)
    }

    /// 本批的主流语言（高置信检测中出现最多者），供低置信文本归组。
    private func dominantLanguage(of texts: [String]) -> String? {
        var counts: [String: Int] = [:]
        for t in texts {
            if let d = detectCode(t), d.confident { counts[d.code, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// 决定一段文本的源语言 code；返回 nil 表示放弃翻译（绝不弹系统选语言框）。
    /// 优先级：高置信检测结果 > 用户选定源语言 > 本批主流语言 > 低置信检测结果。
    private func sourceCode(for text: String, dominant: String?) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① 字符集判定（确定性、零误判）：假名 → 日文，谚文 → 韩文。
        //    这两类文字不会被认错，直接给确定答案。
        let s = t.unicodeScalars
        if s.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return "ja" }
        if s.contains(where: { (0xAC00...0xD7AF).contains($0.value) }) { return "ko" }

        // ② 其余（拉丁 / 西里尔 / 泰文…）：**短文本一律不采信语言检测**。
        //
        // 实测数据（NLLanguageRecognizer 跑 Xcode 真实菜单项）：
        //   Detach → 荷兰语 0.35      Unstage All Changes → 法语 0.59
        //   Add File Bookmark → 印尼语 0.54   Merge All Windows → 罗马尼亚语 0.68
        //   Fill → 加泰罗尼亚语 0.49   Test Plan → 法语 0.27
        // 短文本信息量太少，误判率极高，而且误判的后果很重：这组会去找一个
        // **根本没安装的语言包** → `prepare` 预检失败 → 整组回落原文 →
        // 用户看到的就是「经常有的不翻译」（之前实测那一屏 40 个菜单项里
        // 有 20 多条栽在这上面）。
        //
        // 策略：短项（菜单项 / 按钮 / 标签，≤4 词）用**用户选定的源语言**，
        // 没选就用英语兜底——软件界面文本绝大多数是英语。长句（≥5 词）检测可信，
        // 才采信检测结果（保留多语言界面的支持）。
        let words = t.split(whereSeparator: { $0.isWhitespace }).count
        if words <= 4 || t.count <= 28 { return preferredCode ?? "en" }

        guard let d = detectCode(t) else { return preferredCode ?? "en" }
        if d.confident { return d.code }
        return preferredCode ?? dominant ?? d.code
    }

    // MARK: - 菜单 / 系统术语表（用户 2026-10-11 拍板）

    /// 术语表存在的理由：离线引擎翻短菜单词时会出怪译（Find→「突破」、Xcode→「X代码」），
    /// 而 macOS 官方中文菜单有固定译法。命中即直出——既准确，又省一次引擎调用。
    private static let menuTerms: [String: String] = [
        // 菜单栏标准标题
        "file": "文件", "edit": "编辑", "view": "显示", "find": "查找",
        "navigate": "导航", "editor": "编辑器", "product": "产品", "debug": "调试",
        "integrate": "集成", "window": "窗口", "help": "帮助", "go": "前往",
        "tools": "工具", "format": "格式", "insert": "插入", "services": "服务",
        "text": "文本", "history": "历史记录", "bookmarks": "书签", "share": "共享",
        // 文件 / 编辑
        "new": "新建", "new window": "新建窗口", "new tab": "新建标签页",
        "new file": "新建文件", "new project": "新建项目", "new folder": "新建文件夹",
        "open": "打开", "open recent": "打开最近使用", "open file": "打开文件",
        "close": "关闭", "close window": "关闭窗口", "close all": "全部关闭",
        "close tab": "关闭标签页", "save": "存储", "save as": "存储为",
        "save all": "全部存储", "duplicate": "制作副本", "rename": "重新命名",
        "move": "移动", "move to trash": "移到废纸篓", "revert": "复原",
        "export": "导出", "import": "导入", "print": "打印", "page setup": "页面设置",
        "quit": "退出", "about": "关于", "preferences": "设置", "settings": "设置",
        // 编辑 / 查找
        "undo": "撤销", "redo": "重做", "cut": "剪切", "copy": "拷贝",
        "paste": "粘贴", "paste and match style": "粘贴并匹配样式",
        "delete": "删除", "select all": "全选", "deselect all": "全部取消选择",
        "find next": "查找下一个", "find previous": "查找上一个",
        "find and replace": "查找并替换", "replace": "替换", "replace all": "全部替换",
        "search": "搜索", "refresh": "刷新", "reload": "重新载入",
        // 窗口 / 视图
        "minimize": "最小化", "zoom": "缩放", "zoom in": "放大", "zoom out": "缩小",
        "actual size": "实际大小", "enter full screen": "进入全屏幕",
        "exit full screen": "退出全屏幕", "bring all to front": "全部前置",
        "hide": "隐藏", "hide others": "隐藏其他", "show all": "全部显示",
        "show": "显示", "sort": "排序", "filter": "过滤", "group": "分组",
        // 通用动作
        "cancel": "取消", "ok": "好", "done": "完成", "apply": "应用",
        "reset": "还原", "add": "添加", "remove": "移除", "build": "构建",
        "run": "运行", "stop": "停止", "test": "测试", "clean": "清理",
        "clean build folder": "清理构建文件夹", "archive": "归档",
        "analyze": "分析", "profile": "性能分析", "sign in": "登录",
        "sign out": "登出", "log in": "登录", "log out": "登出",
        "install": "安装", "update": "更新", "check for updates": "检查更新",
        "download": "下载", "upload": "上传", "submit": "提交",
        "report": "报告", "feedback": "反馈", "help center": "帮助中心",
        "documentation": "文档", "release notes": "发行说明", "version": "版本",
        "license": "许可协议", "general": "通用", "advanced": "高级",
        "security": "安全性", "privacy": "隐私", "network": "网络",
        "sound": "声音", "display": "显示器", "language": "语言",
        "account": "账户", "users": "用户", "system": "系统", "software": "软件",
        "support": "支持", "log": "日志", "clear": "清空", "back": "后退",
        "forward": "前进", "home": "主页", "previous": "上一个", "next": "下一个",
        "default": "默认", "custom": "自定", "customize": "自定",
        "enable": "启用", "disable": "停用", "start": "开始", "pause": "暂停",
        "continue": "继续", "finish": "完成", "info": "信息", "get info": "显示简介",
        "inspector": "检查器", "properties": "属性", "wrap": "自动换行",
        "spelling": "拼写", "grammar": "语法", "font": "字体", "bold": "粗体",
        "italic": "斜体", "underline": "下划线", "bigger": "更大",
        "smaller": "更小", "center": "居中", "justified": "两端对齐",
        "emoji & symbols": "表情与符号", "special characters": "特殊字符",
        "start dictation": "开始听写", "finder": "访达", "preview": "预览",
        "trash": "废纸篓", "desktop": "桌面", "documents": "文稿",
        "downloads": "下载", "applications": "应用程序", "library": "资源库",
    ]

    /// 规范化 key：只保留字母与数字、转小写。
    /// AX 给的菜单标题可能夹带隐形字符（零宽空格 U+200B 等）、多余空格、各种省略号，
    /// 精确匹配会漏掉（「只有文件/编辑翻了、View/Find 全没翻」的直接嫌疑）。
    /// 规范化后 "Save As…" / "Save  As" / "Save As" / "Save As\u{200B}" 一律等价。
    private static func normalizeKey(_ s: String) -> String {
        String(s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }

    /// 规范化后的术语查找表（启动时构建一次，避免每次查询做规范化）。
    private static let termTable: [String: String] = {
        var d: [String: String] = [:]
        for (k, v) in menuTerms { d[normalizeKey(k)] = v }
        return d
    }()

    /// 规范化后的产品名集合。
    private static let protectedKeys: Set<String> = Set(protectedTerms.map(normalizeKey))

    /// 专有名词 / 产品名：一律保留原文。**翻译它们必然出错**（Xcode→「X代码」就是典型），
    /// 返回原文后由渲染层「译文 == 原文则静默」规则自动不显示块。
    private static let protectedTerms: Set<String> = [
        "xcode", "macos", "ios", "ipados", "watchos", "tvos", "visionos",
        "iphone", "ipad", "imac", "macbook", "mac", "apple", "airpods",
        "icloud", "app store", "swift", "swiftui", "objective-c", "cocoa",
        "cocoapods", "terminal", "facetime", "itunes", "siri", "metal",
        "arkit", "testflight", "xcode cloud", "instruments", "simulator",
        "appkit", "uikit", "coreml", "homekit", "carplay", "airdrop",
        "airplay", "time machine", "spotlight", "keychain", "activity monitor",
    ]

    /// 术语表命中检查：仅在目标语言是中文时生效（别的语言方向交给引擎）。
    /// 返回 nil = 未命中，走正常翻译流程。
    private func terminologyOverride(_ text: String) -> String? {
        guard targetCode.hasPrefix("zh") else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalizeKey(t)
        guard !key.isEmpty else { return nil }
        // 产品名：原样返回 → 渲染层视为「无需翻译」而静默
        if Self.protectedKeys.contains(key) { return text }
        // 命中术语表：补回尾部省略号（菜单项常见 "Save As…"）
        guard let term = Self.termTable[key] else { return nil }
        let suffix = (t.hasSuffix("…") || t.hasSuffix("...")) ? "…" : ""
        return term + suffix
    }

    /// 真正调用会话：失败自动重试 1 次；失败**绝不写缓存**（避免把原文当译文永久钉死），
    /// 由上层按有限次数重试。
    private func performTranslate(_ text: String) async -> String {
        guard let session else { return text }
        for attempt in 0..<2 {
            do {
                let response = try await session.translate(text)
                let out = response.targetText.isEmpty ? text : response.targetText
                if out != text { store(cacheKey(text), out) }
                return out
            } catch {
                if attempt == 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
        }
        return text
    }

    /// 缓存 key 必须带上语言方向：否则切换源/目标语言后会命中另一种语言的旧译文。
    ///
    /// **隐私脱敏（2026-10-13）**：key 里**不再放原文明文**，改为放原文的 SHA-256。
    /// 旧实现把用户屏幕上的原文整段写进 `translationCache.json`（实测 1106 条 100% 明文，
    /// 最长 970 字符，混有 OCR 扫到的桌面私人文件名）。该文件随 Time Machine / 备份整份带走，
    /// 等于本机长期留存一份「屏幕内容语料」。改 hash 后：同文照样命中（命中率完全不变），
    /// 但**反查不出原文**，泄漏面降到零。译文（缓存值）仍需保留，那是缓存本身的意义所在。
    ///
    /// **2026-10-14**：前缀额外带上后端标识，避免不同引擎对同文给出不同译文时互相串缓存
    /// （例如 Apple 的「你好」与 DeepL 的「您好」不应共享一条缓存）。
    private func cacheKey(_ text: String) -> String {
        let src = preparedSource?.minimalIdentifier ?? "auto"
        let tgt = preparedTarget?.minimalIdentifier ?? "zh-Hans"
        let be = Preferences.shared.translationBackend.rawValue
        return Self.hashedKey(dirPrefix: "\(be)|\(src)>\(tgt)", text: text)
    }

    /// 语言方向前缀 + 原文 SHA-256。`h1:` 为新格式（哈希）标记，旧格式没有它。
    private static func hashedKey(dirPrefix: String, text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(dirPrefix)|h1:\(hex)"
    }

    private static func isHashedKey(_ key: String) -> Bool {
        guard let idx = key.firstIndex(of: "|") else { return false }
        return key[key.index(after: idx)...].hasPrefix("h1:")
    }

    /// 立即落盘（退出时调用）：常规写入有 2 秒去抖，退出瞬间不做这一步会丢掉最近一批译文。
    func flushCache() {
        saveTimer?.invalidate(); saveTimer = nil
        saveNow()
    }

    /// 清空翻译缓存（内存 + 磁盘）。
    func clearCache() {
        cache.removeAll()
        order.removeAll()
        saveTimer?.invalidate(); saveTimer = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// 写入缓存并维护 LRU 顺序；去抖落盘，避免高频翻译时频繁写文件。
    private func store(_ k: String, _ v: String) {
        if let idx = order.firstIndex(of: k) { order.remove(at: idx) }
        cache[k] = v
        order.append(k)
        while order.count > cacheLimit {
            let old = order.removeFirst()
            cache.removeValue(forKey: old)
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    private func saveNow() {
        let arr = order.compactMap { k -> [String]? in
            guard let v = cache[k] else { return nil }
            return [k, v]
        }
        if let data = try? JSONEncoder().encode(arr) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
