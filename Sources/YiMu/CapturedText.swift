import Foundation
import CoreGraphics

/// 取字来源。
enum CaptureSource: String {
    case ax   // 无障碍接口
    case ocr  // 屏幕截图 OCR 兜底
}

/// 一段被捕捉到的文本及其在屏幕上的全局矩形。
/// rect 使用 AppKit 坐标系：原点在「主屏左下角」、Y 轴向上。
struct CapturedText: Identifiable, Hashable {
    let id: UUID
    let text: String
    let rect: NSRect
    let source: CaptureSource
    /// 覆盖层显示文本：默认等于原文；阶段3 起被异步翻译结果替换。
    var displayText: String
    /// 采自菜单栏 / 下拉菜单：这类条目必须独立成块，
    /// 不参与「行内合并」——否则整条菜单栏会被拼成一长串文字。
    var isMenu: Bool
    /// 菜单栏标题（AXMenuBar 的直接子项）：与下拉菜单条目分开做坐标校准。
    var menuBarTitle: Bool
    /// AX 角色名（如 `AXStaticText` / `AXButton`；OCR 项为空串）。仅用于诊断与合并判定，不参与渲染。
    var axRole: String
    /// 该条目是否由「行内合并」产生。
    /// 用途（2026-10-13 修 IMDb 顶部「一块里塞了好几个译文」）：合并结果**不再参与后续合并**，
    /// 防止 A+B 合成后又被 C 吸附、一路级联拼成一长串
    /// （实测 MERGE_LINES 里出现 `ocr+AXLink gap=-1.0` —— 正是合并产物又去合并的痕迹）。
    var didMerge: Bool

    /// 该文本是否**属于某个控件**（自身是控件，或位于控件内部，如 AXButton 里的 AXStaticText）。
    ///
    /// 为什么需要它（2026-10-13 用户报「词汇没有断开、混合排在一起」）：
    /// 工具栏上并排的按钮（Final Draft 的 Split / Views / Beat Board）各自暴露一个文字元素，
    /// 它们的标签天然同行、间距又小，被「行内合并」当成一整句拼成
    /// 「Split Views Beat Board」→ 翻译成「分割视图节拍板」→ 再按并集矩形渲染成一个
    /// 横跨三个按钮的大块。**控件标签必须独立成块**，绝不与邻居拼接。
    var isControl: Bool

    init(id: UUID = UUID(), text: String, rect: NSRect, source: CaptureSource,
         displayText: String? = nil, isMenu: Bool = false, menuBarTitle: Bool = false,
         axRole: String = "", isControl: Bool = false, didMerge: Bool = false) {
        self.id = id
        self.text = text
        self.rect = rect
        self.source = source
        self.displayText = displayText ?? text
        self.isMenu = isMenu
        self.menuBarTitle = menuBarTitle
        self.axRole = axRole
        self.isControl = isControl
        self.didMerge = didMerge
    }

    /// 返回矩形裁剪到 `region` 后的副本（镜头框 / 区域裁剪用）。
    func clipped(to region: NSRect) -> CapturedText {
        CapturedText(id: id, text: text, rect: rect.intersection(region),
                     source: source, displayText: displayText, isMenu: isMenu,
                     menuBarTitle: menuBarTitle, axRole: axRole, isControl: isControl,
                     didMerge: didMerge)
    }

    /// 返回矩形整体平移后的副本（菜单坐标校准用）。
    func shifted(dy: CGFloat) -> CapturedText {
        CapturedText(id: id, text: text, rect: rect.offsetBy(dx: 0, dy: dy),
                     source: source, displayText: displayText, isMenu: isMenu,
                     menuBarTitle: menuBarTitle, axRole: axRole, isControl: isControl,
                     didMerge: didMerge)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(Int(rect.origin.x.rounded()))
        hasher.combine(Int(rect.origin.y.rounded()))
        hasher.combine(Int(rect.width.rounded()))
        hasher.combine(Int(rect.height.rounded()))
    }

    static func == (lhs: CapturedText, rhs: CapturedText) -> Bool {
        lhs.text == rhs.text && lhs.rect == rhs.rect
    }
}
