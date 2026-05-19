#!/usr/bin/env bash
# 拆 duo-paste LaunchAgent。不动数据目录（~/Library/Application Support/duo-paste/）。
set -euo pipefail

LABEL="io.duopaste.agent"
APP="$HOME/Applications/DuoPaste.app"
LEGACY_INSTALL_DIR="$HOME/Applications/duo-paste"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 停止并卸载服务"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

echo "==> 删除 plist"
rm -f "$PLIST"

echo "==> 删除 bundle"
rm -rf "$APP"

# 老路径(adhoc 时代的单二进制安装),从 Developer ID bundle 切过来后理论上已被
# install-agent.sh 清掉。这里兜底,避免老用户卸载残留
if [[ -d "$LEGACY_INSTALL_DIR" ]]; then
    echo "==> 删除遗留 adhoc 路径: $LEGACY_INSTALL_DIR"
    rm -rf "$LEGACY_INSTALL_DIR"
fi

echo
echo "完成。数据目录保留在 ~/Library/Application\ Support/duo-paste/,需要可手动 rm -rf。"
echo "日志在 ~/Library/Logs/duo-paste/,同样不动。"
echo "Accessibility 列表里旧的 'DuoPaste' 记录建议手动从系统设置删掉。"
