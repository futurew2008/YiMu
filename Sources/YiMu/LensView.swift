import SwiftUI

/// 镜头态（透明）：窗口内容变透明成「镜头」，只翻译窗口罩住的区域。
/// 真实译文由 TranslationOverlayView 在对应坐标绘制；此处仅保留镜头边框与一次性提示。
/// 内容区点击穿透（容器 hitTest 控制），左上角蓝点按钮切换到融合态。
/// 注意：镜头态下 hosting 整体 isHidden=true（AppDelegate 切态逻辑），本视图实际不渲染；
/// 可见chrome（白描边/控制栏/四角弧光）均由 AppDelegate 的 AppKit 图层绘制。
struct LensView: View {
    /// 提示条只出现 3 秒后淡出：常驻文字会挡住被翻译的内容。
    @State private var showHint = true

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // 透明细框示意「镜头」范围（可被拖动窗口的标题栏移动）
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .padding(6)

                if showHint {
                    Text(L10n.s("画框模式 · 拖动标题栏移动 · 点左上角蓝点全屏",
                                "Frame · drag the title bar · tap the blue dot for full screen"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .position(x: 230, y: 30)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation(.easeOut(duration: 0.4)) { showHint = false }
            }
        }
    }
}
