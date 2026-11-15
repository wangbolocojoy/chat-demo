import Foundation

/// Widget 用到的会话摘要（不包含消息正文，控制体积）
struct SessionSnapshot: Codable, Identifiable {
  let id: UUID
  let title: String
  let preview: String
  let updatedAt: Date
}

/// 会话快照写入 App Group，Widget 直接读取
enum RecentSessionsStore {
  private static let key = "shared.recent.sessions"
  private static let limit = 6

  static func write(_ snapshots: [SessionSnapshot]) {
    let trimmed = Array(snapshots.prefix(limit))
    guard let data = try? JSONEncoder().encode(trimmed) else { return }
    SharedConfig.defaults.set(data, forKey: key)
  }

  static func read() -> [SessionSnapshot] {
    guard
      let data = SharedConfig.defaults.data(forKey: key),
      let list = try? JSONDecoder().decode([SessionSnapshot].self, from: data)
    else {
      return []
    }
    return list
  }
}
