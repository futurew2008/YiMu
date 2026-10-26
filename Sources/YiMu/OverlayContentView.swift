import SwiftUI

/// 根内容视图：根据 AppModel.state 在三态之间切换。
struct OverlayContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            switch model.state {
            case .settings: SettingsView()
            case .lens:     LensView()
            case .fusion:   FusionView()
            case .region:   Color.clear
            case .off:      Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
