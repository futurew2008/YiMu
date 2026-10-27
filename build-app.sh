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

# Info.plist 里的两个 TCC 说明字符串是**外发硬前提**，勿删：
#   NSScreenCaptureUsageDescription —— app 调用了 CGRequestScreenCaptureAccess / ScreenCaptureKit，
#     缺这个 key 系统不但不弹授权框，还会直接把 app 终止（terminated）。
#   NSAppleEventsUsageDescription —— 辅助功能读取他窗文字，「想要控制」类提示会显示这段用途说明。
# 版本号：CFBundleShortVersionString（对外 1.0）/ CFBundleVersion（build 号），发布前在此定稿。
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>译幕</string>
<key>CFBundleDisplayName</key><string>译幕</string>
<key>CFBundleIdentifier</key><string>com.weilai.yimu</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleExecutable</key><string>YiMu</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSScreenCaptureUsageDescription</key><string>译幕需要「屏幕录制」权限来读取屏幕上的文字，以便识别并翻译。画面仅在本机处理，不会上传任何内容。</string>
<key>NSAppleEventsUsageDescription</key><string>译幕使用「辅助功能」读取其他 App 界面上的文字用于翻译，全程在你的 Mac 上完成。</string>
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
#   B. 三选一设置 notarytool 凭据（凭据全部走环境变量或钥匙串，绝不写进脚本 / 仓库）：
#        · 钥匙串配置（最省事，密码不进历史）：先执行一次
#             xcrun notarytool store-credentials "yimu" --apple-id 你的AppleID --team-id S736GRAMX5
#           之后每次只需：export NOTARY_PROFILE=yimu
#        · App 专用密码：export APPLE_ID=你的AppleID   （密码留空，脚本会交互式提示输入）
#        · API 密钥：    export APPLE_API_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
#                        export APPLE_API_KEY_ID=XXXXXXXXXX        # 必填，Key ID
#                        export APPLE_API_ISSUER=xxxxxxxx-xxxx-... # 团队密钥（Team Key）才需要
#   C. TEAM_ID 默认 S736GRAMX5，可用环境变量覆盖。
#
# 用法：NOTARIZE=1 ./build-app.sh
# ============================================================================
if [ "${NOTARIZE:-0}" = "1" ]; then
  TEAM_ID="${TEAM_ID:-S736GRAMX5}"
  # 允许在 APPLE_API_KEY 里写 ~/xxx（双引号不会展开波浪号，这里手动展开）。
  APPLE_API_KEY="${APPLE_API_KEY/#\~/$HOME}"
  if [ -z "$APPLE_ID" ] && [ -z "$APPLE_API_KEY" ] && [ -z "$NOTARY_PROFILE" ]; then
    echo "⚠️ NOTARIZE=1 但未设置 APPLE_ID / APPLE_API_KEY，跳过公证。"
    echo "   请按本脚本顶部说明配置 notarytool 凭据后再试。"
  elif [ -n "$APPLE_API_KEY" ] && { [ -z "$APPLE_API_KEY_ID" ] || [ ! -f "$APPLE_API_KEY" ]; }; then
    # API 密钥路径缺 --key-id 认证必失败；文件不存在也别白跑一遍构建。
    echo "❌ API 密钥凭据不完整："
    [ -f "$APPLE_API_KEY" ] || echo "   · 找不到 .p8 文件：$APPLE_API_KEY"
    [ -n "$APPLE_API_KEY_ID" ] || echo "   · 未设置 APPLE_API_KEY_ID（Key ID，10 位左右）"
    echo "   正确写法：export APPLE_API_KEY=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8"
    echo "             export APPLE_API_KEY_ID=XXXX  [export APPLE_API_ISSUER=团队IssuerID]"
    exit 1
  else
    # 用 Apple ID 认证但没给密码时，改为运行时交互输入（不回显、不进 shell 历史、不落环境变量）。
    if [ -z "$APPLE_API_KEY" ] && [ -z "$APPLE_APP_PASSWORD" ] && [ -z "$NOTARY_PROFILE" ]; then
      printf "▶ 请输入 App 专用密码（输入不回显，不会写入历史）："
      # read 在 EOF / Ctrl-D 时返回非零，配合 set -e 会直接杀脚本，必须忽略其退出码。
      read -r -s APPLE_APP_PASSWORD || true
      echo
      if [ -z "$APPLE_APP_PASSWORD" ]; then
        echo "❌ 未输入密码，已取消。"
        exit 1
      fi
    fi
    DMG="build/YiMu.dmg"
    echo "▶ 打包 dmg…"
    hdiutil create -volname "译幕 YiMu" -srcfolder "$APP" -ov -format UDZO "$DMG"
    # dmg 容器本身也必须用 Developer ID 签名：
    # 用户下载的 dmg 带隔离属性，双击挂载时 Gatekeeper 判定的是 dmg 容器而不是里面的 app，
    # 未签名的 dmg 会得到 "no usable signature" 而被拦（内含 app 已公证也没用）。
    if [ -n "$IDENTITY" ]; then
      echo "▶ 签名 dmg 容器…"
      codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    else
      echo "⚠️ 无签名身份，跳过 dmg 签名（Gatekeeper 可能在挂载这一步拦截）。"
    fi
    echo "▶ 提交公证（notarytool，可能需等待数十秒到几分钟）…"
    if [ -n "$NOTARY_PROFILE" ]; then
      # 凭据事先由 `xcrun notarytool store-credentials` 存入钥匙串，这里只按名字引用。
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [ -n "$APPLE_API_KEY" ]; then
      # Team Key 需要 --issuer；Individual Key 则必须不传 --issuer，故按是否设置动态拼参数。
      ISSUER_ARGS=()
      if [ -n "$APPLE_API_ISSUER" ]; then
        ISSUER_ARGS=(--issuer "$APPLE_API_ISSUER")
      fi
      xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" "${ISSUER_ARGS[@]}" --wait
    else
      xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID" --wait
    fi
    echo "▶ 钉入公证票据（stapler）——之后用户打开无需再向苹果请求校验："
    xcrun stapler staple "$DMG"
    echo "✅ 已生成公证版 $DMG"
    echo "   发布：把 $DMG 传 GitHub Releases 或你的站点即可。"
  fi
fi
