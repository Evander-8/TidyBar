#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="TidyBar"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
STAGING_DIR="$DIST_DIR/dmg_staging"
TEMP_DMG="$DIST_DIR/${APP_NAME}-temp.dmg"
FINAL_DMG="$DIST_DIR/${APP_NAME}.dmg"
VOLUME_NAME="TidyBar"

"$ROOT_DIR/scripts/build_app.sh" "${@:-}"

echo "==> 准备 DMG 暂存目录..."
rm -rf "$STAGING_DIR" "$TEMP_DMG" "$FINAL_DMG"
mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> 创建可读写过渡 DMG 并尝试应用拖拽安装窗口布局..."
if hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDRW -fs HFS+ "$TEMP_DMG" >/dev/null 2>&1; then
    MOUNT_DIR="$(mktemp -d /tmp/tidybar-dmg.XXXXXX)"
    if hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" "$TEMP_DMG" >/dev/null 2>&1; then
        osascript <<EOF >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 160, 800, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "$APP_NAME.app" of container window to {150, 165}
        set position of item "Applications" of container window to {410, 165}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF
        sync
        hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
    fi
    rmdir "$MOUNT_DIR" 2>/dev/null || true

    echo "==> 压缩输出最终 DMG..."
    hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$FINAL_DMG"
    rm -f "$TEMP_DMG"
else
    echo "==> 直接生成压缩 UDZO DMG..."
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO -imagekey zlib-level=9 "$FINAL_DMG"
fi

rm -rf "$STAGING_DIR"
ls -lh "$FINAL_DMG"
echo "完成：$FINAL_DMG"
