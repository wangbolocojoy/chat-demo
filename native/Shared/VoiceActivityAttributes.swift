import ActivityKit
import Foundation

/// 语音通话的 Live Activity：锁屏 / 灵动岛显示通话状态
struct VoiceActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var statusText: String
    public var startedAt: Date
    public var level: Double
  }

  public var title: String
}
