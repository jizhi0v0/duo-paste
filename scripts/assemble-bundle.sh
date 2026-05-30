#!/usr/bin/env bash
# 组装 + 深签 DuoPaste.app —— install-agent.sh（本机装）和 .github/workflows/release.yml
# （发布）共享这一段，避免两处组 bundle / Sparkle 深签逻辑漂移（深签顺序极脆，只该有一个
# 权威实现）。**只负责到 bundle 签好为止**：launchd plist / notarize / DMG 由各调用方自理。
#
# 入参全走环境变量：
#   必填：DP_APP DP_BINARY DP_SHORT_VERSION DP_BUILD_NUMBER DP_SIGN_IDENTITY
#   可选：DP_BUNDLE_ID(默 io.duopaste.daemon) DP_BUNDLE_NAME(默 DuoPaste)
#         DP_SPARKLE_FW(Sparkle.framework 路径；空/不存在 → 不嵌、不写 SU 键)
#         DP_SU_FEED_URL / DP_SU_PUBLIC_ED_KEY(嵌 Sparkle 时必填)
#         DP_TIMESTAMP(1 → codesign 加 --timestamp，notarize 必需；默 0)
set -euo pipefail

: "${DP_APP:?DP_APP 必填}"
: "${DP_BINARY:?DP_BINARY 必填}"
: "${DP_SHORT_VERSION:?DP_SHORT_VERSION 必填}"
: "${DP_BUILD_NUMBER:?DP_BUILD_NUMBER 必填}"
: "${DP_SIGN_IDENTITY:?DP_SIGN_IDENTITY 必填}"
BUNDLE_ID="${DP_BUNDLE_ID:-io.duopaste.daemon}"
BUNDLE_NAME="${DP_BUNDLE_NAME:-DuoPaste}"
SPARKLE_FW="${DP_SPARKLE_FW:-}"

if [[ ! -x "$DP_BINARY" ]]; then
    echo "assemble-bundle: 构建产物不存在/不可执行: $DP_BINARY" >&2
    exit 1
fi

# --timestamp 只在 notarize 路径加（连 Apple 时间戳服务，本机慢且非必需）。
CS_FLAGS=(--force --options runtime)
[[ "${DP_TIMESTAMP:-0}" == "1" ]] && CS_FLAGS+=(--timestamp)

EMBED_SPARKLE=0
[[ -n "$SPARKLE_FW" && -d "$SPARKLE_FW" ]] && EMBED_SPARKLE=1

echo "==> 组装 .app bundle: $DP_APP (sparkle=$EMBED_SPARKLE timestamp=${DP_TIMESTAMP:-0})"
rm -rf "$DP_APP"
mkdir -p "$DP_APP/Contents/MacOS"
cp "$DP_BINARY" "$DP_APP/Contents/MacOS/duo-pasted"
chmod +x "$DP_APP/Contents/MacOS/duo-pasted"

# Sparkle.framework → Contents/Frameworks/ + 补 @loader_path/../Frameworks rpath（裸 swift
# build 不加这条，Contents/MacOS → ../Frameworks；spike 实测不补 dyld 找不到 dylib）。
if [[ "$EMBED_SPARKLE" == "1" ]]; then
    echo "==> 嵌入 Sparkle.framework + 补 rpath"
    mkdir -p "$DP_APP/Contents/Frameworks"
    # -R 保符号链接（framework Versions/Current 是 symlink，解开会破坏签名）
    cp -R "$SPARKLE_FW" "$DP_APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$DP_APP/Contents/MacOS/duo-pasted" 2>/dev/null \
        || echo "   (rpath 已存在，跳过)"
fi

# 嵌 Sparkle 时拼一段 SU 键，注入 Info.plist。变量先算好，避免 heredoc 内嵌条件展开。
SU_KEYS=""
if [[ "$EMBED_SPARKLE" == "1" ]]; then
    : "${DP_SU_FEED_URL:?嵌 Sparkle 时 DP_SU_FEED_URL 必填}"
    : "${DP_SU_PUBLIC_ED_KEY:?嵌 Sparkle 时 DP_SU_PUBLIC_ED_KEY 必填}"
    SU_KEYS="    <key>SUFeedURL</key>
    <string>${DP_SU_FEED_URL}</string>
    <key>SUPublicEDKey</key>
    <string>${DP_SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>"
fi

# LSUIElement=true → accessory app（无 Dock 图标 / 不抢主菜单）。daemon 走 SwiftUI accessory。
cat >"$DP_APP/Contents/Info.plist" <<INFO_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>duo-pasted</string>
    <key>CFBundleName</key>
    <string>${BUNDLE_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${BUNDLE_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${DP_SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${DP_BUILD_NUMBER}</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
${SU_KEYS}
</dict>
</plist>
INFO_EOF

echo "==> 签名 bundle (Developer ID Application + hardened runtime)"
if [[ "$EMBED_SPARKLE" == "1" ]]; then
    # Sparkle 内嵌物由内而外深签（顺序硬要求：先 nested Mach-O / bundle，再 framework，最后
    # 外层 app）。spike 实测能过 codesign --verify --deep --strict + 运行加载。find 遍历覆盖
    # Autoupdate / XPCServices/*.xpc / Updater.app，未来加新嵌入物也兜得到。
    SPB="$DP_APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    echo "   深签 Sparkle 内嵌 Mach-O / bundle"
    find "$SPB" -type f \( -name Autoupdate -o -path '*/Contents/MacOS/*' \) -print0 \
        | while IFS= read -r -d '' p; do
            codesign "${CS_FLAGS[@]}" --sign "$DP_SIGN_IDENTITY" "$p"
        done
    find "$SPB" -depth \( -name '*.app' -o -name '*.xpc' \) -print0 \
        | while IFS= read -r -d '' p; do
            codesign "${CS_FLAGS[@]}" --sign "$DP_SIGN_IDENTITY" "$p"
        done
    codesign "${CS_FLAGS[@]}" --sign "$DP_SIGN_IDENTITY" "$DP_APP/Contents/Frameworks/Sparkle.framework"
fi
# 外层 app（含 embedded framework 后必须最后签）
codesign "${CS_FLAGS[@]}" --sign "$DP_SIGN_IDENTITY" "$DP_APP"

echo "==> 验证签名"
if [[ "$EMBED_SPARKLE" == "1" ]]; then
    codesign --verify --deep --strict --verbose=2 "$DP_APP"
else
    codesign --verify --strict --verbose=2 "$DP_APP"
fi
codesign -dvv "$DP_APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -10 || true
echo "==> bundle 就绪: $DP_APP"
