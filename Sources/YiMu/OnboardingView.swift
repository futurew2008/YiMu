import SwiftUI
import AppKit
import Combine

/// 首次启动引导：3 步讲清"为什么需要两项系统授权 + 一键跳转设置"，
/// 消灭"点了没反应"的挫败感。完成后写入 Preferences.hasOnboarded 并关闭窗口。
struct OnboardingView: View {
    var onFinish: () -> Void = {}

    @State private var step = 0
    @State private var axOK = false
    @State private var scrOK = false
    private let timer = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    private let totalSteps = 3

    var body: some View {
        VStack(spacing: 22) {
            // 顶部标题
            VStack(spacing: 4) {
                Text(L10n.s("欢迎使用译幕", "Welcome to Transcreen"))
                    .font(.title).fontWeight(.semibold)
                Text(L10n.s("把屏幕上的任意外文，实时翻译成你的语言",
                            "Translate any on-screen text into your language, in real time"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 步骤内容
            GroupBox {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .frame(height: 196)

            // 步骤指示
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            // 底部按钮
            HStack {
                if step > 0 {
                    Button(L10n.s("上一步", "Back")) { step -= 1 }
                }
                Spacer()
                if step < totalSteps - 1 {
                    Button(L10n.s("下一步", "Next")) { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L10n.s("开始使用", "Get Started")) { finish() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 540, height: 420)
        .onReceive(timer) { _ in
            axOK = AXTextExtractor.shared.isTrusted
            scrOK = OCRTextExtractor.shared.hasPermission
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.s("它能做什么", "What it does"))
                    .font(.headline)
                Text(L10n.s("译幕是一层透明的实时翻译浮层，罩在屏幕最上层、鼠标可穿透。它能识别窗口里的外文（菜单、按钮、正文），并在原词位置直接给出译文。",
                            "Transcreen is a transparent, click-through translation layer on top of everything. It reads on-screen text and shows the translation right where the original sits."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case 1:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.s("① 辅助功能权限", "① Accessibility"))
                    .font(.headline)
                Text(L10n.s("用于读取前台 App 的文本内容（菜单、按钮）。这是本地操作，不会上传任何数据。",
                            "Lets Transcreen read text from the front app (menus, buttons). Fully on-device — nothing leaves your Mac."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Image(systemName: axOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(axOK ? .green : .orange)
                    Text(axOK ? L10n.s("已授权", "Granted") : L10n.s("未授权", "Not granted"))
                        .font(.callout)
                    Spacer()
                    Button(axOK ? L10n.s("已授权", "Granted") : L10n.s("去授权", "Grant")) {
                        AXTextExtractor.shared.requestAccessibility()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    .disabled(axOK)
                    .controlSize(.small)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.s("② 屏幕录制权限", "② Screen Recording"))
                    .font(.headline)
                Text(L10n.s("当某些 App（游戏、自绘界面）读不到文本时，用截屏 OCR 兜底识别。授权后请务必退出译幕重开一次。",
                            "Used as a fallback (OCR) for apps we can't read directly. After granting, quit and relaunch Transcreen once."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Image(systemName: scrOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(scrOK ? .green : .orange)
                    Text(scrOK ? L10n.s("已授权", "Granted") : L10n.s("未授权", "Not granted"))
                        .font(.callout)
                    Spacer()
                    Button(scrOK ? L10n.s("已授权", "Granted") : L10n.s("去授权", "Grant")) {
                        OCRTextExtractor.shared.requestPermission()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                    .disabled(scrOK)
                    .controlSize(.small)
                }
            }
        }
    }

    private func finish() {
        Preferences.shared.hasOnboarded = true
        onFinish()
    }
}

/// 引导窗口控制器：首次启动弹出；用户点"开始使用"后写标记并关闭。
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func showIfNeeded() {
        guard !Preferences.shared.hasOnboarded else { return }
        show()
    }

    func show() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.s("译幕 · 引导", "Transcreen · Setup")
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false   // ARC：防止 close() 过度释放（闪退根因）
        let hosting = NSHostingView(rootView: OnboardingView(onFinish: { [weak win] in
            win?.close()
            self.window = nil
        }))
        win.contentView = hosting
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}
