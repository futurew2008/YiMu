import ScreenCaptureKit
import Vision
import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import AppKit
import CoreGraphics

/// 通过 ScreenCaptureKit 抓屏 + Vision 识别文字，作为 AX 读不到时的兜底
/// （游戏、自绘 UI、桌面、无前台 AX app）。支持多显示器：每块显示各起一路流，
/// 结果聚合后整体回传（全局 AppKit 坐标），供多屏融合态使用。
///
/// 线程模型（修复真机闪退的关键）：
/// 旧版把 `streams` / `displayInfo` / `resultsByDisplay` 三个字典在「采集回调队列」上读、
/// 在「begin/stop 的 Task」上写，无锁跨线程访问在融合→设置切换（stop 与在途帧并发）时
/// 撕裂内存，表现为主线程 autorelease pool 清理时 over-release 崩溃（6 份崩溃日志均如此）。
/// 现在：每块显示一个独立的 `DisplayStream` 输出对象（状态创建后不可变），
/// 全部可变状态只在一个串行 stateQueue 上读写，从机制上消灭数据竞争。
final class OCRTextExtractor: NSObject {
    static let shared = OCRTextExtractor()

    /// 每块显示一个流封装：自身就是 SCStreamOutput，持有该路全部不可变上下文，
    /// 回调里不再触碰任何共享字典。
    private final class DisplayStream: NSObject, SCStreamOutput {
        let displayID: CGDirectDisplayID
        let frame: NSRect          // 全局 AppKit 矩形
        let cfgW: CGFloat          // 抓屏像素宽
        let cfgH: CGFloat          // 抓屏像素高
        weak var owner: OCRTextExtractor?

        init(displayID: CGDirectDisplayID, frame: NSRect, cfgW: CGFloat, cfgH: CGFloat, owner: OCRTextExtractor?) {
            self.displayID = displayID
            self.frame = frame
            self.cfgW = cfgW
            self.cfgH = cfgH
            self.owner = owner
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen,
                  let owner = owner, !owner.isStopped,
                  let ib = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ci = CIImage(cvImageBuffer: ib)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // UI 文本不做语言校正：校正会改动专有名词（PID→Pid）且逐帧结果不稳定，
            // 造成同处文字反复微变、译文块抖动堆积。
            request.usesLanguageCorrection = false
            // 识别语言：跟随设置里的源语言（2026-10-12 加强镜头翻译）。
            // 旧版写死 ["zh-Hans","en-US"]：源语言是日/韩/俄等时，Vision 只用中/英模型
            // 去"猜"，把汉字/假名认成一串拉丁乱码（日志里的 `tIEX.` / `RB1₺extapp` /
            // `] (Z Z*) . Xcoe`），翻出来就是「不是翻译的内容」的怪块。
            // 现在：指定源语言 → 该语言+中英兜底；自动 → 一组常用语言，配合自动判别。
            // 正确识别成源语言后，源文本会被上层「已是中文则跳过」/ 翻译引擎正常处理。
            request.recognitionLanguages = owner.recognitionLanguages
            request.automaticallyDetectsLanguage = true
            // 最小可识别高度 0.8%（2x 屏约 8pt）：原 2% 阈值（约 21pt）把桌面图标标签、
            // 菜单文字这类小字全部拒识——这是"很多单词不翻译"的直接原因之一。
            request.minimumTextHeight = 0.008

            let handler = VNImageRequestHandler(ciImage: ci, orientation: .up, options: [:])
            do { try handler.perform([request]) } catch { return }
            guard let observations = request.results else { return }

            var items: [CapturedText] = []
            for o in observations {
                guard let top = o.topCandidates(1).first else { continue }
                // 置信度门槛：Vision 对噪点、图标、背景纹理也会给出候选框，
                // 低置信度的基本都是乱码或碎片——翻出来只是噪声。
                // 2026-10-12 19:35 修正：门槛 0.4 把「Open」这类短孤立 UI 词（Vision 给的
                // 置信度常 <0.4）整类丢在取字最上游，导致按钮文字不翻译（isTranslatable 改了也没用
                // —— 它在置信度下游）。降到 0.3：短词能进来，垃圾由 isTranslatable/isCleanWord
                // 在下游兜底（识别语言已跟随源语言，乱码源已堵）。
                guard top.confidence >= 0.3 else { continue }
                let rect = Self.map(bbox: o.boundingBox, frame: frame, cfgW: cfgW, cfgH: cfgH)
                items.append(CapturedText(id: UUID(), text: top.string, rect: rect, source: .ocr))
            }
            owner.publish(items: items, from: displayID)
        }

        /// Vision 归一化包围盒（原点左下、Y 上）→ AppKit 全局矩形（原点左下、Y 上）。
        private static func map(bbox: CGRect, frame: NSRect, cfgW: CGFloat, cfgH: CGFloat) -> NSRect {
            let px = bbox.origin.x * cfgW
            let pyTop = (1 - bbox.origin.y - bbox.height) * cfgH   // 距图像顶部的像素
            let scale = cfgW / max(frame.width, 1)
            let gx = frame.minX + px / scale
            let gTop = pyTop / scale                               // 距显示顶部的点距
            let gh = (bbox.height * cfgH) / scale
            let gy = frame.maxY - gTop - gh                        // AppKit 左下原点
            return NSRect(x: gx, y: gy, width: (bbox.width * cfgW) / scale, height: gh)
        }
    }

    private var streams: [CGDirectDisplayID: (stream: SCStream, wrapper: DisplayStream)] = [:]
    private var resultsByDisplay: [CGDirectDisplayID: [CapturedText]] = [:]
    private var stopped = true

    /// 源语言 code（来自设置；nil = 自动识别）。用于决定 Vision 识别语言集合，
    /// 使日语 / 韩语 / 俄语等非中英文源文本不再被英文模型乱码识别（直接修掉大量"怪块"）。
    /// 由 AppDelegate 在语言方向变化时写入；每帧回调实时读取，无需重启流即生效。
    var sourceLanguageCode: String?

    /// 当前应下发给 Vision 的识别语言集合（internal：AppDelegate 的指译 OCR 兜底也复用，
    /// 保证指译与镜头用同一套识别语言）。
    /// - 指定源语言 → 该语言 + 中 / 英兜底（翻译该语言时模型最准）；
    /// - 自动识别 → 一组常用语言（中日韩俄法德西葡意泰越阿印尼荷波土乌等），
    ///   配合 `automaticallyDetectsLanguage` 自动判定，避免限定中/英时把其它文字认成乱码。
    /// 直接用 LanguageOption.id 作 BCP-47 码（"ja" / "zh-Hans" / "ru" 等），避免 Locale.Language 无 identifier 的坑。
    var recognitionLanguages: [String] {
        if let code = sourceLanguageCode, code != "auto" {
            let opt = LanguageOption.sourceOption(forCode: code)
            if opt.locale != nil {
                return [opt.id, "en-US", "zh-Hans"]
            }
        }
        return ["en-US","zh-Hans","ja-JP","ko-KR","ru-RU","fr-FR","de-DE","es-ES",
                "pt-BR","it-IT","th-TH","vi-VN","ar","id","ms","nl-NL","pl-PL","tr-TR","uk-UA"]
    }
    /// 全部可变状态的唯一守护队列。
    private let stateQueue = DispatchQueue(label: "com.weilai.transcreen.ocr.state")

    var onResult: (([CapturedText]) -> Void)?

    /// 是否需要「屏幕录制」授权（TCC）。
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 请求屏幕录制授权（会弹出系统授权框）。
    func requestPermission() { CGRequestScreenCaptureAccess() }

    var isStopped: Bool { stateQueue.sync { stopped } }

    /// 在指定的一组显示上开始流式 OCR。
    /// - Parameters:
    ///   - displays: 形如 (frame 全局矩形, id, scale)。融合/镜头态传全部屏幕；区域态传单屏。
    ///   - cropRect: 兼容旧接口（现由 CaptureEngine 统一裁剪，不再在抽取器内裁）。
    ///   - frameRate: 抓屏帧率（帧/秒）。镜头/区域态用更高帧率让译文更快跟上拖动；
    ///     融合态只需整屏兜底，保持低帧率省 CPU。
    ///   - excludeWindowIDs: 从抓屏中排除的本 app 窗口，避免译文块被二次识别造成反馈堆积。
    func start(displays: [(frame: NSRect, id: CGDirectDisplayID, scale: CGFloat)],
              cropRect: NSRect?,
              frameRate: Int = 3,
              excludeWindowIDs: [CGWindowID] = []) {
        guard hasPermission else { return }
        stateQueue.sync {
            stopped = false
            resultsByDisplay.removeAll()
        }
        for d in displays {
            Task { await begin(display: d, frameRate: frameRate, excludeWindowIDs: excludeWindowIDs) }
        }
    }

    func stop() {
        let snapshot: [(SCStream, DisplayStream)] = stateQueue.sync {
            stopped = true
            resultsByDisplay.removeAll()
            let s = Array(streams.values).map { ($0.stream, $0.wrapper) }
            streams.removeAll()
            return s
        }
        // 在后台把流优雅停掉；回调里 isStopped 已为 true，在途帧会被直接丢弃。
        Task { [snapshot] in
            for (s, w) in snapshot {
                w.owner = nil
                try? await s.stopCapture()
            }
        }
    }

    // MARK: - 启动流（每块显示一路）

    private func begin(display: (frame: NSRect, id: CGDirectDisplayID, scale: CGFloat),
                       frameRate: Int = 3,
                       excludeWindowIDs: [CGWindowID]) async {
        guard let content = try? await SCShareableContent.current,
              let disp = content.displays.first(where: { $0.displayID == display.id }) else { return }

        // 排除本 app 自身的覆盖窗口（主窗口 + 融合态所有分屏窗口），
        // 避免译文块被 OCR 二次识别造成反馈堆积。
        let excludeWin = content.windows.filter { excludeWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: disp, excludingWindows: excludeWin)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(disp.width) * display.scale)
        cfg.height = Int(CGFloat(disp.height) * display.scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate))) // 镜头/区域态用更高帧率（默认 6），新文字更快被认出，拖动后译文跟手；融合态用 3 省 CPU
        cfg.showsCursor = false
        cfg.captureResolution = .best

        let wrapper = DisplayStream(displayID: display.id,
                                    frame: display.frame,
                                    cfgW: CGFloat(cfg.width),
                                    cfgH: CGFloat(cfg.height),
                                    owner: self)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try? stream.addStreamOutput(wrapper, type: .screen,
                                    sampleHandlerQueue: DispatchQueue(label: "com.weilai.transcreen.ocr.\(display.id)"))

        // 注册前再校验一次：若期间已被 stop，直接把流停掉，绝不留下"僵尸流"。
        let shouldStart: Bool = stateQueue.sync {
            guard !stopped else { return false }
            streams[display.id] = (stream, wrapper)
            return true
        }
        guard shouldStart else {
            try? await stream.stopCapture()
            return
        }
        do {
            try await stream.startCapture()
        } catch {
            print("[OCR] startCapture failed: \(error)")
        }
    }

    /// DisplayStream 回调入口：把本帧结果并入聚合表，整体回传（全局坐标）。
    /// 只在 stateQueue 上读写 resultsByDisplay——这是无竞争的关键。
    fileprivate func publish(items: [CapturedText], from displayID: CGDirectDisplayID) {
        var all: [CapturedText] = []
        let ok: Bool = stateQueue.sync {
            guard !stopped else { return false }
            resultsByDisplay[displayID] = items
            for v in resultsByDisplay.values { all.append(contentsOf: v) }
            return true
        }
        guard ok else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.onResult?(all)
        }
    }
}
