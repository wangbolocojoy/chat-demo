import ActivityKit
import Foundation

/// 语音通话的 Live Activity 生命周期（锁屏卡片 + 灵动岛）
@MainActor
enum VoiceActivityManager {
  private static var activity: Activity<VoiceActivityAttributes>?

  private static func debugLog(_ text: String) {
    #if DEBUG
    guard
      let directory = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: SharedConfig.appGroup
      )
    else { return }
    let url = directory.appending(path: "activity-debug.log")
    let line = "\(Date().timeIntervalSince1970) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
    #endif
  }

  static func start() {
    guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else {
      debugLog("skip start enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled) exists=\(activity != nil)")
      return
    }
    let attributes = VoiceActivityAttributes(title: "DeepSeek 语音")
    let state = VoiceActivityAttributes.ContentState(
      statusText: "正在连接",
      startedAt: Date(),
      level: 0
    )
    do {
      activity = try Activity.request(
        attributes: attributes,
        content: ActivityContent(state: state, staleDate: nil)
      )
      debugLog("activity started id=\(activity?.id ?? "?")")
    } catch {
      debugLog("activity request failed: \(error)")
    }
  }

  static func update(statusText: String, level: Double) {
    guard let activity else {
      debugLog("update skipped: no activity (\(statusText))")
      return
    }
    let state = VoiceActivityAttributes.ContentState(
      statusText: statusText,
      startedAt: activity.content.state.startedAt,
      level: level
    )
    Task {
      await activity.update(ActivityContent(state: state, staleDate: nil))
    }
  }

  static func end() {
    guard let activity else {
      debugLog("end skipped: no activity")
      return
    }
    debugLog("activity end")
    let state = activity.content.state
    self.activity = nil
    Task {
      await activity.end(
        ActivityContent(state: state, staleDate: nil),
        dismissalPolicy: .immediate
      )
    }
  }
}
