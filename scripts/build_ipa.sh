#!/bin/bash
# 在 Mac 上直接产出「已签名、可直接安装」的 .ipa。
#
# 用法：
#   ./scripts/build_ipa.sh development          # 免费 Apple ID / Personal Team，装到本机已配对设备
#   ./scripts/build_ipa.sh adhoc                # 需付费开发者账号 + Ad Hoc 描述文件 + 设备 UDID
#   DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build_ipa.sh development
#
# 前置：Xcode 已登录 Apple ID；Target 勾选 Automatically manage signing。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:-development}"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
SCHEME="PocketTrackpad"
PROJECT="$ROOT/PocketTrackpad.xcodeproj"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/PocketTrackpad.xcarchive"
EXPORT_DIR="$BUILD/export"

case "$MODE" in
  development) PLIST="$ROOT/export/ExportOptions-Development.plist" ;;
  adhoc)       PLIST="$ROOT/export/ExportOptions-AdHoc.plist" ;;
  *) echo "用法: $0 development|adhoc"; exit 1 ;;
esac

if [ ! -d "$PROJECT" ]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo "未发现 .xcodeproj，使用 xcodegen 生成..."
    xcodegen generate
  else
    echo "错误：缺少 PocketTrackpad.xcodeproj，且未安装 xcodegen。"
    echo "请执行：brew install xcodegen && xcodegen generate"
    exit 1
  fi
fi

echo "==> 修改 Bundle ID（可选）"
echo "    当前为 com.example.PocketTrackpad。"
echo "    Sideloadly/Development 签名会自动改写，若要固定请编辑 project.yml 的 PRODUCT_BUNDLE_IDENTIFIER。"

rm -rf "$BUILD"
mkdir -p "$BUILD"

ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration Release
  -sdk iphoneos
  -archivePath "$ARCHIVE"
  -derivedDataPath "$BUILD/DerivedData"
  -allowProvisioningUpdates
)
if [ -n "$TEAM_ID" ]; then
  ARGS+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi

echo "==> archive（自动签名，$MODE）"
xcodebuild "${ARGS[@]}" clean archive

echo "==> exportArchive → ipa"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$PLIST" \
  -allowProvisioningUpdates

echo ""
echo "完成，产物目录：$EXPORT_DIR"
ls -lh "$EXPORT_DIR"/*.ipa
echo ""
echo "安装方式："
echo "  - Xcode → Window → Devices and Simulators → 选中 iPhone → 拖入 .ipa"
echo "  - 或 Apple Configurator / Finder 拖入"
echo "  - iOS 16+ 需在 设置 → 隐私与安全性 → 开发者模式 打开开关"
