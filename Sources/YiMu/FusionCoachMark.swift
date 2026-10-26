import AppKit
import SwiftUI
import CoreGraphics

/// 首次进入「屏幕融合」态时，一次性浮出的轻量交互引导卡。
///
/// 设计取舍（ADA 级克制）：
/// - 只出现一次，看完即走，绝不重复打扰；
/// - 非交互（`ignoresMouseEvents = true`），6 秒自动淡出，绝不挡住下层 app 的操作；
/// - 位置固定在主屏顶部居中，与右下角的 HUD 形成「上教手势 / 下给出口」的平衡；
/// - 入场带轻微下滑动 + 淡入，尊重系统「减弱动态效果」开关。
final class FusionCoachMark {
    static let shared = FusionCoachMark()

    private var window: NSWindow?
    private var timer: Timer?

    /// 首次进入融合态时调用一次；已看过则什么都不做。
    func showIfNeeded(on screen: NSScreen) {
        guard !Preferences.shared.hasSeenFusionTip else { return }
        Preferences.shared.hasSeenFusionTip = true
        show(on: screen)
    }

    private func show(on screen: NSScreen) {
        let size = NSSize(width: 360, height: 172)
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - size.height - 96
        )
        let win = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.isReleasedWhenClosed = false   // ARC：防止 close() 过度释放（闪退根因）
        // 高于融合覆盖窗口与 HUD，确保浮在最上
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.ignoresMouseEvents = true       // 纯信息卡，不拦截下层点击
        win.contentView = CoachCardView()
        win.alphaValue = 0
        win.orderFront(nil)
        self.window = win

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce {
            win.alphaValue = 1
        } else {
            // 轻微下滑动（起手高 8pt → 落定）+ 淡入，比纯淡入更有"落定"的层次感
            let cv = win.contentView
            cv?.wantsLayer = true
            if let layer = cv?.layer {
                layer.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.32)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                win.animator().alphaValue = 1
                layer.setAffineTransform(.identity)
                CATransaction.commit()
            } else {
                win.animator().alphaValue = 1
            }
        }

        // 6 秒后自动消隐
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        timer?.invalidate(); timer = nil
        guard let win = window else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce {
            win.close(); window = nil
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                win.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                win.close(); self?.window = nil
            })
        }
    }
}

/// 引导卡本体：磨砂玻璃胶囊，承载 SwiftUI 排版的内容。
private final class CoachCardView: NSVisualEffectView {
    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 360, height: 172))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: 6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        self.shadow = shadow

        let hosting = NSHostingView(rootView: CoachTipView())
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 172)
        addSubview(hosting)
    }
}

/// 引导卡内容（SwiftUI 排版，保证中英文字距与层级的精致度）。
private struct CoachTipView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(L10n.s("屏幕融合已开启", "Fusion is on"))
                    .font(.headline)
                Spacer()
            }
            tipRow(symbol: "shift",
                   text: L10n.s("按住 ⇧ Shift，临时查看原文",
                                "Hold ⇧ Shift to peek the original"))
            tipRow(symbol: "arrow.down.right",
                   text: L10n.s("鼠标移到右下角，暂停 / 退出",
                                "Move to bottom-right to pause / exit"))
            Spacer(minLength: 0)
            Text(L10n.s("此提示仅出现一次", "This tip shows only once"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 360, height: 172)
    }

    private func tipRow(symbol: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
            Spacer()
        }
    }
}
