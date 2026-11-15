import Foundation

/// App 与扩展（Widget / 分享扩展）之间的共享配置。
/// 这些值必须和 project.yml 里的 App Group、URL scheme 保持一致。
enum SharedConfig {
  static let appGroup = "group.com.aicd.deepseeknative"
  static let urlScheme = "deepseeknative"

  static var defaults: UserDefaults {
    UserDefaults(suiteName: appGroup) ?? .standard
  }

  private static let pendingQuestionKey = "shared.pending.question"
  private static let pendingVoiceKey = "shared.pending.voice"

  /// 分享扩展 / Siri 留下的待发送问题
  static func setPendingQuestion(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    defaults.set(trimmed, forKey: pendingQuestionKey)
  }

  static func consumePendingQuestion() -> String? {
    let question = defaults.string(forKey: pendingQuestionKey)
    defaults.removeObject(forKey: pendingQuestionKey)
    return question
  }

  static func setPendingVoice() {
    defaults.set(true, forKey: pendingVoiceKey)
  }

  static func consumePendingVoice() -> Bool {
    let wants = defaults.bool(forKey: pendingVoiceKey)
    defaults.removeObject(forKey: pendingVoiceKey)
    return wants
  }
}
