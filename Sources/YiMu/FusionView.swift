import SwiftUI

/// 融合态（全屏）：窗口 chrome 隐藏、定位到整屏、罩住整个桌面（含菜单栏）。
/// 真实译文由 TranslationOverlayView 在对应坐标绘制；此处保持完全透明。
struct FusionView: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
