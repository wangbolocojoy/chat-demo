# iOS App 版

这个 fork 在官方 `chat-demo`（MIT）基础上加了一层 **Capacitor iOS 外壳**，把网页版聊天界面打包成可以在 iPhone 上独立安装运行的 App。网页版的行为完全保留：`pnpm dev` / `pnpm build` 产出的 `dist` 仍然可以直接在浏览器里用。

## 和原版的区别

| 改动 | 文件 |
| --- | --- |
| Capacitor 配置（App ID、启动图、状态栏、键盘） | `capacitor.config.ts` |
| iOS 原生工程（Xcode，SPM 依赖，无需 CocoaPods） | `ios/App/` |
| 安全区 / 状态栏 / 键盘 / 外链 / 启动图的初始化 | `src/native/index.ts`、`src/native/native.css` |
| 导出 ZIP 改为系统分享面板（WKWebView 不支持 Blob 下载） | `src/native/share.ts`、`SettingsDialog.tsx` |
| App 图标和启动图生成脚本 | `scripts/gen-app-icon.py` |
| 模拟器一键构建安装截图 | `scripts/ios-sim.sh` |
| 键盘 / 录音的 UI 冒烟测试 | `ios/AppUITests/` |

原生相关的代码都放在 `src/native/`，并且全部通过 `Capacitor.isNativePlatform()` 判断，**浏览器里不会执行**，方便继续跟进上游更新。

## 原生适配做了什么

- **安全区**：页面 `viewport-fit=cover` 铺满全屏，用 `env(safe-area-inset-*)` 让出刘海和 Home Indicator；状态栏背景就是页面底色，深浅色主题自动跟随。
- **状态栏**：文字颜色跟随应用主题（深色背景用白字，浅色背景用黑字）。
- **键盘**：Capacitor 原生收缩 WebView，`keyboardWillShow/Hide` 时去掉底部安全区预留，输入框始终贴在键盘上方。
- **外链**：聊天里的引用链接用 App 内 `SFSafariViewController` 打开（Capacitor `target=_blank` 默认会跳到 Safari）。
- **导出历史**：WKWebView 里 `<a download>` 无效，改为写入缓存目录后弹系统分享面板，可以存到「文件」App 或发微信。
- **麦克风**：`Info.plist` 已加 `NSMicrophoneUsageDescription`，语音输入走官方 ASR 接口；已于 iOS 27 模拟器验证 `getUserMedia` / 16kHz `AudioContext` 可用。
- **iOS 26+ 滚动边缘效果**：新系统会在状态栏区域叠加渐变，深色主题下顶部会有一条浅色带，`SceneDelegate.swift` 里已关闭。
- **图标 / 启动图**：`scripts/gen-app-icon.py` 用 Pillow 生成 1024 图标和 2732 启动图（不依赖外网工具），改色改形状直接改脚本重跑。

## 开发

```sh
pnpm install

# 只改网页，浏览器里开发
pnpm dev

# 改完同步到 iOS 工程（构建 dist + cap sync）
pnpm ios:sync

# 构建模拟器版本
pnpm ios:build

# 构建 + 装进模拟器 + 启动 + 截图（默认设备名 AICD-Sim，可用参数覆盖）
pnpm ios:sim "iPhone 18 Pro"

# 用 Xcode 打开工程（真机调试从这里选 Team、Run）
pnpm ios:open
```

首次生成模拟器需要先创建一台设备（本机原有设备数据损坏时）：

```sh
xcrun simctl create "AICD-Sim" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0
```

### 装到自己的 iPhone

1. `pnpm ios:open` 打开 `ios/App/App.xcodeproj`
2. 选中 App target → Signing & Capabilities → Team 选自己的 Apple ID（免费个人团队即可）
3. 数据线连上 iPhone，顶部设备选你的手机，Run
4. 首次运行去 iPhone「设置 → 通用 → VPN 与设备管理」信任自己的开发者证书

Bundle ID 是 `com.aicd.deepseekchat`，想换直接改 `capacitor.config.ts` 的 `appId` 再 `pnpm ios:sync`。

## 冒烟测试

```sh
xcodebuild test -project ios/AppUITests/AppUITests.xcodeproj -scheme AppUITests \
  -destination 'platform=iOS Simulator,id=<模拟器 UDID>'
```

覆盖两件事：键盘弹出后输入框不被遮挡、麦克风按钮能进入录音态。测试不依赖宿主 App target，直接用 `XCUIApplication(bundleIdentifier:)` 驱动已安装的 App，所以不用改 Capacitor 生成的工程。

## 已知限制

- App 是 WebView 外壳，不是 SwiftUI 原生重写；首屏、滚动性能取决于 Web 实现，但交互已经接近原生。
- API Key 存在 WebView 的 `localStorage` 里（和网页版一致），没有进 Keychain；如果要更安全可以加一个原生 Keychain 插件。
- 没有接入推送、后台任务、Face ID 锁；这些如果要可以后续补。
- 工具能力（联网搜索、深度思考）只有 `deepseek-flash` 支持，和官方公告一致。
