#!/bin/bash
# 构建 FirebaseUploaderMac.app（release 编译 → 组装 bundle → 图标 → ad-hoc 签名）
# 用法: ./build-app.sh   产物: dist/FirebaseUploaderMac.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FirebaseUploaderMac"
BUNDLE_ID="com.firebase-uploader"
VERSION="1.4.0"
DIST="dist"

echo "==> swift build -c release"
swift build -c release

APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"

# 应用图标：1024 PNG → iconset → icns（PNG 缓存在 build/，改 scripts/make-icon.swift 后删缓存重跑）
ICON_PNG="build/AppIcon1024.png"
if [ ! -f "$ICON_PNG" ]; then
    echo "==> 生成应用图标"
    mkdir -p build
    swift scripts/make-icon.swift "$ICON_PNG"
fi
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Firebase Uploader</string>
    <key>CFBundleDisplayName</key>
    <string>Firebase Uploader</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
</dict>
</plist>
EOF

# Apple Silicon 要求可执行文件有签名；ad-hoc 签名即可本机运行
echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo "==> 完成: $APP"
