# DeepSeek Native（SwiftUI 原生客户端）

原生 iOS 客户端，跟 `ios/`（Capacitor 网页壳）是两条独立的实现。这里是纯 SwiftUI：
不用 WebView，聊天、流式解析、语音通话、存储全部在原生层完成，因此能接系统能力。

## 已实现

- **聊天**：会话列表 + 消息流 + 流式渲染，Anthropic 兼容的 `/anthropic/v1/messages`（SSE），
  支持深度思考块折叠、停止生成、Markdown（行内格式 + 围栏代码块）、会话持久化（JSON）。
- **全双工语音**：`AVAudioEngine` + `.voiceChat` 音频会话（系统回声消除 + 外放），
  能量 VAD + 预录、ASR → 流式回答 → 逐句 TTS 播放、**随时插话打断**。
- **系统级能力**：
  - **Siri / 快捷指令**：`AskDeepSeekIntent`（“问 DeepSeek”，带问题打开 App 直接发送）、
    `StartVoiceChatIntent`（“用 DeepSeek 语音对话”）；App Intents 已注册（`Metadata.appintents`）。
  - **后台音频**：`UIBackgroundModes: audio`，语音通话可以切后台继续。
  - **Keychain**：API Key 存 Keychain，不落 UserDefaults。
  - 深浅色、动态字体、iPad 分栏、原生长按选择文本、系统分享（后续补）。
- **调试**：接口地址可改，配合 `dev/mock-server.py` 在模拟器里离线联调（流式、ASR、TTS 都有 mock）。

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

## 和网页版的功能差距（后续补）

- 附件上传 / 图片输入、搜索与链接阅读的工具块回传（服务端工具块需要原样带回下一轮）
- 会话重命名、导入 / 导出、多分支版本切换
- 系统级扩展：Widget、Live Activity / 灵动岛、分享扩展、Spotlight 索引
- 语音：全双工已通，但 ASR 仍是整段识别（DeepSeek 接口限制），首句延迟约 1.5–2.5s
