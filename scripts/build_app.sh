#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="TidyBar"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"

CLANG_CACHE="${CLANG_MODULE_CACHE_PATH:-/tmp/tb-clang-cache}"
SWIFT_CACHE="${SWIFT_MODULE_CACHE_PATH:-/tmp/tb-swift-cache}"
mkdir -p "$CLANG_CACHE" "$SWIFT_CACHE" "$DIST_DIR"

echo "==> [1/4] 生成应用图标..."
if [[ ! -f "$ICON_ICNS" || "${1:-}" == "--regen-icon" ]]; then
    rm -rf "$ICONSET_DIR"
    CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift \
        -module-cache-path "$SWIFT_CACHE" \
        "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_DIR"
    iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
    rm -rf "$ICONSET_DIR"
fi

echo "==> [2/4] Release 编译 TidyBar..."
cd "$ROOT_DIR"
SWIFT_FLAGS=(
    --disable-sandbox
    -c release
    -Xswiftc -module-cache-path -Xswiftc "$SWIFT_CACHE"
    -Xcc -fmodules-cache-path="$CLANG_CACHE"
)
CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift build "${SWIFT_FLAGS[@]}" --product "$APP_NAME"
BIN_DIR="$(CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "错误：未找到 Release 可执行文件 $EXECUTABLE" >&2
    exit 1
fi

echo "==> [3/4] 组装 $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_ICNS" "$RESOURCES_DIR/AppIcon.icns"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo "==> [4/4] 代码签名并校验..."
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"TidyBar Code Signing"'; then
    SIGN_IDENTITY="TidyBar Code Signing"
else
    SIGN_IDENTITY="-"
fi
echo "使用签名身份: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "完成：$APP_BUNDLE"
