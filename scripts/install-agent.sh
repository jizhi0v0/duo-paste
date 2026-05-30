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

# ── Sparkle 自动更新（方案 A：KeepAlive daemon 自控 relaunch）─────────────────
# feed 走公开 release 仓的 raw appcast；公钥是 duo-paste 专属 EdDSA（generate_keys
# --account duopaste 生成，私钥在本机 login keychain，CI 用 -x 导成 secret）。
# DP_NO_SPARKLE=1 → 纯本地构建不嵌 Sparkle / 不写 SU 键（开发自测时不想被自动更新顶掉）。
SU_FEED_URL="https://raw.githubusercontent.com/jizhi0v0/duo-paste-releases/main/appcast.xml"
SU_PUBLIC_ED_KEY="5Ws5rSunj3IH4UiP8aN8YFtDni4inudOxMLTgmzhr1s="
EMBED_SPARKLE=1
[[ "${DP_NO_SPARKLE:-0}" == "1" ]] && EMBED_SPARKLE=0

# 版本号：build 号 = git commit count + 1000 offset（与 .github CI / claude-usage
# deploy.sh 同口径），让本地装的版本跟 appcast 上的 release build 单调对齐——Sparkle
# 按 CFBundleVersion 比较不会误判「本地比 release 旧/新」。short version 派生自 build。
BUILD_OFFSET=1000
BUILD_NUMBER=$(( $(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0) + BUILD_OFFSET ))
SHORT_VERSION="0.1.${BUILD_NUMBER}"

echo "==> 构建 release"
cd "$REPO_ROOT"
swift build -c release

BINARY="$REPO_ROOT/.build/release/duo-pasted"
if [[ ! -x "$BINARY" ]]; then
    echo "构建产物不存在: $BINARY" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

# 组 bundle + 嵌 Sparkle + 深签 → 抽到 assemble-bundle.sh（release.yml CI 也调它，单一真相，
# 避免组 bundle / 深签顺序两处漂移）。本机自用不 notarize（不设 DP_TIMESTAMP）。
# DP_NO_SPARKLE=1 时 SPARKLE_FW_ARG 传空 → 不嵌 Sparkle、不写 SU 键。
SPARKLE_FW_ARG=""
if [[ "$EMBED_SPARKLE" == "1" ]]; then
    SPARKLE_FW_ARG="$REPO_ROOT/.build/release/Sparkle.framework"
    if [[ ! -d "$SPARKLE_FW_ARG" ]]; then
        echo "Sparkle.framework 不存在: $SPARKLE_FW_ARG（swift build 没产出？）" >&2
        exit 1
    fi
fi
DP_APP="$APP" \
DP_BINARY="$BINARY" \
DP_BUNDLE_ID="$BUNDLE_ID" \
DP_BUNDLE_NAME="$BUNDLE_NAME" \
DP_SHORT_VERSION="$SHORT_VERSION" \
DP_BUILD_NUMBER="$BUILD_NUMBER" \
DP_SIGN_IDENTITY="$SIGN_IDENTITY" \
DP_SPARKLE_FW="$SPARKLE_FW_ARG" \
DP_SU_FEED_URL="$SU_FEED_URL" \
DP_SU_PUBLIC_ED_KEY="$SU_PUBLIC_ED_KEY" \
    bash "$REPO_ROOT/scripts/assemble-bundle.sh"

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
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
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
