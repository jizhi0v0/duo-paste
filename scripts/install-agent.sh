#!/usr/bin/env bash
# 把 duo-paste 装成 LaunchAgent：开机自启 + 崩溃自动重启 + 日志重定向。
# 幂等：重复运行会先 bootout 再重新 bootstrap。
set -euo pipefail

LABEL="io.duopaste.agent"
INSTALL_DIR="$HOME/Applications/duo-paste"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/duo-paste"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 构建 release"
cd "$REPO_ROOT"
swift build -c release

BINARY="$REPO_ROOT/.build/release/duo-pasted"
if [[ ! -x "$BINARY" ]]; then
    echo "构建产物不存在: $BINARY" >&2
    exit 1
fi

echo "==> 安装二进制到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
cp "$BINARY" "$INSTALL_DIR/duo-pasted"
chmod +x "$INSTALL_DIR/duo-pasted"

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
    <string>$INSTALL_DIR/duo-pasted</string>
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
# 如果已加载过先卸掉，避免 "service already bootstrapped" 报错
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"
launchctl kickstart -k "gui/$UID/$LABEL"

echo "==> 状态"
launchctl print "gui/$UID/$LABEL" | head -20 || true

echo
echo "完成。"
echo "  二进制: $INSTALL_DIR/duo-pasted"
echo "  plist:  $PLIST"
echo "  日志:   $LOG_DIR/"
echo
echo "可以按 ⌥⌘V 试一下；日常更新代码后重跑这个脚本即可。"
