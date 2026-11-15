# DeepSeek Native（SwiftUI 原生客户端）

原生 iOS 客户端，跟 `ios/`（Capacitor 网页壳）是两条独立的实现。这里是纯 SwiftUI：
不用 WebView，聊天、流式解析、语音通话、存储全部在原生层完成，因此能接系统能力。

## 已实现

- **聊天**：会话列表 + 消息流 + 流式渲染，Anthropic 兼容的 `/anthropic/v1/messages`（SSE），
  支持深度思考块折叠、停止生成、Markdown（行内格式 + 围栏代码块）、会话持久化（JSON）。
- **全双工语音**：`AVAudioEngine` + `.voiceChat` 音频会话（系统回声消除 + 外放），
  能量 VAD + 预录、ASR → 流式回答 → 逐句 TTS 播放、**随时插话打断**。
- **系统扩展**（本次新增）：
  - **桌面 Widget**：最近会话 + 新对话 / 语音对话快捷入口（App Group 共享数据）
  - **Live Activity / 灵动岛**：语音通话时锁屏卡片和灵动岛显示状态与计时
  - **分享扩展**：Safari / 微信里选中文字或链接 → 「问 DeepSeek」直接发进 App
  - **Spotlight**：会话写入系统聚焦搜索，搜到即打开
  - **Apple Watch**：独立的 watchOS 客户端（`Watch/`，支持语音提问 + 朗读回答，见下方说明）
- **系统级能力**：
  - **Siri / 快捷指令**：`AskDeepSeekIntent`（“问 DeepSeek”，带问题打开 App 直接发送）、
    `StartVoiceChatIntent`（“用 DeepSeek 语音对话”）；App Intents 已注册（`Metadata.appintents`）。
  - **后台音频**：`UIBackgroundModes: audio`，语音通话可以切后台继续。
  - **Keychain**：API Key 存 Keychain，不落 UserDefaults。
  - 深浅色、动态字体、iPad 分栏、原生长按选择文本、系统分享（后续补）。
- **功能补齐**：图片输入（相册选图 → Files API 上传 → image 块）、深度思考/联网搜索工具块原样回传（含思考签名）、长按重新生成、会话 JSON 导入导出（系统分享面板 / 文件 App）。
- **调试**：接口地址可改，配合 `dev/mock-server.py` 在模拟器里离线联调（流式、ASR、TTS、文件上传都有 mock）。

## 目录

```
native/
├── project.yml                     # xcodegen 工程描述
├── DeepSeekNative/
│   ├── App/                        # 入口 + 根视图（分栏、Siri 请求消费）
│   ├── Core/                       # 模型、设置、Keychain、SSE、API、会话存储
│   ├── Features/Chat/              # 聊天界面、Markdown、输入栏
│   ├── Features/Voice/             # 语音会话（VAD/打断）+ 通话界面
│   ├── Features/Settings/          # 设置（Key、接口地址、思考、音色）
│   ├── System/AppIntents.swift     # Siri / 快捷指令
│   └── Resources/                  # AppIcon
└── dev/mock-server.py              # 本地 mock：SSE 聊天 / ASR / TTS
```

## 构建运行

```sh
cd native
xcodegen generate                      # 生成 DeepSeekNative.xcodeproj
open DeepSeekNative.xcodeproj          # 选 Team 后 Run
```

命令行构建模拟器版本：

```sh
xcodebuild -project DeepSeekNative.xcodeproj -scheme DeepSeekNative \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath .derivedData CODE_SIGNING_ALLOWED=NO build
```

装到真机：先 `xcodebuild -destination 'generic/platform=iOS' -allowProvisioningUpdates`
（需要在工程里填 `DEVELOPMENT_TEAM`，或 Xcode 里选 Team），再 `xcrun devicectl device install app`。

**关于 App Group（Widget 读会话数据需要）**：命令行自动签名不会自动给 App ID 打开
App Groups 能力，直接构建会报 `Provisioning profile doesn't match ... application-groups`。两种做法：

1. 在 Xcode 里给三个 target（App / Widgets / ShareExt）的 Signing & Capabilities 加上
   App Groups → `group.com.aicd.deepseeknative`，之后正常 Run，所有功能完整；
2. 只想快速装到手机、不介意 Widget 最近会话为空：构建时传 `CODE_SIGN_ENTITLEMENTS=""`，
   其余功能（分享扩展走深链、Live Activity、Spotlight、Watch）都正常。

```sh
xcodegen generate && python3 scripts/enable-capabilities.py   # 生成工程并声明能力
xcodebuild -project DeepSeekNative.xcodeproj -scheme DeepSeekNative -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .derivedData-device \
  DEVELOPMENT_TEAM=<你的 TeamID> -allowProvisioningUpdates CODE_SIGN_ENTITLEMENTS="" build
xcrun devicectl device install app --device <设备 UDID> .derivedData-device/Build/Products/Debug-iphoneos/DeepSeekNative.app
```

## 本地 mock 联调

```sh
python3 dev/mock-server.py 8099
# App 设置 → 接口地址改成 http://127.0.0.1:8099，API Key 随便填
# 或者用启动环境变量（DEBUG 生效）：
#   DEEPSEEK_BASE_URL=http://127.0.0.1:8099
#   DEEPSEEK_API_KEY=mock-key
```

UI 冒烟测试（需要先起 mock）：

```sh
xcodebuild test -project UITests/DeepSeekNativeUITests.xcodeproj \
  -scheme DeepSeekNativeUITests \
  -destination 'platform=iOS Simulator,id=<UDID>'
```

覆盖：流式聊天（mock SSE，含思考块）、语音界面打开。语音链路另外用 Mac 外放人声
喂给模拟器麦克风验证过：VAD → ASR → 流式回答 → TTS 播放 → 插话打断，全部走通。

## Apple Watch

`Watch/` 是独立的 watchOS 工程（不依赖 iPhone 端进程，手表上自己带 Keychain 和设置）：

```sh
cd native/Watch
xcodegen generate
xcodebuild -project DeepSeekWatch.xcodeproj -scheme DeepSeekWatch \
  -sdk watchos -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
```

功能：语音/文字提问、流式回答、系统朗读。因为本机没有安装 watchOS 模拟器运行时，只做了
watchOS Device SDK 的编译验证；要真机调试，先在 Xcode 里配好 Watch App 配对再 Run。

## 和网页版还差的

- 文档类附件（PDF/Office）上传；图片目前是 image 块 + Files API
- 会话多分支版本切换（重新生成会替换旧回答）
- 语音：全双工已通，但 ASR 仍是整段识别（DeepSeek 接口限制），首句延迟约 1.5–2.5s
