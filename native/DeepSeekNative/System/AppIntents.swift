import AppIntents

/// 系统级入口：Siri、快捷指令、聚焦都能触发。
/// 真正的发送交给 App 前台完成，这里只把请求记下来。
enum PendingIntentStore {
  static func setQuestion(_ question: String) {
    SharedConfig.setPendingQuestion(question)
  }

  static func consumeQuestion() -> String? {
    SharedConfig.consumePendingQuestion()
  }

  static func setVoice() {
    SharedConfig.setPendingVoice()
  }

  static func consumeVoice() -> Bool {
    SharedConfig.consumePendingVoice()
  }
}

/// “问 DeepSeek”：带一个问题打开 App 并直接发送
struct AskDeepSeekIntent: AppIntent {
  static var title: LocalizedStringResource = "问 DeepSeek"
  static var description = IntentDescription("把问题发给 DeepSeek，并打开 App 显示流式回答。")
  static var openAppWhenRun: Bool = true

  @Parameter(title: "问题", requestValueDialog: "想问什么？")
  var question: String

  init() {}

  init(question: String) {
    self.question = question
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    PendingIntentStore.setQuestion(question)
    return .result(dialog: "正在问 DeepSeek：\(question)")
  }
}

/// “语音对话”：直接拉起全双工通话界面
struct StartVoiceChatIntent: AppIntent {
  static var title: LocalizedStringResource = "语音对话"
  static var description = IntentDescription("打开 DeepSeek 的全双工语音通话。")
  static var openAppWhenRun: Bool = true

  init() {}

  func perform() async throws -> some IntentResult {
    PendingIntentStore.setVoice()
    return .result()
  }
}

/// Siri / 快捷指令里可以直接说出来的短语
struct DeepSeekShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskDeepSeekIntent(),
      phrases: [
        "问 \(.applicationName)",
        "Ask \(.applicationName)",
      ],
      shortTitle: "问 DeepSeek",
      systemImageName: "bubble.left.and.bubble.right"
    )
    AppShortcut(
      intent: StartVoiceChatIntent(),
      phrases: [
        "用 \(.applicationName) 语音对话",
        "Talk to \(.applicationName)",
      ],
      shortTitle: "语音对话",
      systemImageName: "waveform"
    )
  }
}
