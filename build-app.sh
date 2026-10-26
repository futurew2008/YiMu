#!/usr/bin/env bash
# 把译幕(YiMu)打包成可被 TCC 稳定识别的 .app，避免 Xcode ⌘R 的命令行二进制
# 在「屏幕录制 / 辅助功能」授权上身份不稳定、授权收不到的问题。
set -e
cd "$(dirname "$0")"

echo "▶ 构建 release 二进制…"
swift build -c release --disable-sandbox
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/YiMu"

APP="build/YiMu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/YiMu"

# App 图标（2026-10-14 接入）：源图 icon.png 四周白边已抠成透明（圆角 r=160，实测值），
# 由 iconutil 打成 AppIcon.icns（含 16~1024 全套 10 个尺寸）。
if [ -f "AppIcon.icns" ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "⚠️ 未找到 AppIcon.icns，本次打包不含图标。"
fi

# 设置侧栏品牌图标 yi.png（2026-10-14 接入，SettingsView 从 bundle 读取）
if [ -f "yi.png" ]; then
  cp yi.png "$APP/Contents/Resources/yi.png"
else
  echo "⚠️ 未找到 yi.png，设置侧栏图标将回退为 app 图标。"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>译幕</string>
<key>CFBundleDisplayName</key><string>译幕</string>
<key>CFBundleIdentifier</key><string>com.weilai.yimu</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleExecutable</key><string>YiMu</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF

# 优先用开发者证书签名：TCC（屏幕录制 / 辅助功能）授权是按「代码签名身份」绑定的，
# ad-hoc 签名每次重打包身份都变，会导致已授予的屏幕录制权限失效、OCR 整链静默退出。
# 用稳定的开发者证书签名后，授权在重打包后依然有效。
#
# 身份选择（优先级从高到低）：
#   1. 环境变量 SIGN_IDENTITY 强制指定，例如：
#        SIGN_IDENTITY="Developer ID Application: lai wei (S736GRAMX5)" ./build-app.sh
#   2. NOTARIZE=1 时强制挑选「Developer ID Application」（公证硬性要求），找不到直接报错退出。
#   3. 否则自动挑选钥匙串里已有的 Developer ID Application / Apple Development（优先 Developer ID）。
if [ -n "$SIGN_IDENTITY" ]; then
  IDENTITY="$SIGN_IDENTITY"
elif [ "${NOTARIZE:-0}" = "1" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -E "Developer ID Application" \
              | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*[0-9A-Fa-f]*[[:space:]]*"([^"]+)".*$/\1/')
  if [ -z "$IDENTITY" ]; then
    echo "❌ NOTARIZE=1 但未在钥匙串找到「Developer ID Application」证书，无法公证。"
    echo "   请先在 developer.apple.com 申请并安装该证书，或显式设置 SIGN_IDENTITY。"
    exit 1
  fi
else
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -E "Developer ID Application|Apple Development" \
              | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*[0-9A-Fa-f]*[[:space:]]*"([^"]+)".*$/\1/')
fi

# Hardened Runtime 由 --options runtime 启用（公证必备）；entitlements 仅声明「非沙箱」。
ENTITLEMENTS="$(pwd)/YiMu.entitlements"
if [ -n "$IDENTITY" ]; then
  echo "▶ 使用证书签名（Hardened Runtime）：$IDENTITY"
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  echo "⚠️ 未找到开发者证书，回退 ad-hoc 签名（Hardened Runtime 仍启用）。"
  echo "   这会导致屏幕录制授权在重打包后失效，仅适合本地调试。请在钥匙串安装开发者证书后重试。"
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi

echo "✅ 已生成 $APP"
echo "运行方式（不要从 Xcode ⌘R）："
echo "  open \"$(pwd)/build/YiMu.app\""

# ============================================================================
# 公证 + 打包 dmg（可选，仅「发布」时开启）
# ----------------------------------------------------------------------------
# 为什么需要：从 GitHub / 自有站点直分的 app 必须经苹果公证（Notarization），
# 否则用户双击打开会弹「无法验证开发者」。功能代码一行都不用改。
#
# 前置（凭据全部走环境变量，绝不写进脚本 / 仓库，守住私钥红线）：
#   A. Developer ID Application 证书：在 developer.apple.com 申请并装进钥匙串。
#   B. 二选一设置 notarytool 凭据：
#        · app 专用密码：export APPLE_ID=你的AppleID  APPLE_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
#        · API 密钥：     export APPLE_API_KEY=/绝对路径/AuthKey_XXXX.p8  APPLE_API_ISSUER=发行商ID
#   C. TEAM_ID 默认 S736GRAMX5，可用环境变量覆盖。
#
# 用法：NOTARIZE=1 ./build-app.sh
# ============================================================================
if [ "${NOTARIZE:-0}" = "1" ]; then
  TEAM_ID="${TEAM_ID:-S736GRAMX5}"
  if [ -z "$APPLE_ID" ] && [ -z "$APPLE_API_KEY" ]; then
    echo "⚠️ NOTARIZE=1 但未设置 APPLE_ID / APPLE_API_KEY，跳过公证。"
    echo "   请按本脚本顶部说明配置 notarytool 凭据后再试。"
  else
    DMG="build/YiMu.dmg"
    echo "▶ 打包 dmg…"
    hdiutil create -volname "译幕 YiMu" -srcfolder "$APP" -ov -format UDZO "$DMG"
    echo "▶ 提交公证（notarytool，可能需等待数十秒到几分钟）…"
    if [ -n "$APPLE_API_KEY" ]; then
      xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY" --issuer "$APPLE_API_ISSUER" --team-id "$TEAM_ID" --wait
    else
      xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID" --wait
    fi
    echo "▶ 钉入公证票据（stapler）——之后用户打开无需再向苹果请求校验："
    xcrun stapler staple "$DMG"
    echo "✅ 已生成公证版 $DMG"
    echo "   发布：把 $DMG 传 GitHub Releases 或你的站点即可。"
  fi
fi
