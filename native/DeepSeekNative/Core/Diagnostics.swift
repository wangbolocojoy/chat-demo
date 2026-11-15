import Foundation

/// 轻量诊断日志：写到 App Group 容器里的 voice-debug.log。
/// 语音链路出问题时，可以在设置 → 诊断日志里直接看，或者导出来发给开发者。
enum DLog {
  private static let queue = DispatchQueue(label: "com.aicd.deepseeknative.dlog")
  private static let maxBytes = 300_000

  static var logURL: URL? {
    let directory =
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConfig.appGroup)
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    return directory?.appending(path: "voice-debug.log")
  }

  static func log(_ message: String) {
    #if DEBUG
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    print("[DeepSeek] \(message)")
    queue.async {
      guard let url = logURL else { return }
      guard let data = line.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: url) {
        if handle.seekToEndOfFile() > UInt64(maxBytes) {
          try? handle.truncate(atOffset: 0)
        }
        handle.write(data)
        try? handle.close()
      } else {
        try? data.write(to: url)
      }
    }
    #endif
  }

  static func read() -> String {
    guard let url = logURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
      return "（暂无日志）"
    }
    return text
  }

  static func clear() {
    guard let url = logURL else { return }
    try? FileManager.default.removeItem(at: url)
  }
}
