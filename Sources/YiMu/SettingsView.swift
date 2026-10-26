import SwiftUI
import AppKit
import Combine

/// 设置页分区。
enum SettingsTab: String, CaseIterable {
    case general, appearance, excluded, hotkeys, about

    var title: String {
        switch self {
        case .general:    return L10n.s("翻译", "Translate")
        case .appearance: return L10n.s("外观", "Appearance")
        case .excluded:   return L10n.s("排除", "Exclusions")
        case .hotkeys:    return L10n.s("快捷键", "Hotkeys")
        case .about:      return L10n.s("关于", "About")
        }
    }

    var icon: String {
        switch self {
        case .general:    return "character.book.closed"
        case .appearance: return "paintbrush"
        case .excluded:   return "nosign"
        case .hotkeys:    return "keyboard"
        case .about:      return "info.circle"
        }
    }
}

/// 用于把「权限与数据」框第二行首按钮宽度对齐到第一行首按钮（让「查看引导」左缘对齐「打开屏幕录制设置」）。
private struct FirstColWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 设置窗口按钮样式：默认灰底黑字，鼠标悬停/按下时整块点亮成强调色底白字。
struct HoverFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverFillButton(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct HoverFillButton: View {
        let label: ButtonStyle.Configuration.Label
        let isPressed: Bool
        @State private var hover = false

    var body: some View {
            label
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .frame(minWidth: 96)
                .background(hover || isPressed
                            ? Color.accentColor
                            : Color(nsColor: .controlColor))
                .foregroundColor(hover || isPressed ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .animation(.easeOut(duration: 0.12), value: hover)
                .onHover { hover = $0 }
        }
    }
}

/// 设置态：侧栏分区 + 内容区。整体半透明毛玻璃；窗口可缩放，内容可滚动。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Preferences.shared

    @State private var tab: SettingsTab = .general
    @State private var axOK = false
    @State private var ocrOK = false
    @State private var testResult = ""
    @State private var testing = false
    @State private var permFirstColWidth: CGFloat = 0
    @StateObject private var recorder = HotkeyRecorder()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }
            // 2026-10-14：一次性提示为居中浮层（overlay），不占内容流布局位置。
            .overlay(alignment: .center) {
                if !prefs.gestureTipSeen {
                    gestureTipBanner
                        .padding(.horizontal, 28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 首次提示期间：透明整窗层接住任意点击即关闭（点任意位置都消失），
        // 关闭后该层移除、恢复正常交互（非模态，不再禁用界面）。
        .overlay {
            if !prefs.gestureTipSeen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { prefs.gestureTipSeen = true }
                    }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // 侧栏品牌图标（2026-10-14 换成 yi.png 的「译」字渐变图）：
                // yi.png 由 build-app.sh 拷入 bundle Resources；找不到时回退 app 图标。
                Image(nsImage: {
                    if let url = Bundle.main.url(forResource: "yi", withExtension: "png"),
                       let img = NSImage(contentsOf: url) {
                        return img
                    }
                    return NSApp.applicationIconImage
                }())
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text("译幕").font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            ForEach(SettingsTab.allCases, id: \.rawValue) { t in
                Button {
                    tab = t
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.icon).frame(width: 14)
                        Text(t.title).font(.system(size: 12))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab == t ? Color.primary.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Text(versionString)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .padding(.vertical, 14)
        .frame(width: 128)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - 首次启动一次性提示

    /// 设置页首次出现时提示「按住 Shift 看原文」；点界面任意处即关闭，写入 gestureTipSeen，永不再弹。
    private var gestureTipBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.point.up.left.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 26))
            Text(L10n.s("提示：按住 Shift，指针处显示原文",
                        "Tip: hold Shift to peek the original text at your pointer"))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))   // 实底：不再透出后面的文字
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:    generalSection
        case .appearance: appearanceSection
        case .excluded:   exclusionSection
        case .hotkeys:    hotkeySection
        case .about:      aboutSection
        }
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(v)"
    }

    // 翻译

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.s("翻译", "Translate"),
                          L10n.s("Apple 离线引擎 · 全部内容留在本机", "Apple on-device engine · nothing leaves your Mac")) {
                if model.paused {
                    Label(L10n.s("已暂停（菜单栏可恢复）", "Paused (resume from menu bar)"),
                          systemImage: "pause.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            GroupBox {
                // 2026-10-26：恢复为上下两行（源语言一行、目标语言一行）；
                // 标签不占固定宽（贴紧下拉）、下拉缩到 120 保持不变。
                VStack(alignment: .leading, spacing: 10) {
                    // 2026-10-26：两个标签固定等宽（保证两行下拉左缘对齐），
                    // 标签→下拉间距加大，下拉整体右移但仍保持两行一致间距。
                    HStack(spacing: 14) {
                        Text(L10n.s("源语言", "Source"))
                            .frame(width: 56, alignment: .leading)
                        Picker("", selection: $model.sourceLanguageCode) {
                            Text(L10n.s("自动识别", "Auto detect")).tag(nil as String?)
                            ForEach(LanguageOption.targetOptions) { opt in
                                Text(opt.displayName).tag(opt.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                        Spacer()
                    }
                    HStack(spacing: 14) {
                        Text(L10n.s("目标语言", "Target"))
                            .frame(width: 56, alignment: .leading)
                        Picker("", selection: $model.targetLanguageCode) {
                            ForEach(LanguageOption.targetOptions) { opt in
                                Text(opt.displayName).tag(opt.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                        Spacer()
                    }
                }
                .padding(10)
            }

            permissionSection
            engineSection

            HStack(spacing: 10) {
                Button(L10n.s("画框翻译", "Frame translation")) {
                    AppDelegate.shared?.applyState(.lens)
                }
                .buttonStyle(HoverFillButtonStyle())

                Button(L10n.s("屏幕融合", "Screen fusion")) {
                    AppDelegate.shared?.applyState(.fusion)
                }
                .buttonStyle(HoverFillButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.s("外观", "Appearance"),
                          L10n.s("译文块的呈现方式", "How translation blocks look"))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.s("界面语言", "Interface")).frame(width: 64, alignment: .leading)
                        Picker("", selection: $prefs.uiLanguage) {
                            Text("中文").tag("zh")
                            Text("English").tag("en")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 180)
                        Spacer()
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.s("译文字号", "Text size")).frame(width: 64, alignment: .leading)
                        Text(L10n.s("自动", "Auto"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(L10n.s("字号自动匹配原文行高：译文与原文同尺寸，遮挡范围只由原文长度决定，不会因字号变大而盖出原文之外。",
                                "Text size follows the original line height: the block stays as wide as the original text, never wider."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }
        }
    }

    // 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.s("关于译幕", "About"),
                          L10n.s("实时把屏幕上的外文变成你的语言", "See any app in your language, live"))

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(L10n.s("版本", "Version"), versionString)
                    Divider()
                    infoRow(L10n.s("引擎", "Engine"),
                            L10n.s("Apple 设备端", "Apple on-device"))
                    Divider()
                    infoRow(L10n.s("隐私", "Privacy"),
                            L10n.s("全本地处理，无任何上传", "Fully on-device, zero upload"))
                }
                .padding(10)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.s("权限与数据", "Permissions & data")).font(.system(size: 12, weight: .medium))
                    HStack(spacing: 8) {
                        Button(L10n.s("打开辅助功能设置", "Open Accessibility settings")) { openAccessibility() }
                            .controlSize(.small)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: FirstColWidthKey.self, value: proxy.size.width)
                            })
                        Button(L10n.s("打开屏幕录制设置", "Open Screen Recording settings")) { openScreenRecording() }
                            .controlSize(.small)
                        Spacer()
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button(L10n.s("清空翻译缓存", "Clear translation cache")) {
                            Translator.shared.clearCache()
                            CaptureEngine.shared.invalidateTranslations()
                        }
                        .controlSize(.small)
                        .frame(width: permFirstColWidth, alignment: .leading)
                        Button(L10n.s("查看引导", "Replay onboarding")) {
                            Preferences.shared.hasOnboarded = false
                            OnboardingWindowController.shared.show()
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .onPreferenceChange(FirstColWidthKey.self) { permFirstColWidth = $0 }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12))
            Spacer()
        }
    }

    private func sectionHeader<Trailing: View>(_ title: String, _ subtitle: String,
                                               @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 15, weight: .medium))
                trailing()
            }
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 权限 / 引擎

    @ViewBuilder
    private var engineSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.s("引擎状态", "Engine")).font(.system(size: 12, weight: .medium))
                // 2026-10-14：清空翻译缓存 / 测试翻译 / 测试结果 同一行（用户要求）
                HStack(spacing: 8) {
                    Button(L10n.s("清空翻译缓存", "Clear translation cache")) {
                        Translator.shared.clearCache()
                        CaptureEngine.shared.invalidateTranslations()
                    }
                    .controlSize(.small)
                    Button(testing ? L10n.s("测试中…", "Testing…") : L10n.s("测试翻译", "Test")) {
                        testing = true
                        Task {
                            let r = await Translator.shared.translate("Hello")
                            await MainActor.run {
                                testResult = r
                                testing = false
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(testing)
                    if !testResult.isEmpty {
                        Text("Hello → \(testResult)")
                            .font(.system(size: 11))
                            .foregroundStyle(testResult == "Hello" ? .orange : .green)
                    }
                    Spacer()
                }
                if testResult == "Hello" {
                    // 原文被原样返回 = 翻译失败回退：多为目标语言包未下载。
                    Text(L10n.s("译文等于原文，可能目标语言包未下载，请在系统「设置 ▸ 通用 ▸ 语言与地区 / 翻译」中下载目标语言离线包",
                                "Translation equals source — the offline language pack may not be downloaded yet. Get it in System Settings ▸ General ▸ Language & Region / Translate."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var permissionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(granted: axOK,
                              title: L10n.s("辅助功能", "Accessibility"),
                              hint: L10n.s("读取前台 app 文本（AX）", "Read text from the front app (AX)"),
                              open: openAccessibility)
                Divider()
                permissionRow(granted: ocrOK,
                              title: L10n.s("屏幕录制", "Screen Recording"),
                              hint: L10n.s("截图兜底识别（OCR）", "OCR fallback via screenshot"),
                              open: openScreenRecording)
            }
            .padding(10)
        }
    }

    private func permissionRow(granted: Bool, title: String, hint: String, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L10n.s("授权", "Grant")) { open() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 排除应用

    @ViewBuilder
    private var exclusionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.s("排除", "Exclusions"),
                          L10n.s("这些 app 在前台时完全不翻译；可点选某个窗口来排除它所属的 App",
                                 "Never translate while these apps are in front; pick a window to exclude its app"))

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.s("不翻译的应用", "Don't translate"))
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button(L10n.s("＋ 点选窗口", "Pick a window")) {
                            AppDelegate.shared?.startAppPicker()
                        }
                        .controlSize(.small)
                        Button(L10n.s("+ 当前前台 App", "+ Front app")) {
                            if let app = NSWorkspace.shared.frontmostApplication,
                               let id = app.bundleIdentifier,
                               !Preferences.shared.excludedBundleIDs.contains(id) {
                                Preferences.shared.excludedBundleIDs.append(id)
                            }
                        }
                        .controlSize(.small)
                    }
                    if prefs.excludedBundleIDs.isEmpty {
                        Text(L10n.s("暂无。加入后该 App 在前台时不会翻译（如 Xcode / 终端）。",
                                    "Empty. Added apps are skipped while in front (e.g. Xcode / Terminal)."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ForEach(prefs.excludedBundleIDs, id: \.self) { id in
                            HStack {
                                Text(id).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Button {
                                    Preferences.shared.excludedBundleIDs.removeAll { $0 == id }
                                } label: { Image(systemName: "minus.circle") }
                                    .controlSize(.small)
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: - 快捷键

    @ViewBuilder
    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.s("快捷键", "Hotkeys"),
                          L10n.s("点「录制」后按下新的组合键", "Hit Record, then press your combo"))

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    hotkeyRow(action: Hotkey.Action.showLens)
                    hotkeyRow(action: Hotkey.Action.toggleFusion)
                    hotkeyRow(action: Hotkey.Action.exitFusion)
                    hotkeyRow(action: Hotkey.Action.togglePause)
                    Divider()
                    Button(L10n.s("恢复默认", "Restore defaults")) { Preferences.shared.resetHotkeys() }
                        .controlSize(.small)
                }
                .padding(10)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.s("手势", "Gestures")).font(.system(size: 12, weight: .medium))
                    Text(L10n.s("按住 ⇧：指针处显示原文", "Hold ⇧: peek the original under your pointer"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        }
    }

    private func hotkeyRow(action: String) -> some View {
        HStack {
            Text(Hotkey.actionTitle(action, english: Preferences.shared.isEnglish))
                .font(.system(size: 12))
            Spacer()
            if recorder.recordingAction == action {
                Text(L10n.s("按下按键…", "Press a key…"))
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text(Preferences.shared.hotkeys[action]?.display ?? "—")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15)))
            }
            Button(recorder.recordingAction == action ? L10n.s("取消", "Cancel") : L10n.s("录制", "Record")) {
                if recorder.recordingAction == action {
                    recorder.end()
                } else {
                    recorder.begin(action: action) { hk in
                        Preferences.shared.hotkeys[action] = hk
                    }
                }
            }
            .controlSize(.small)
            Button(L10n.s("默认", "Default")) {
                if let d = Hotkey.defaults[action] { Preferences.shared.hotkeys[action] = d }
            }
            .controlSize(.small)
        }
    }

    // MARK: - 刷新与跳转

    private func refresh() {
        axOK = AXTextExtractor.shared.isTrusted
        ocrOK = OCRTextExtractor.shared.hasPermission
    }

    private func openAccessibility() {
        AXTextExtractor.shared.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func openScreenRecording() {
        OCRTextExtractor.shared.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
