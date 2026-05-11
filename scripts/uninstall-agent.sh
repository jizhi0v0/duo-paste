#!/usr/bin/env bash
# 拆 duo-paste LaunchAgent。不动数据目录（~/Library/Application Support/duo-paste/）。
set -euo pipefail

LABEL="io.duopaste.agent"
INSTALL_DIR="$HOME/Applications/duo-paste"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 停止并卸载服务"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

echo "==> 删除 plist"
rm -f "$PLIST"

echo "==> 删除二进制"
rm -rf "$INSTALL_DIR"

echo
echo "完成。数据目录保留在 ~/Library/Application\ Support/duo-paste/，需要可手动 rm -rf。"
echo "日志在 ~/Library/Logs/duo-paste/，同样不动。"
