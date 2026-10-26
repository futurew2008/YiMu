import AppKit
import SwiftUI

/// 遮挡块背景：系统毛玻璃（NSVisualEffectView，behindWindow 模糊）。
/// 真实系统菜单、弹出框用的就是这套材质——不自带折射描边，
/// 透出背后原底色、把原文字糊成读不出的雾。≥26 与 <26 统一走这条路径。
/// （液态玻璃 GlassButtonStyle 的自带折射亮边无法用公开 API 去掉，故不采用。）

/// 单个译文块：毛玻璃底 + 不透明底衬（原文不再透出）+ 左对齐深色文字。
/// 尺寸紧贴译文文字，左上角对齐到原词在屏幕上的位置——不居中、不大块。
final class TranslationBlock: NSView {
    let label: NSTextField
    /// 文字左侧约束（普通块 3pt；菜单项要内缩到与系统菜单标题同一缩进，见 menuTextInset）。
    private var leadingConstraint: NSLayoutConstraint!
    /// 底衬：把毛玻璃的模糊"托"成一片有色的玻璃面。太厚就成死白纸片（用户嫌弃的"灰块/白贴纸"），
    /// 太薄原文会半透出来。当前取值 + 玻璃自身的强模糊，是"像菜单"与"遮得住"的平衡点。
    private let tint = NSView()
    /// 顶边 1pt 内高光：系统毛玻璃面板的标志性细节（受光边缘）。
    /// 有了它，块才像"一片玻璃"而不是"一块涂料"。
    private let highlight = NSView()
    /// 系统毛玻璃底（NSVisualEffectView）；全版本统一使用。
    private var vibrancy: NSVisualEffectView?
    /// 玻璃层的整体不透明度（alphaValue）。注意：NSVisualEffectView 的「磨砂模糊」与
    /// 图层不透明度是绑定的，没有独立的模糊强度旋钮——alphaValue 越高磨砂越强、原字
    /// 糊得越干净但越「实」；越低越透、但原字会透出来、磨砂感弱。
    /// 1.0 = 标准毛玻璃（16:22 实测太实、无透明感）；0.6 = 用户认可「找对透明度」但磨砂偏弱；
    /// 0.8 = 折中：磨砂回来糊住原字、面板读作一片玻璃，又比 1.0 略透。单常量微调。
    static let glassAlpha: CGFloat = 0.8
    /// 下拉菜单条目遮挡块相对面板左缘的额外右移量（pt）。
    /// 2026-10-12 用户：块左缘紧贴面板左缘、右侧字母盖不住 → 先右移 2pt，
    /// 17:47 再 +6pt（合计 8pt），17:50 再 +2pt（合计 10pt）；文字 leading 同步减同一值，
    /// 译文视觉位置不动（只挪遮挡块，不动文字）。
    static let menuRightShift: CGFloat = 10
    /// 下拉菜单条目遮挡块**仅右侧额外加宽**（pt）。
    /// 2026-10-12 18:06 用户：左侧保持已右移 10pt 不动、只把右缘再延伸加宽 2pt
    /// （即块宽 +2、左缘与文字位置均不变），多盖住右侧 2pt。仅作用于下拉条目分支。
    static let menuExtraWidth: CGFloat = 2
    /// 下拉菜单条目遮挡块**仅左侧额外加宽**（pt，向左延伸；负值则收右）。
    /// 2026-10-12 18:11 用户：右/文字不动、左缘向左延伸加宽 4pt；
    /// 18:13 再 +1（共 5pt）；18:21 反向收 1pt（共 4pt）。
    /// 实现：左缘 x − menuLeftExtend、块宽 + menuLeftExtend、文字 leading + menuLeftExtend
    /// （三项联立 ⇒ 右缘与文字屏幕位置均不变，只把左侧遮挡矩形左右探出/收回）。仅作用于下拉条目分支。
    static let menuLeftExtend: CGFloat = 4
    /// 当前圆角（layout 里给高光内缩用）。
    private var currentRadius: CGFloat = 6
    /// macOS 菜单项标题距**菜单面板左缘**的标准缩进。
    /// 真机截图实测：面板左缘 x=145，英文 "Show Quick Actions…" / "Navigators" 等首笔在 x=160，
    /// 即 15px ≈ 14.6pt（减去字形左侧边距后布局原点约 14pt）。
    /// 为什么必须知道它：AX 给的下拉项矩形 x 就是**面板左缘**（实测块左缘与面板左缘重合），
    /// 而英文是从 +14pt 处开始画的——所以
    ///   ① 块宽必须把这段缩进算进去，否则右端会差 14pt、盖不住英文尾巴（残影）；
    ///   ② 译文文字也要按同样缩进排，才会落在原英文的位置上（否则整体左移 14pt）。
    static let menuTextInset: CGFloat = 14
    /// configure 算出的**基准 frame**（尚未被重叠消解修改）。
    /// resolveOverlaps 必须每帧从基准重算——否则会在上一帧已被压缩的结果上反复压缩，
    /// 表现为「译文块越来越小，直到消失」。
    var baseFrame: NSRect = .zero

    /// 多行块几何探针节流（每 0.5s 窗口内最多 6 条，够记录同一帧的多个多行块）。临时诊断，验收后删除。
    private static var fitProbeAt: CFTimeInterval = 0
    private static var fitProbeCount = 0
    static func fitProbeGate() -> Bool {
        let now = CACurrentMediaTime()
        if now - fitProbeAt > 0.5 { fitProbeAt = now; fitProbeCount = 0 }
        fitProbeCount += 1
        return fitProbeCount <= 24
    }

    override init(frame frameRect: NSRect) {
        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.cell?.truncatesLastVisibleLine = false

        super.init(frame: frameRect)

        // 背景层：系统毛玻璃（NSVisualEffectView）。
        // behindWindow 模糊 → 原文字糊成雾、读不出；材质透出背后原底色。
        // .popover 材质比 .menu 更透更中性，且无自带描边。
        let ve = NSVisualEffectView()
        ve.material = .popover
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.appearance = nil
        // 压低玻璃层不透明度 = 提高透明度（见 glassAlpha 注释）。
        ve.alphaValue = Self.glassAlpha
        ve.frame = bounds
        ve.autoresizingMask = [.width, .height]
        addSubview(ve)
        vibrancy = ve
        // 显式让块跟随窗口外观，避免材质把外观锁成 aqua（浅色）。
        self.appearance = nil

        // 底衬：普通 NSView，负责白度(alpha 可调) + 圆角 + 描边 + 落影。
        tint.wantsLayer = true
        tint.layer?.cornerRadius = 7
        tint.layer?.borderWidth = 0.5
        tint.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        let sh = NSShadow()
        sh.shadowBlurRadius = 5
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.22)
        tint.shadow = sh
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        // 玻璃顶边内高光：叠在底衬之上、文字之下
        highlight.wantsLayer = true
        addSubview(highlight)
        updateTintColor()
        updateHighlightColor()

        label.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(label)

        leadingConstraint = label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 3)
        NSLayoutConstraint.activate([
            leadingConstraint,
            label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -3),
            // 垂直居中：块高可能远大于文字（大字标题），居中比贴顶自然
            label.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tint.frame = bounds
        vibrancy?.frame = bounds
        // 顶边 1pt 高光：两端各内缩一个圆角半径，避免溢出圆角外。
        let inset = currentRadius
        highlight.frame = NSRect(x: inset,
                                 y: bounds.height - 1,
                                 width: max(0, bounds.width - inset * 2),
                                 height: 1)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTintColor()
        updateHighlightColor()
    }

    /// 底衬颜色 —— 统一「白色半透明毛玻璃」（2026-10-12 用户定方向）。
    /// alpha 0.55 → 0.35（12:53）→ 0.22（12:56）→ 0.16（12:58）→ 0.08（13:03 仍嫌白）
    /// → 0.04（13:11 用户"降低一半"：白膜更薄更透）
    /// 用户 13:49 指定：tint 设 0 → 不留任何白/蓝，纯 .menu 玻璃裸奔。
    private func updateTintColor() {
        self.tint.layer?.backgroundColor =
            NSColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 1)
                .withAlphaComponent(0).cgColor
    }

    /// 菜单类块的悬停高亮（2026-10-12 用户）：模仿系统菜单悬停反蓝。
    /// 悬停时底衬 tint 叠系统强调色（菜单高亮蓝），移出恢复透明；文字仍在玻璃上清晰可读。
    private var hovered = false
    func setHovered(_ on: Bool) {
        guard hovered != on else { return }
        hovered = on
        if on {
            tint.layer?.backgroundColor =
                NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        } else {
            updateTintColor()
        }
    }

    /// 顶边内高光：浅色玻璃上的一丝受光白线，让块像「一片玻璃」而非「一块涂料」。
    private func updateHighlightColor() {
        highlight.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
    }

    /// 所有块统一为系统毛玻璃：behindWindow 模糊把原文字糊成雾、读不出，
    /// 材质透出背后原底色；译文用系统 labelColor 直接画在玻璃上，清晰可读。
    /// 不做取色、不跟随背景变色；全屏统一毛玻璃。任何版本都不画描边/阴影/顶高光，
    /// 以彻底去掉用户反馈的「描边」观感（液态玻璃折射边 / AppKit 边框 / 顶边白线）。
    private func applyChrome(isMenu: Bool, menuBarTitle: Bool = false) {
        label.textColor = .labelColor
        let radius: CGFloat = isMenu ? 6 : 7
        currentRadius = radius
        // 圆角裁剪放在最外层容器 self：连带玻璃层 vibrancy 一起裁成圆角矩形。
        // 之前圆角只设在透明底衬 tint 上、玻璃层 vibrancy 是直角矩形 → 视觉上是长方形。
        // 仅给父容器裁圆角、不给 NSVisualEffectView 自身 wantsLayer，避免触发 vibrancy 失效。
        self.wantsLayer = true
        self.layer?.cornerRadius = radius
        self.layer?.masksToBounds = true
        // 底衬 tint 已无白叠（updateTintColor 中 alpha=0），这里仅负责圆角，
        // 边框/阴影一律为 0；顶边高光线隐藏——三处都是可能的「描边」来源。
        tint.layer?.cornerRadius = radius
        tint.layer?.borderWidth = 0
        tint.layer?.borderColor = nil
        tint.shadow = nil
        highlight.isHidden = true
    }

    /// 根据捕捉项定位与绘制：块大小 = 译文文字大小；水平左对齐到原词起点，垂直居中原词。
    /// - rowHeight：下拉菜单的**真实行高**（同组相邻条目间距），nil = 无法推断。
    /// 所有块统一白色半透明毛玻璃（见 applyChrome）。
    func configure(item: CapturedText, originScreen: NSPoint, rowHeight: CGFloat?,
                   debug: Bool, overrideText: String? = nil) {
        let local = NSRect(
            x: item.rect.origin.x - originScreen.x,
            y: item.rect.origin.y - originScreen.y,
            width: item.rect.width,
            height: item.rect.height
        )
        // overrideText：渲染层「译文保持」场景下，用已确认的译文覆盖 configure 默认取到的原文，
        // 使块在「上游该帧未翻、退回原文」时仍显示已画过的译文，不闪。
        let text = overrideText ?? displayText(for: item)
        applyChrome(isMenu: item.isMenu, menuBarTitle: item.menuBarTitle)
        // 默认左右各 3pt；菜单项在下面会改成与系统菜单标题一致的缩进。
        leadingConstraint.constant = 3

        // —— 菜单栏带（仅菜单栏标题）——
        // 字号与块高都以它为准，所以要在算字号**之前**先取到。
        var bandBottom: CGFloat?
        var bandHeight: CGFloat?
        if item.isMenu, item.menuBarTitle,
           let band = Self.menuBarBand(containing: NSPoint(x: item.rect.midX, y: item.rect.midY)) {
            bandBottom = band.bottom - originScreen.y
            bandHeight = band.height
        }

        // 字号：**全自动**，由原文的行高推导（2026-10-12 用户决定取消手动字号设置）。
        // 为什么必须自动——手动字号会直接破坏遮挡：块宽 = max(译文宽, 原文估宽)，
        // 字号一调大，译文变宽，块面就跟着撑到原文以外（「盖住的长度过长」的根因之一）。
        // 自动后译文与原文视觉同尺寸，块面自然贴合原文，不再人为外扩。
        let pt = Self.autoPointSize(lineHeight: bandHeight ?? local.height,
                                    rectWidth: local.width,
                                    sourceText: item.text,
                                    isMenu: item.isMenu,
                                    isMenuBarTitle: item.menuBarTitle)
        // 原生替换模式用 regular 字重：系统菜单文字本就是 regular，
        // medium 是此前「死色贴纸」时代为了可读性做的补偿性加粗。
        let font = NSFont.systemFont(ofSize: pt, weight: .medium)
        label.font = font
        label.stringValue = text

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)
        // 原文宽度估算：菜单类用**系统自己渲染菜单文字所用的字体**（NSFont.menuFont / menuBarFont）
        // 来量英文，而不是拿译文的中等字重字体去量——后者会系统性偏宽 30–50pt，
        // 块面因此盖到原文之外（用户反复提的「盖住的长度过长了」）。
        // 菜单字体与系统实际渲染同源，量出来的宽度与屏幕上英文的占宽基本重合。
        // 非菜单项的 AX 矩形本就紧贴文字，仍用与译文同字号估宽做交叉校验。
        let origFont: NSFont = item.isMenu
            ? (item.menuBarTitle ? NSFont.menuBarFont(ofSize: 0) : NSFont.menuFont(ofSize: 0))
            : NSFont.systemFont(ofSize: font.pointSize)
        let origSize = (item.text as NSString)
            .size(withAttributes: [.font: origFont])
        let padX: CGFloat = item.isMenu ? 4 : 4
        // 窗口 / 正文内容「严格贴合原文矩形」用的内边距（用户 2026-10-12 拍板：由 4pt 收到 2pt）
        // 与上面菜单用的 padX 分开，互不干扰——菜单分支完全不读这两个值。
        let fitPadX: CGFloat = 2
        let fitPadY: CGFloat = 2

        // 宽度铁律：块只遮「原词/原句本身」，绝不按"整段串成单行"的估宽撑大块面。
        // 块宽口径按分支走（见下）：菜单标题 = AX 矩形宽；下拉条目 = 原文估宽 + 缩进；
        // 窗口/正文 = 原文矩形宽（窄元素才有限扩张）。

        let blockW: CGFloat
        let textH: CGFloat
        // 窗口内容：译文按原文矩形「拟合」后的实际尺寸（供下面 blockH 分支取用，
        // 保证宽高用同一套拟合结果，不会一个按原文、一个按译文）。
        var fittedTextSize: NSSize = .zero
        if item.isMenu, item.menuBarTitle {
            // 菜单栏标题块宽度（用户定的双原则）：以盖住**原文**为准 = AX 标题矩形宽
            // （菜单栏标题矩形本就紧贴文字，不向两侧扩张——扩张就会压到相邻标题）；
            // 译文比原文宽时缩字号适配（最低 8pt），绝不撑大块面。
            blockW = local.width
            var fitAttrs = attrs
            if textSize.width > local.width - 3 {
                let shrunkPt = max(8, floor(font.pointSize * (local.width - 3) / max(textSize.width, 1)))
                let fitFont = NSFont.systemFont(ofSize: shrunkPt, weight: .medium)
                fitAttrs = [.font: fitFont]
                label.font = fitFont
            }
            label.alignment = .center
            label.preferredMaxLayoutWidth = 100000
            textH = (text as NSString).boundingRect(
                with: NSSize(width: 100000, height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: fitAttrs).height
        } else if item.isMenu {
            // 下拉菜单条目——遮挡宽度双原则（用户 2026-10-11 拍板）：
            // ① 首要原则：盖住**英文原文的实际宽度**。AX 给的条目矩形是整行宽（含左侧图标槽
            //    与右侧快捷键区），照抄就会盖出一大条灰块（黄线对比的根因）——所以按原文
            //    文本估宽，而不是抄矩形宽。但英文是从面板左缘 + menuTextInset 处起画的，
            //    这段缩进必须计入块宽，否则块右端比英文尾部短 14pt、尾巴会露出来。
            // ② 译文比原文长时：以**译文的宽度**为准（不缩字号、不硬塞）。
            let origW = origSize.width + 2
            blockW = max(textSize.width, origW) + padX * 2 + Self.menuTextInset + Self.menuExtraWidth + Self.menuLeftExtend
            // 译文按与系统菜单标题**相同的缩进**排（块左缘 = 面板左缘），
            // 这样译文正好落在原来英文的位置上，而不是整体左移 14pt。
            // 减去 menuRightShift：块整体右移后，用 leading 补偿使译文视觉位置不变。
            leadingConstraint.constant = Self.menuTextInset + 3 - Self.menuRightShift + Self.menuLeftExtend
            label.alignment = .left
            label.preferredMaxLayoutWidth = 100000
            textH = (text as NSString).boundingRect(
                with: NSSize(width: 100000, height: 10000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs).height
        } else {
            // —— 窗口 / 正文内容：块面严格贴合原文矩形，文字去适配（2026-10-12 用户拍板三项）——
            // 旧规则是「块跟着译文走」：blockW = min(max(译文宽, 原文估宽), 520) + 10、
            // blockH = max(译文折行高 + 6, 原文高)。后果：译文一宽就盖到原文之外，
            // 译文一换行块就上下外扩——正是用户看到的「遮挡尺寸与原文对不上」。
            // 新规则：
            // ① 块宽 / 块高 = 原文矩形宽 / 高（内边距 fitPad 收窄）；
            // ② 译文先按原文行高定字号，塞不进原文矩形就逐级缩字号（下限 9pt）——文字去适配；
            // ③ 缩到下限仍塞不进，才允许块按译文尺寸扩张，**文字绝不截断**。
            // —— 窄块横向扩张（2026-10-13 修 IMDb 工具栏「译文太紧凑、聚在一起」）——
            // AX 给的盒子常常只有 24–60pt 宽（汉堡按钮 / 提交按钮 / 分享按钮 / 复选框标签），
            // 中文在这个宽度里每行只能排 1–2 个字 → 折成 2–3 行、极端时 13 行
            // （实测 rectW=24 时译文被挤成 24×158 的竖条），块与块紧贴。
            //
            // **2026-10-13 二改（用户截图：「这部分遮挡为什么宽了好多」）**：
            // 扩张只对**真正的窄元素**生效（盒宽 < 120pt）。段落那类正常宽度的盒子
            // 一旦也按"译文自然宽"扩张，块就往右鼓出一大条，盖到原文之外。
            // 段落的目标不是"更宽"，而是"字号小一点 + 自动换行"，把译文排进原区域里。
            let narrow = local.width < 120
            let naturalW = (text as NSString)
                .size(withAttributes: [.font: font]).width
            let wantW = narrow
                ? max(local.width, min(naturalW + 6 + fitPadX * 2, local.width + 100))
                : local.width
            let availW = max(8, wantW - fitPadX * 2 - 6)   // 再让出 label 自身 3pt 左右内缩
            let availH = max(10, local.height - fitPadY * 2)
            let measure = { (p: CGFloat) -> NSSize in
                (text as NSString).boundingRect(
                    with: NSSize(width: availW, height: 10000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: NSFont.systemFont(ofSize: p, weight: .medium)]).size
            }
            // 下限 9 → 8pt（2026-10-13 用户：「字体小一点点，自动换行，以保证覆盖原区域」）：
            // 宁可字号小一档换取"译文排得进原文矩形"，也不要为了字号把块撑出原区域。
            let minPt: CGFloat = 8
            var ptF = font.pointSize
            var fitted = measure(ptF)
            // 按比例跳档（宽度/高度都近似线性于字号），再少量迭代收敛；
            // 单纯每次 -0.5pt 在最坏情况下要循环 20+ 次，逐帧跑会拖慢刷新。
            var iter = 0
            while (fitted.height > availH || fitted.width > availW) && ptF > minPt && iter < 10 {
                iter += 1
                let wScale = fitted.width > 0 ? availW / fitted.width : 1
                let hScale = fitted.height > 0 ? availH / fitted.height : 1
                let scale = min(wScale, hScale)
                ptF = max(minPt, ptF * min(0.95, scale))   // 留 5% 余量，避免刚好卡边界来回抖
                fitted = measure(ptF)
                if scale >= 0.95 { break }
            }
            label.font = NSFont.systemFont(ofSize: ptF, weight: .medium)
            label.preferredMaxLayoutWidth = availW
            textH = fitted.height
            fittedTextSize = fitted
            // 宽度取「扩张后的目标宽」与「译文实际需要宽」的较大者（wantW 已含窄块扩张）。
            blockW = max(wantW, fitted.width + 6 + fitPadX * 2)
        }

        // 高度：菜单块 = **整行矩形高**，正文块至少盖住译文行高 + 呼吸空间。
        var blockH: CGFloat
        if item.isMenu, !item.menuBarTitle {
            // 下拉菜单项：AX 给的矩形是**整行矩形**——真机实测每条都是 364×24
            // （x 从菜单内容左缘起、宽含右侧快捷键区、高 = 整行高），相邻行 y 步长恰好 24、
            // 跨分隔线 35，也就是说**行与行本来就是严格相接的**。
            // 上一版误把它当成「文字紧致框」而 +8pt 外扩 → 块高 32pt 而行距只有 24pt，
            // 每行都盖住下一行 8pt，这就是用户截图里「遮挡底色重叠」的根因。
            // 现在直接取整行高，再各内缩 0.5pt（块高 = 行高 − 1）：行与行之间留一条发丝缝，
            // 既不相交，也不会糊成一整条灰带，视觉上是一排整齐的胶囊。
            let rowH = local.height >= 16 ? local.height : (rowHeight ?? local.height)
            // 相邻菜单行各内缩 0.5pt（块高 = 行高 − 1），留一条发丝缝避免相交糊成一条灰带。
            blockH = max(rowH - 1, textH)
        } else if item.menuBarTitle {
            blockH = max(local.height, textH)           // 随后被菜单栏带覆盖
        } else {
            // 窗口内容：块高必须同时满足两件事（2026-10-13 用户：「保证覆盖原区域，
            // 并且翻译后的文字完全显示」）：
            // ① **盖住整段原文**：AX 给的矩形经常只覆盖首行（实测网页多行段落 rectH 35~85
            //    而原文实占更高），用「原文估算渲染高 srcH」兜底，否则最后一行英文露在块外
            //    （用户截图底部露出的 `who to do is kill. — Adrienne`）。
            // ② **装下完整译文**：fittedTextSize.height 是已缩字号后的实测排版高。
            // srcH 上限锁 local.height × 1.6：估算失真时不至于把块撑成巨块。
            let srcW0 = (item.text as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: pt)]).width
            let est0 = max(1, Int((srcW0 / max(local.width, 1)).rounded(.up)))
            let srcH = min(CGFloat(est0) * pt * 1.25, local.height * 1.6)
            blockH = max(local.height, max(srcH, fittedTextSize.height + fitPadY * 2))
        }

        // 水平：左对齐到原词起点。
        // 垂直：**以原词矩形为基准垂直居中**（用户 2026-10-11 定原则）。
        // 旧版是「块顶 = 原词顶边、向下生长」——块高恒 ≥ 原词矩形高，所以译文块只要比原词高
        // （译文更长 / 原词矩形偏矮），整块就往下坠，视觉上就是「上对齐」。居中后上下对称：
        // 块高 ≥ 原词矩形高 ⇒ 原词仍被完整盖住，且块与原文垂直对齐。
        // 下拉菜单条目：整体右移 menuRightShift，使块左缘不再紧贴面板左缘、右侧字母被盖住
        // （译文 leading 已同步减同一值，视觉位置不变——只挪遮挡块）。
        let x = local.origin.x + ((item.isMenu && !item.menuBarTitle) ? (Self.menuRightShift - Self.menuLeftExtend) : 0)
        var y = local.midY - blockH / 2

        // —— 菜单栏标题：强制锚定到真实菜单栏带 ——
        // AX 给的标题矩形在 Tahoe 下系统性上偏约 6pt、且高度偏矮，照它画只盖住英文
        // 上半截（字母底部露在外面），极端时被顶出屏幕只剩一条细边（看着像"没翻译"）。
        // 这里彻底不信任 AX 的 y/height：块 = 整条菜单栏带本身，文字在带内垂直居中。
        if let bb = bandBottom, let bh = bandHeight {
            blockH = bh
            y = bb
        }
        // —— 横向发丝缝（2026-10-13）——
        // 相邻文字块的 AX 盒子常常横向紧贴（间距 0–1pt），块挨着块画出来就是
        // 「糊成一片、没分开」（用户 IMDb 工具栏截图：「翻译得太紧凑，没分开」）。
        // 右缘内缩 1pt —— 与菜单块「行高 − 1」同一套做法：接缝处露出一线原底色，
        // 每个块读作独立的一块玻璃，而不是连成一条灰带。仅作用于非菜单块。
        let frameW = item.isMenu ? blockW : max(8, blockW - 1)
        self.frame = NSRect(x: x, y: y, width: frameW, height: blockH)
        baseFrame = self.frame
        tint.frame = bounds
        vibrancy?.frame = bounds

        // —— 多行段落「盖不全 / 译文被裁」几何探针（临时诊断，验收后删除）——
        // 背景：用户 2026-10-13 截图显示一段 3 行英文只被盖住前两行，译文也像是被压在一起。
        // 两个可能的凶手必须用数字分开：① 捕捉矩形本身只有 2 行高（采集漏行）；
        // ② 矩形够高但块高被算小（渲染 bug，label 被 masksToBounds 裁掉末行）。
        // 这里只落尺寸数字，**不含任何屏幕文本**（隐私红线）。
        if !item.isMenu, TranslationBlock.fitProbeGate() {
            let need = fittedTextSize.height + fitPadY * 2
            // est = 按「原文文字宽度 ÷ 矩形宽」推算的原文行数。
            let srcW = (item.text as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: pt)]).width
            let est = max(1, Int((srcW / max(local.width, 1)).rounded(.up)))
            // —— 两个方向都要抓（2026-10-13 用户截图：大标题只被盖住中间一条 + 段落第 3 行露出）——
            // ① `lowRect=1`：**矩形比原文实际占位矮**（AX 只报一条/半行框）→ 块盖不住原文上下。
            //    判据：rectH < 原文估算渲染高(est × 字号 × 1.25) 的 80%。
            // ② `container=1`：**矩形比原文实际占位大得多**（网页容器盒 div/section）→ 满屏巨块
            //    只配一小行字。判据：rectH > 原文估算高的 2.5 倍且 rectH > 60。
            // `len` = 原文字符数（只记长度，不记内容，隐私安全）。
            let srcTextH = CGFloat(est) * pt * 1.25
            let lowRect = local.height < srcTextH * 0.8
            let container = local.height > max(srcTextH, 24) * 2.5 && local.height > 60
            AXTextExtractor.diagLog(String(
                format: "BLOCKFIT src=%@ role=%@ y=%.0f len=%d rectH=%.0f rectW=%.0f pt0=%.1f pt=%.1f "
                    + "est=%d srcH=%.0f lowRect=%d container=%d fitW=%.0f fitH=%.0f "
                    + "blockW=%.0f blockH=%.0f need=%.0f risk=%d",
                item.source == .ax ? "ax" : "ocr", item.axRole.isEmpty ? "-" : item.axRole,
                local.origin.y, item.text.count, local.height, local.width,
                pt, label.font?.pointSize ?? 0, est, srcTextH,
                lowRect ? 1 : 0, container ? 1 : 0,
                fittedTextSize.width, fittedTextSize.height,
                blockW, blockH, need, need > blockH + 0.5 ? 1 : 0))
        }

        // 无障碍：覆盖层是纯视觉的，补上可访问性标签让 VoiceOver 也能读出译文。
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityLabel(text)

        // 调试：描红框便于核对坐标。
        if debug {
            self.layer?.borderWidth = 1.5
            self.layer?.borderColor = NSColor.systemRed.cgColor
            self.layer?.cornerRadius = 8
        } else {
            self.layer?.borderWidth = 0
        }
    }

    private func displayText(for item: CapturedText) -> String {
        item.displayText
    }

    /// 是否为「网页容器盒」：矩形巨大、里面实际却只有一小段文字。
    /// 只做纯几何判断，与角色无关——实测在 AXGroup / AXButton / AXHeading 上都出现过。
    /// 为什么必须砍掉它（2026-10-13 Safari 实测，见 TranslationOverlayView.reloadBlocks 的详细说明）：
    /// ① 照容器盒画就是「满屏毛玻璃配一小行字」；
    /// ② 更致命——巨块的矩形把里面的标题块与段落块整个套住，触发重叠消解，
    ///    把那些正常文字块上推并砍掉最多 40% 高度 → 英文上下半截露在块外。
    /// 正常多行段落（85pt / 150pt）不满足该判据，不会被误伤。
    static func isContainerBox(_ item: CapturedText) -> Bool {
        let pt = autoPointSize(lineHeight: item.rect.height,
                               rectWidth: item.rect.width,
                               sourceText: item.text,
                               isMenu: item.isMenu,
                               isMenuBarTitle: item.menuBarTitle)
        let srcW = (item.text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: pt)]).width
        let est = max(1, Int((srcW / max(item.rect.width, 1)).rounded(.up)))
        let srcH = CGFloat(est) * pt * 1.25
        return item.rect.height > max(srcH, 24) * 2.5 && item.rect.height > 60
    }

    /// 自动字号：由原文的「单行行高」反推，让译文与原文**视觉同尺寸**（不再提供手动字号）。
    /// - 菜单栏标题：系统菜单栏真实字号 13–14pt，带高 24–30pt ⇒ 系数 0.55，夹到 10–15pt。
    /// - 下拉菜单项：条目行高通常 20–24pt ⇒ 系数 0.62，夹到 10–16pt。
    /// - 正文：先按 13pt 行高估出行数再反推单行行高——否则一个 5 行段落会被当成
    ///   「单行超高文本」算出 30pt 的巨型字，块面随之远超原文（遮挡失控）。
    /// 夹取上下限的意义：低于 10pt 读不清，高于 20pt 的译文几乎必然比原文宽，
    /// 会把块撑到原文之外。
    private static func autoPointSize(lineHeight h: CGFloat,
                                      rectWidth w: CGFloat,
                                      sourceText source: String,
                                      isMenu: Bool,
                                      isMenuBarTitle: Bool) -> CGFloat {
        if isMenuBarTitle { return min(max(h * 0.55, 10), 15) }
        if isMenu         { return min(max(h * 0.62, 10), 16) }
        // 行数按「原文文本宽度 ÷ 矩形宽」估算，而不是按矩形高估：
        // 后者会把带内边距的控件误判——实测 Title Page 按钮矩形 67×42、里面只有一行 13pt 文字，
        // 按高估算得 lines=2 → 推出 15pt，译文明显比原文大。用文本宽度估行数才反映真实排版。
        let probeW = (source as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let lines = max(1, Int((probeW / max(w, 1)).rounded(.up)))
        // 单行封顶 14pt：控件矩形再高（按钮 42pt 含内边距），里面也只有一行字，
        // 放任高度去推字号就会得出 20–30pt 的巨字。多行段落才放宽到 20。
        let cap: CGFloat = lines > 1 ? 20 : 14
        return min(max(h / CGFloat(lines) * 0.72, 10), cap)
    }

    /// 某点所在屏幕的「菜单栏带」：返回带的底边 y 与高度（AppKit 坐标）。
    /// macOS 菜单栏永远贴在屏幕最顶：底边 = visibleFrame.maxY，高度 = frame.maxY − visibleFrame.maxY。
    /// 高度做 14–48pt  sanity clamp：异常屏（全屏 app 隐藏菜单栏时返回 0）宁可回退矩形定位，
    /// 也不要画出一条 0 高或整屏高的怪块。
    private static func menuBarBand(containing point: NSPoint) -> (bottom: CGFloat, height: CGFloat)? {
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.frame.minX <= point.x && point.x <= $0.frame.maxX }
            ?? NSScreen.main
        guard let s = screen else { return nil }
        let h = s.frame.maxY - s.visibleFrame.maxY
        guard h >= 14, h <= 48 else { return nil }
        return (s.visibleFrame.maxY, h)
    }
}

/// 覆盖层容器：管理一组译文毛玻璃块（按捕捉项数量复用）。
/// 窗口本身全透明：融合态下真实菜单栏直接透出（状态图标可见），译文块只叠在识别到的文字上。
/// 覆盖层容器：管理两组译文毛玻璃块——**菜单层**（菜单栏标题 + 下拉条目）与
/// **窗口层**（其余界面 / 正文文字），两层各自维护独立的块池与增量渲染缓存。
///
/// 为什么拆两层（2026-10-13 用户拍板 Plan A）：
/// 之前菜单项与窗口内容混在**同一个 `items` 数组、同一套按下标复用的缓存**里。
/// 窗口内容一变（滚动 / 悬停 / AX 亚像素抖动）就会让整条排序后的数组下标重排，
/// 菜单块在新数组里的槽位对不上 → 被当成「变了」→ 全盘重排 → 用户看到的「整体页面跳动」。
/// 拆层后：窗口层怎么抖，都**碰不到菜单层的缓存**；菜单层只在自身行高变化时重绘，
/// 视觉上两层各自独立、互不牵连，跳动消失。改动仅限本文件，菜单采集链路一行未动。
final class TranslationOverlayView: NSView {
    var items: [CapturedText] = [] {
        didSet { reloadBlocks() }
    }

    /// 调试用：给每个块描红框，便于在真机上核对坐标对齐。
    var drawDebugOutlines = false

    // —— 两层独立块池（Plan A，2026-10-13 二改：下标复用 → 内容键复用）——
    // 之前用「下标槽位」复用缓存：上游 items 每帧都重排（SHAKE 实测 orderChanged 每帧都变），
    // 下标 i 对上的不再是同一个菜单项 → 被判「变了」→ 每帧重排 → 菜单栏持续闪/抖。
    // 改用 **内容稳定键 (原文 + 量化矩形)** 复用：顺序怎么翻、数量怎么变，
    // 同一个屏幕词永远映射到同一块，内容没变就绝不重排、绝不重放 popIn。
    private var menuPool: [String: TranslationBlock] = [:]      // isMenu 项（菜单栏标题 + 下拉条目）
    private var windowPool: [String: TranslationBlock] = [:]    // 非菜单项（界面 / 正文）

    /// 「按住 Option 偷看原文」状态：为真时，光标所指的译文块隐藏，露出原界面。
    var peekActive = false
    /// 光标位置（AppKit 屏幕坐标，原点左下）。
    var peekPoint = NSPoint.zero

    // —— 每层独立的增量渲染缓存与帧矩形（互不牵连 + 内容键寻址）——
    private var menuRendered: [String: (text: String, rect: NSRect)] = [:]
    private var windowRendered: [String: (text: String, rect: NSRect)] = [:]
    private var menuBlockFrames: [String: NSRect] = [:]
    private var windowBlockFrames: [String: NSRect] = [:]
    /// 回收用：每个内容键最后一次出现的时刻，超过 0.5s 未出现则从视图树移除，避免块无限堆积。
    private var menuLastSeen: [String: CFTimeInterval] = [:]
    private var windowLastSeen: [String: CFTimeInterval] = [:]
    /// 菜单层专用：上一帧下拉菜单行高（显著变化才清菜单缓存、强制重排）。
    private var lastMenuRowHeight: CGFloat?
    /// 菜单层「隐藏/显示」闪烁探针（临时诊断）：本采样窗内菜单层新建块数（popIn 来源）
    /// 与被隐藏块数（回收来源）。理想应趋近 0；若持续 >0，说明菜单层内容键仍不稳定。
    private var menuNewCount = 0
    private var menuHiddenCount = 0

    /// 内容稳定键：归一化原文 + 量化矩形。
    /// - 用「归一化原文」而非裸文本：AX 菜单项文本常带尾随空格 / 双向排版控制符（如 U+200E），
    ///   这些不可见字符逐帧抖动会让裸文本键翻面 → 块反复重建（isNew 触发 popIn）→ 菜单栏闪烁。
    ///   归一化（去控制符 + 去首尾空白）后，同一屏幕词稳定映射到同一块。
    /// - 用原文而非译文做键：译文异步到达时键不变 → 只换文字、不重放 popIn，视觉不闪。
    /// 内容稳定键。
    /// - 菜单层（isMenu）：以「归一化文本」为主键 + 粗量化 midY（/10pt 桶）区分不同层级/位置
    ///   同名项（菜单栏标题与下拉条目可能同名）。**不用矩形四元组**——
    ///   之前下拉菜单项的 `rect.height` 在整数边界逐帧抖动（如 23.6↔24.4 → Int 23↔24），
    ///   直接让内容键翻面 → 旧块被回收隐藏、新块重建 popIn = 菜单「一直在隐藏和显示」的闪。
    ///   而 SHAKE 的 rectDiff 探针键不含 height，掩盖了它。midY（行中心，间隔 24pt、抖动 <1pt）
    ///   比 height 稳定得多，/10 量化对 ±4pt 抖动免疫，彻底隔离该抖动源。
    /// - 窗口层：归一化文本 + 精确量化矩形（现状，已稳 win=0）。
    private static func contentKey(_ item: CapturedText, isMenu: Bool) -> String {
        let t = Self.normText(item.text)
        if isMenu {
            return "\(t)@\(Int(item.rect.midY / 10))"
        }
        return "\(t)|\(Int(item.rect.origin.x))|\(Int(item.rect.origin.y))"
            + "|\(Int(item.rect.width))|\(Int(item.rect.height))"
    }

    /// 归一化文本：剔除全部 Unicode 控制字符与 bidi/格式字符（含 LRM/RLM/BOM 以及
    /// 全部 bidi 隔离符 LRE/RLE/PDF/LRO/RLO/LRI/RLI/FSI/PDI 等不可见字符），并去掉首尾空白。
    /// 目的：消除 AX 文本逐帧携带的不可见字符抖动，稳定块复用键。
    /// （基于码点值范围判断，避免依赖不同 SDK 下 API 差异。）
    private static func normText(_ s: String) -> String {
        let filtered = s.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v < 0x20 { return false }                       // C0 控制符
            if v == 0x7F { return false }                       // DEL
            if v >= 0x80, v <= 0x9F { return false }            // C1 控制符
            if v == 0x200E || v == 0x200F || v == 0xFEFF { return false }  // LRM/RLM/BOM
            if v >= 0x202A, v <= 0x202E { return false }       // LRE/RLE/PDF/LRO/RLO
            if v >= 0x2066, v <= 0x2069 { return false }       // LRI/RLI/FSI/PDI 隔离符
            return true
        }
        return String(filtered.map { Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 需要图层树，菜单层块才能用 zPosition 稳定压在窗口层之上。
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 覆盖层永远鼠标穿透：译文块只是视觉层，交互（穿透/拖动/按钮）
    /// 由各状态的窗口容器统一调度。返回 nil 让事件落到下层窗口。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func reloadBlocks() {
        guard let win = self.window else { return }
        // 直接用窗口左下角全局坐标作为原点，等价于窗口内容视图原点
        // （fullSizeContentView 下内容视图无标题栏偏移），最稳。
        let originScreen = win.frame.origin

        // 两层分池：菜单项独立成序列，下标不再被窗口项数量 / 顺序变化挤动——
        // 这是「菜单层不受窗口抖动牵连」的根治点。
        let menuItems = items.filter { $0.isMenu }
        let windowItems = items.filter { !$0.isMenu }

        let menuReconf = renderLayer(menuItems, into: &menuPool, rendered: &menuRendered,
                                     rowHeight: menuRowHeight(from: menuItems), isMenu: true,
                                     originScreen: originScreen, frames: &menuBlockFrames,
                                     zPosition: 10)
        let windowReconf = renderLayer(windowItems, into: &windowPool, rendered: &windowRendered,
                                       rowHeight: nil, isMenu: false,
                                       originScreen: originScreen, frames: &windowBlockFrames,
                                       zPosition: 0)

        shakeProbe(menu: menuReconf, window: windowReconf)
        updatePeekVisibility()
        menuVisibleProbe(itemsIn: menuItems.count)
        windowLayoutProbe(windowItems)
    }

    /// 窗口层布局对照探针（2026-10-13 修「窗口内容翻译不好 / 有的没翻译」）：
    /// 逐项把「源矩形（AX 给的原文框）→ 最终块 frame」摊开，并标出该项是**跳过**（容器盒）、
    /// **隐藏**（没画出来）还是**已画**。这样"哪些项没有块""块画到哪去了"一眼可见，
    /// 不必再靠截图猜。只记坐标/尺寸/字符数，**不落任何屏幕文本**（隐私红线）。
    private func windowLayoutProbe(_ source: [CapturedText]) {
        guard !source.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard now - Self.lastWinLayAt > 2 else { return }
        Self.lastWinLayAt = now
        // 坐标原点一并输出：块 frame 是「overlay 窗口内坐标」，源 rect 是「屏幕坐标」，
        // 两者相减必须恒等于窗口原点。若对不上，就是整层块错位的根因（一眼可辨）。
        let org = self.window?.frame.origin ?? .zero
        var parts: [String] = []
        var drawn = 0, hiddenN = 0, skipped = 0
        for it in source.prefix(26) {
            let isContainer = TranslationBlock.isContainerBox(it)
            if isContainer { skipped += 1 }
            let b = windowPool[Self.contentKey(it, isMenu: false)]
            let isHidden = (b?.isHidden ?? true)
            if !isHidden { drawn += 1 } else if !isContainer { hiddenN += 1 }
            let f = b?.frame ?? .zero
            let tag = isContainer ? "S" : (isHidden ? "h" : "o")
            // L<原文长>>译文长：两者相等即「译文本帧退回原文」（没翻译或翻译未到位）。
            parts.append(String(format: "%@L%d>%d s[%d,%d %dx%d] b[%d,%d %dx%d]",
                                tag, it.text.count, it.displayText.count,
                                Int(it.rect.minX), Int(it.rect.minY),
                                Int(it.rect.width), Int(it.rect.height),
                                Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)))
        }
        AXTextExtractor.diagLog("WINLAY feed=\(source.count) drawn=\(drawn) hidden=\(hiddenN) "
            + "containerSkip=\(skipped) org=[\(Int(org.x)),\(Int(org.y))] winH=\(Int(self.window?.frame.height ?? 0)) "
            + "| " + parts.joined(separator: " | "))
    }

    private static var lastWinLayAt: CFTimeInterval = 0

    /// 端到端探针（2026-10-13 修「下拉收回去后译文残影迟迟不走」）：
    /// 引擎侧的所有计数都只是**中间态**，用户看到的永远是"屏幕上还剩几个菜单块"。
    /// 这里统计 menuPool 里 isHidden=false 的块数，**只要数字变化立刻打时间戳**——
    /// 于是「菜单关闭」到「屏幕清零」的真实端到端耗时可以直接从相邻两条日志相减得出，
    /// 不用再靠猜。只记计数，**不落任何屏幕文本**（隐私红线）。
    private func menuVisibleProbe(itemsIn: Int) {
        var visible = 0
        for (_, b) in menuPool where !b.isHidden { visible += 1 }
        guard visible != lastMenuVisible else { return }
        let now = CACurrentMediaTime()
        let dt = lastMenuVisibleAt > 0 ? now - lastMenuVisibleAt : 0
        // ov= 实例标识（2026-10-13 修）：主覆盖层与融合覆盖层是**两个 overlay 实例**，
        // 旧实现把计数存成 static，两个实例互相覆盖 → 日志里的数字可能在两个实例间跳，
        // 根本不代表「屏幕上真实还剩几块」（本探针存在的唯一意义就是回答这个问题）。
        let tag = String(format: "%04X", UInt(bitPattern: ObjectIdentifier(self)) % 0x10000)
        AXTextExtractor.diagLog(String(format: "BLKVIS ov=%@ menu=%d (was %d, held %.2fs) feed=%d",
                                       tag, visible, lastMenuVisible, dt, itemsIn))
        lastMenuVisible = visible
        lastMenuVisibleAt = now
    }

    // 改为**实例**属性：每个 overlay 各记各的，互不干扰（见上方 menuVisibleProbe 说明）。
    private var lastMenuVisible = -1
    private var lastMenuVisibleAt: CFTimeInterval = 0

    /// 单层渲染：确保池容量、按本层独立的增量缓存决定重排、复位基准 frame、做 pop 入。
    /// 仅菜单层走行高迟滞（窗口层永不因行高变化重排，彻底隔离跳动源）。
    /// 返回本层这帧被重新布局的块数（供抖动探针统计）。
    @discardableResult
    private func renderLayer(_ layerItems: [CapturedText],
                             into pool: inout [String: TranslationBlock],
                             rendered: inout [String: (text: String, rect: NSRect)],
                             rowHeight: CGFloat?,
                             isMenu: Bool,
                             originScreen: NSPoint,
                             frames: inout [String: NSRect],
                             zPosition: CGFloat) -> Int {
        // 容器盒（仅窗口层）不参与：提前剔除，避免占位错位。
        let eligible = layerItems.filter { !(!$0.isMenu && TranslationBlock.isContainerBox($0)) }
        // 稳定排序：无论上游 items 如何重排（SHAKE 实测 orderChanged 每帧都变），
        // 同一组内容在数组里的相对位置恒定 → 仍以内容键复用，顺序翻转不再触发重排。
        let ordered = eligible.sorted { (a, b) in
            let ya = a.rect.midY, yb = b.rect.midY
            if abs(ya - yb) > 0.5 { return ya > yb }   // 屏幕自上向下
            return a.rect.minX < b.rect.minX
        }

        let now = CACurrentMediaTime()
        var seen = isMenu ? menuLastSeen : windowLastSeen

        var reconfigured = 0

        // 行高迟滞：仅菜单层。窗口层始终 false（不依赖行高，永不因菜单行高变化重排）。
        var rowHChanged = false
        if isMenu {
            if let r = rowHeight, let l = lastMenuRowHeight {
                rowHChanged = abs(r - l) > 1          // 1pt 以内的浮动保持现有布局，不重排
            } else {
                rowHChanged = (rowHeight != lastMenuRowHeight)  // 「无菜单 ⇄ 有菜单」切换才走这里
            }
            // 必须写 inout 参数 `rendered`，**绝不能直接写实例属性 menuRendered**：
            // 调用方传的是 `&menuRendered`，inout 的写访问贯穿整个函数体；此时再直接
            // 访问同一个实例属性就是「两条路径同时访问同一存储」→ Swift 运行时报
            // exclusivity violation → fatalError → 进程 abort（今日多份 .ips 已确认）。
            if rowHChanged { rendered = [:]; lastMenuRowHeight = rowHeight }
        }

        var aliveKeys = Set<String>()
        var blocks: [TranslationBlock] = []
        for item in ordered {
            let key = Self.contentKey(item, isMenu: isMenu)
            aliveKeys.insert(key)
            // 内容键复用：同一个屏幕词永远拿到同一块，内容没变就绝不重排。
            let b: TranslationBlock
            let isNew: Bool
            if let existing = pool[key] {
                b = existing; isNew = false
            } else {
                b = TranslationBlock()
                b.isHidden = true
                pool[key] = b
                addSubview(b)
                isNew = true
            }
            blocks.append(b)

            // —— 译文保持（根治菜单栏「自己闪」）——
            // 上游译文是异步的：某帧原文未翻（displayText 退回 source）而本键之前已画过译文时，
            // 继续显示之前的译文，绝不退回原文。否则「原文↔译文」逐帧来回翻 = 肉眼闪烁。
            let candidate = item.displayText
            let prevPainted = rendered[key]?.text
            let holdTranslation = candidate == item.text
                && prevPainted != nil && prevPainted != item.text
            let painted = holdTranslation ? prevPainted! : candidate

            let cached = rendered[key]
            let unchanged = cached != nil
                && cached!.text == painted
                && cached!.rect == item.rect
            if !unchanged {
                reconfigured += 1
                b.configure(item: item, originScreen: originScreen, rowHeight: rowHeight,
                            debug: drawDebugOutlines, overrideText: holdTranslation ? painted : nil)
                b.alphaValue = 1
                b.layer?.setAffineTransform(.identity)
                b.setHovered(false)   // 块复用防残留：内容已换，悬停高亮必须清零
                rendered[key] = (painted, item.rect)
            } else {
                // 内容未变：复位到基准 frame（可能上一帧被重叠消解压过），绝不重排。
                b.frame = b.baseFrame
            }
            b.isHidden = false
            b.layer?.zPosition = zPosition   // 菜单层恒压在窗口层之上
            if isNew {                       // 仅「新词出现」播放一次 pop，复用/重显绝不重放 → 不闪
                popIn(b)
                if isMenu { menuNewCount += 1 }
            }
        }

        // 重叠消解仅作用于窗口层（菜单块整体豁免）。
        if !isMenu {
            resolveOverlaps(pool: blocks, items: ordered)
        }
        // 写帧矩形（按内容键）；容器盒本帧未参与，自然不再写入 → 失效键被下方回收。
        frames.removeAll()
        for (item, b) in zip(ordered, blocks) {
            let key = Self.contentKey(item, isMenu: isMenu)
            frames[key] = NSRect(x: b.frame.origin.x + originScreen.x,
                                 y: b.frame.origin.y + originScreen.y,
                                 width: b.frame.width,
                                 height: b.frame.height)
            seen[key] = now
        }
        // 隐藏并回收不再出现的块（>0.12s 未出现才从视图树移除，避免堆积）。
        //
        // 注意：**视觉上的消失由上面的 `b.isHidden = true` 决定，是即时的**；
        // 这里的 0.12s 只是把块真正从视图树摘掉、释放内存。原来设 0.5s 是为了
        // 容忍"下一拍又回来"避免重建开销，但下拉菜单关闭后用户会看到译文
        // 迟迟不撤，故压到 0.12s（仍够跨过一两帧抖动，不会导致频繁重建）。
        //
        // **必须分两趟，绝不能在遍历 inout 字典时删除它的元素**：
        // `for (key, b) in pool` 会持有 pool 的**读访问直到循环结束**，此时循环体内再执行
        // `pool.removeValue(forKey:)`（写访问）就构成读写重叠 —— Swift 运行时抛
        // "Simultaneous accesses ..., but modification requires exclusive access"，
        // 直接 fatalError → abort。崩溃报告里 `_swift_reportExclusivityConflict ←
        // renderLayer ← reloadBlocks` 就是这个（今日 09:18 / 10:02 / 10:56 / 11:13 多份 .ips）。
        // 第一趟只收集（只读），第二趟等读访问释放后再统一删除。
        var deadKeys: [String] = []
        for (key, b) in pool {
            if !aliveKeys.contains(key) {
                b.isHidden = true
                if isMenu { menuHiddenCount += 1 }
                if now - (seen[key] ?? 0) > 0.12 { deadKeys.append(key) }
            }
        }
        // 上面的读访问已随循环结束而释放，此处再写不再冲突。
        for key in deadKeys {
            pool[key]?.removeFromSuperview()
            pool.removeValue(forKey: key)
            rendered.removeValue(forKey: key)
            frames.removeValue(forKey: key)
            seen.removeValue(forKey: key)
        }
        if isMenu { menuLastSeen = seen } else { windowLastSeen = seen }
        return reconfigured
    }

    // MARK: - 渲染抖动探针（临时诊断，验收后整块删除）

    private var shakeFrames = 0
    private var shakeMenuReconf = 0
    private var shakeWindowReconf = 0
    private var shakeRectDiff = 0
    private var shakeOrderDiff = 0
    private var lastShakeAt: CFTimeInterval = 0
    private var lastKeys: [String] = []
    private var lastKeyRects: [String: NSRect] = [:]

    /// 把「为什么抖」变成可读数（每 2 秒一条），**菜单层 / 窗口层分别报**：
    /// - `menu`：菜单层（菜单栏标题 + 下拉条目）平均每帧重配置块数 —— 理想应趋近 0；
    ///   若它高，说明菜单栏闪烁来自菜单层内容逐帧变化（文本/译文抖动）。
    /// - `win`：窗口层同上。
    /// - `rectDiff` / `orderChanged`：坐标 / 排序稳定性（备注：orderChanged 用位置键，顺序翻转会误报，仅供参考）。
    /// 只记坐标与计数，**不落任何屏幕文本**（隐私红线）。
    private func shakeProbe(menu menuReconf: Int, window windowReconf: Int) {
        let keys = items.map { item -> String in
            let src = item.source == .ax ? "a" : "o"
            return "\(src)\(Int(item.rect.minX))x\(Int(item.rect.minY))w\(Int(item.rect.width))"
        }
        var rectDiff = 0
        var newRects: [String: NSRect] = [:]
        for (k, item) in zip(keys, items) {
            if let old = lastKeyRects[k], old != item.rect { rectDiff += 1 }
            newRects[k] = item.rect
        }
        if keys != lastKeys { shakeOrderDiff += 1 }
        shakeFrames += 1
        shakeMenuReconf += menuReconf
        shakeWindowReconf += windowReconf
        shakeRectDiff += rectDiff
        lastKeys = keys
        lastKeyRects = newRects

        let now = CACurrentMediaTime()
        guard now - lastShakeAt > 2, shakeFrames > 0 else { return }
        lastShakeAt = now
        let f = Double(max(shakeFrames, 1))
        let msg = String(format: "SHAKE frames=%d menu=%.1f win=%.1f rectDiff=%.1f orderChanged=%d n=%d menuNew=%d menuHidden=%d",
                         shakeFrames, Double(shakeMenuReconf) / f,
                         Double(shakeWindowReconf) / f,
                         Double(shakeRectDiff) / f, shakeOrderDiff, items.count,
                         menuNewCount, menuHiddenCount)
        AXTextExtractor.diagLog(msg)
        shakeFrames = 0; shakeMenuReconf = 0; shakeWindowReconf = 0; shakeRectDiff = 0; shakeOrderDiff = 0
        menuNewCount = 0; menuHiddenCount = 0
    }

    /// 下拉菜单的**真实行高**：同组相邻条目 midY 间距的中位数。
    /// 为什么需要它——AX 给的菜单项矩形只是「文字紧致框」（真机实测约 12pt），
    /// 而系统菜单每行实际约 20pt。照矩形画块只盖住英文上半截，字母下半截从块底露出来。
    /// 相邻条目的间距恰好等于真实行高（与矩形是否偏矮/偏上无关，最稳），取中位数抗分隔线干扰。
    /// 仅菜单层调用（窗口层不依赖行高），这是「两层互不牵连」把行高抖动隔离在菜单层内的关键。
    private func menuRowHeight(from rows: [CapturedText]) -> CGFloat? {
        let menuRows = rows.filter { !$0.menuBarTitle }
        guard menuRows.count >= 3 else { return nil }
        let ys = menuRows.map { $0.rect.midY }.sorted()
        var gaps: [CGFloat] = []
        for i in 1..<ys.count {
            let d = ys[i] - ys[i - 1]
            if d > 8, d < 80 { gaps.append(d) }   // 排除「跨分隔线/跨分组」的异常间距
        }
        guard gaps.count >= 2 else { return nil }
        gaps.sort()
        let med = gaps[gaps.count / 2]
        // 稳定性关键（2026-10-13 修「抖动厉害」）：量化到 1pt 网格，抖不掉 ±0.5pt 就不足以触发重排。
        return med.rounded()
    }

    /// 重叠消解（世界级细节）：任何两个译文块都不允许互相压盖。
    /// 双路来源的矩形松紧不一、AX 行框偶有抖动，都可能让相邻块纵向相交——
    /// 这里按屏幕从上到下扫描，相交时修剪下方块的顶边（上限其高度的 15%，
    /// 文字垂直居中约束会自动重新居中，不会被裁掉）。
    /// 仅作用于**窗口层**（菜单块整体豁免，由 renderLayer 只在窗口层调用本方法）。
    private func resolveOverlaps(pool: [TranslationBlock], items: [CapturedText]) {
        let visible = pool.indices.filter { !pool[$0].isHidden && $0 < items.count }
        guard visible.count > 1 else { return }
        // 只让「普通高度的正文块」参与消解（2026-10-13）：
        // 消解的本意是抚平松紧不一的正文矩形，不是给大块做减法；
        // 让高块进来只会把相邻的小文字块压扁（Safari 上实测被砍掉 40%）。
        let targets = visible.filter { pool[$0].frame.height <= 60 }
        guard targets.count > 1 else { return }
        // AppKit 视图坐标 Y 向上：midY 大的在屏幕上方
        let sorted = targets.sorted { pool[$0].frame.midY > pool[$1].frame.midY }
        var trimCount = 0
        var trimWorst: CGFloat = 0
        for j in 1..<sorted.count {
            let upper = pool[sorted[j - 1]].frame
            var lower = pool[sorted[j]].frame
            // 只处理横向也有交叠的真压盖（同列相邻行）
            guard upper.maxY > lower.minY + 0.5,
                  upper.minX < lower.maxX, lower.minX < upper.maxX else { continue }
            let overlap = upper.maxY - lower.minY
            // 上限 15%（2026-10-13）：40% 足以把一块 58pt 的标题砍成 35pt，
            // 英文上下半截因此露在块外（用户截图「只盖住中间一条」）。消解只需削掉发丝级重叠。
            let maxTrim = lower.height * 0.15
            let trim = min(overlap, maxTrim)
            guard trim > 0.5 else { continue }
            lower.origin.y += trim
            lower.size.height -= trim
            pool[sorted[j]].frame = lower
            trimCount += 1
            trimWorst = max(trimWorst, trim)
        }
        // 探针（临时诊断）：块在最后一步被"上推 + 压矮"了多少 ——
        // 这是唯一会在 configure 之外改动块高的地方，若"盖不住原文"来自这里，只有它看得见。
        if trimCount > 0, CACurrentMediaTime() - Self.lastTrimDiagAt > 2 {
            Self.lastTrimDiagAt = CACurrentMediaTime()
            AXTextExtractor.diagLog("OVERLAPTRIM n=\(trimCount) worst=\(String(format: "%.1f", trimWorst))")
        }
    }

    private static var lastTrimDiagAt: CFTimeInterval = 0

    /// 新出现的译文块做克制的「微缩放 + 淡入」pop，避免"啪"地贴上、也更有生命感。
    /// 缩放从 0.94 → 1.0，透明度 0 → 1，easeOut 0.18s。
    /// 缩放与透明度都走同一条 CATransaction，保证两属性严格同步动画、互不抢拍。
    /// 尊重系统「减弱动态效果」偏好：开启时直接显示，不做任何动效。
    private func popIn(_ block: TranslationBlock) {
        guard let layer = block.layer else { block.alphaValue = 1; return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            block.alphaValue = 1
            layer.setAffineTransform(.identity)
            return
        }
        // 起始：94% 缩放 + 全透明（直接落模型值，瞬时就位，再由事务动画到终态）
        layer.opacity = 0
        layer.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.opacity = 1
        layer.setAffineTransform(.identity)
        CATransaction.commit()
    }

    /// 鼠标移动 / Option 状态变化时，仅切换可见性（不重算布局），开销低。
    func applyPeek(active: Bool, point: NSPoint) {
        peekActive = active
        peekPoint = point
        updatePeekVisibility()
    }

    /// 悬停高亮（2026-10-12 用户）：鼠标移到**菜单类块**上时反蓝加亮、移出恢复。
    /// 菜单块只在菜单层（menuPool），窗口层（windowPool）天然无菜单块，故永不参与。
    func applyHover(point: NSPoint) {
        var hitKey: String?
        for (key, frame) in menuBlockFrames {
            guard let b = menuPool[key], !b.isHidden, frame.contains(point) else { continue }
            hitKey = key
            break
        }
        for (key, b) in menuPool { b.setHovered(key == hitKey) }
        for (_, b) in windowPool { b.setHovered(false) }
    }

    /// 「偷看原文」：指针落在译文块上时，把该块 alpha 渐隐到 0，露出底下原界面文字；
    /// 移开后渐显回 1。用 alpha 而非 isHidden，使揭开/盖回是平滑过渡而非硬切。
    /// 尊重系统「减弱动态效果」：开启时直接切换、不做渐变。
    private func updatePeekVisibility() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // 菜单层：peek 激活时菜单块先让出悬停高亮（淡出露原文优先）。
        for (key, b) in menuPool {
            guard !b.isHidden, let frame = menuBlockFrames[key] else { continue }
            let near = peekActive && frame.insetBy(dx: -8, dy: -8).contains(peekPoint)
            b.setHovered(false)
            setPeekAlpha(b, near ? 0 : 1, reduce)
        }
        // 窗口层：窗口块不参与悬停高亮，仅受 peek 显隐控制。
        for (key, b) in windowPool {
            guard !b.isHidden, let frame = windowBlockFrames[key] else { continue }
            let near = peekActive && frame.insetBy(dx: -8, dy: -8).contains(peekPoint)
            setPeekAlpha(b, near ? 0 : 1, reduce)
        }
    }

    private func setPeekAlpha(_ block: TranslationBlock, _ target: CGFloat, _ reduce: Bool) {
        guard block.alphaValue != target else { return }
        if reduce {
            block.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                block.animator().alphaValue = target
            }
        }
    }

    /// 窗口/屏幕移动后强制重算块坐标。
    func reflow() { reloadBlocks() }
}
