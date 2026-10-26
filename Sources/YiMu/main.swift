import AppKit

// 入口：手工启动 NSApplication，使用 accessory 激活策略（不占 Dock，作为悬浮/菜单栏 App）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
