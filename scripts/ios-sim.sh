#!/usr/bin/env bash
# 把构建好的 App 装进模拟器、启动并截图，用于快速验证 iOS 端的改动。
#
# 用法：bash scripts/ios-sim.sh [模拟器名称，默认 "iPhone 18 Pro"]
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 18 Pro}"
APP_PATH=".derivedData/Build/Products/Debug-iphonesimulator/App.app"
BUNDLE_ID="com.aicd.deepseekchat"
SHOT_DIR="${SHOT_DIR:-.screenshots}"

if [ ! -d "$APP_PATH" ]; then
  echo "找不到 $APP_PATH，先运行 pnpm ios:build" >&2
  exit 1
fi

mkdir -p "$SHOT_DIR"

echo "==> 启动模拟器：$DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
SIMULATOR_APP="$(xcode-select -p)/Applications/Simulator.app"
[ -d "$SIMULATOR_APP" ] && open "$SIMULATOR_APP" || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

echo "==> 安装并启动 App"
xcrun simctl install "$DEVICE" "$APP_PATH"
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

# 等首屏渲染完再截图
sleep "${WAIT_SECONDS:-4}"
if [ "${SKIP_SCREENSHOT:-0}" != "1" ]; then
  xcrun simctl io "$DEVICE" screenshot "$SHOT_DIR/ios-home.png"
  echo "==> 截图：$SHOT_DIR/ios-home.png"
fi
