#!/usr/bin/env bash
# 把 duo-paste 装成 LaunchAgent：开机自启 + 崩溃自动重启 + 日志重定向。
# 幂等：重复运行会先 bootout 再重新 bootstrap。
#
# 签名策略:Developer ID Application + hardened runtime,装成 .app bundle。
# 这样 macOS TCC 按 Team ID + Bundle ID 判 Accessibility 权限保留——cdhash 变了
# 但 Designated Requirement 不变,权限跟 app 走,重装不要求重新授权。adhoc 签名
# 时代每次 install 都让 Accessibility 列表里旧 cdhash 失效,体验极差
set -euo pipefail

LABEL="io.duopaste.agent"
BUNDLE_ID="io.duopaste.daemon"
BUNDLE_NAME="DuoPaste"
APP="$HOME/Applications/$BUNDLE_NAME.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/duo-paste"
SIGN_IDENTITY="Developer ID Application: BO LI (RS59HDH7Y3)"
LEGACY_INSTALL_DIR="$HOME/Applications/duo-paste"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 构建 release"
cd "$REPO_ROOT"
swift build -c release

BINARY="$REPO_ROOT/.build/release/duo-pasted"
if [[ ! -x "$BINARY" ]]; then
    echo "构建产物不存在: $BINARY" >&2
    exit 1
fi

echo "==> 组装 .app bundle: $APP"
# rm -rf 整个 bundle 后重建,避免旧 Resources / 旧签名残留
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$LOG_DIR"
cp "$BINARY" "$APP/Contents/MacOS/duo-pasted"
chmod +x "$APP/Contents/MacOS/duo-pasted"

# LSUIElement=true 让 macOS 把这个 bundle 当 accessory app 处理:不显 Dock 图标,
# 不抢 NSApp 主菜单。daemon 本来就走 SwiftUI accessory 模式
cat >"$APP/Contents/Info.plist" <<INFO_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>duo-pasted</string>
    <key>CFBundleName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$BUNDLE_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
INFO_EOF

# --options runtime:开 hardened runtime。CGEvent / NSPasteboard / GRDB sqlite /
# HummingbirdTLS 都在 hardened runtime 下 OK,不需要额外 entitlements。
# --force:覆盖之前签名(install 重跑时旧签名失效)。
# 不加 --timestamp:本机自用不 notarize,timestamp 服务连 Apple 慢且非必需
echo "==> 签名 bundle (Developer ID Application + hardened runtime)"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

echo "==> 验证签名"
codesign --verify --strict --verbose=2 "$APP"
# 打印 Bundle ID + Team ID + Authority 让用户日后排查 TCC 问题
codesign -dvv "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -10 || true

if [[ -d "$LEGACY_INSTALL_DIR" ]]; then
    echo "==> 清理旧 adhoc 路径: $LEGACY_INSTALL_DIR"
    rm -rf "$LEGACY_INSTALL_DIR"
fi

echo "==> 写 LaunchAgent plist: $PLIST"
mkdir -p "$(dirname "$PLIST")"
cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>Program</key>
    <string>$APP/Contents/MacOS/duo-pasted</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/duo-pasted.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/duo-pasted.err.log</string>
</dict>
</plist>
PLIST_EOF

echo "==> 重载 launchd 服务"
# 已加载过先卸掉(同 Label 不同 Program 路径切换的场景),避免 "service already
# bootstrapped" 报错
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "==> 状态"
launchctl print "gui/$UID/$LABEL" | head -20 || true

echo
echo "完成。"
echo "  bundle:  $APP"
echo "  plist:   $PLIST"
echo "  日志:    $LOG_DIR/"
echo
echo "提示:首次切到 Developer ID 签名,Accessibility 权限需要重新勾一次。"
echo "之后所有 install-agent.sh 重装都会保留权限(Team ID + Bundle ID 不变)。"
echo
echo "可以按 ⌥⌘V 试一下;日常更新代码后重跑这个脚本即可。"
