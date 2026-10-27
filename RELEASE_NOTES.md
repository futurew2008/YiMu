# 译幕 YiMu 1.0 · Release Notes

首个正式版。这是一个完全在你的 Mac 上运行的实时翻译浮层——透明、常驻顶层、鼠标穿透，
把屏幕上的外文原文用译文遮挡块当场替换，像系统菜单一样无声地叠在原处。

**发布日期**：2026-10-27　**Bundle ID**：`com.weilai.yimu`　**签名**：Developer ID Application（Team ID `S736GRAMX5`）

---

## 下载与安装

- **系统要求**：macOS 15（Sequoia）或更高，Apple 芯片 / Intel 均可。
- 下载 [`YiMu.dmg`](https://github.com/futurew2008/YiMu/releases/download/v1.0/YiMu.dmg)（3,237,969 字节），双击后把「译幕」拖进「应用程序」。
- 首次打开：已签名 + 苹果公证 + 票据钉入，正常情况下直接双击即可运行，不会出现"无法验证开发者"。
- 首次启用翻译时，按提示到 **系统设置 → 隐私与安全性** 授予「辅助功能」与「屏幕录制」两项权限，重启译幕。

**为什么不在 Mac App Store**：译幕依赖辅助功能 API 与屏幕捕获，而 App Store 强制的 App Sandbox
在禁用清单第一条就禁止这两者。这是苹果对所有"读取他窗内容"类工具的统一限制。
因此译幕走 **Developer ID 签名 + 苹果公证** 的官方合规分发方式，功能零改动。

### 校验下载（可选但推荐）

```bash
# 确认签名有效
codesign -dvv /Applications/译幕.app 2>&1 | grep -E "Authority|TeamIdentifier"
# 确认通过了苹果公证（Gatekeeper 评估）
spctl -a -vv /Applications/译幕.app
# 比对校验和
shasum -a 256 YiMu.dmg
```

本版 `YiMu.dmg` 的 SHA-256 应为：

```
08569d7a9eb86682a7ee275172748a65d0267c0ff783913fdf80fb14c08c8b59
```

`shasum -a 256 YiMu.dmg` 的输出必须与上面**逐字符一致**，不一致说明下载被篡改或损坏，请重新下载。

---

## 本版本的主要变化

### 界面 · 交互

- **窗口左上角四个按钮合为一组**：关闭 / 最小化 / **画框最大化** / **屏幕融合**。
  四个按钮同尺寸（14pt）、同间距（20pt），鼠标移到其中任意一个，**四个符号一起出现、一起消失**。
- **画框最大化**：原来第三个按钮是系统"缩放"，现在改为**一键启用画框翻译并把框铺满整屏**。
- 第四个按钮的符号定为「两个等腰直角三角形」向两端张开，深蓝配色，外加深色细环。
- 设置页源语言 / 目标语言恢复为上下两行，标签等宽对齐。

### 翻译质量

- **重复文本不再漏翻**：屏幕上有几个相同的词，就盖几个译文块。此前同批次内的重复文本会被去重跳过
  （导致"A 处翻了、B 处没翻，用户根本找不到那个词"），已修复。
- 连带修复：切换语言后译文残留旧语言、缓存 key 方向错误、语言包未下载时的误告警。

### 性能

- 画框 / 区域态 OCR 帧率 **3fps → 6fps**，拖动窗口、滚动页面时译文明显更跟手。
  融合态维持 3fps 以省 CPU。

### 隐私

- **彻底移除可选的云端翻译引擎**（相关设置项、代码、凭据存储一并删除）。
  译幕现在是百分百 Apple 设备端翻译：**零联网、零上传、零遥测**。断网使用功能完全正常。

---

## English summary

YiMu 1.0 — first stable release. A fully on-device, real-time translation overlay for macOS:
transparent, always-on-top, click-through. It reads what's on screen and covers the original text
with translated blocks in place, like a system menu.

- **Unified 4-button titlebar cluster** (close / minimize / **Frame Maximize** / Fusion) — all 4 symbols
  reveal together on hover; `+` now means "start frame translation and fill the screen".
- **Fix: repeated text is no longer skipped** — every occurrence on screen gets its own translated block.
- **Frame/region OCR 3fps → 6fps**, so translations keep up when you drag or scroll.
- **Cloud translation engine removed** — 100% Apple on-device translation, zero network, zero telemetry.

**Requires macOS 15+.** Distributed outside the Mac App Store (Developer ID + Apple notarization)
because Accessibility APIs and Screen Recording are incompatible with the App Store sandbox.

---

## 隐私承诺

译幕不联网、不收集、不上传你的任何数据：

- 翻译走 Apple 原生 `Translation` 框架，源码中无任何 `URLSession` / HTTP / 第三方 API 调用。
- 屏幕内容只在本机处理，处理完即弃，不留明文。
- 磁盘缓存只存**原文的 SHA-256 哈希 + 译文**，不存原文。

完整说明见 [PRIVACY.md](./PRIVACY.md)。
