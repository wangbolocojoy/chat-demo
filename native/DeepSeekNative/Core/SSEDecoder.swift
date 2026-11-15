import Foundation

/// SSE（text/event-stream）逐行解析。
///
/// `URLSession.AsyncBytes.lines` 不会产出空行，所以这里按「收到一行就喂进来」的方式工作：
/// 空行代表一个事件结束。多行 `data` 用 `\n` 连接，注释行忽略。
struct SSEDecoder {
  struct Event {
    let event: String
    let data: String
  }

  private var dataLines: [String] = []
  private var eventName = ""

  mutating func consume(line: String) -> Event? {
    // 行内容可能带尾部 CR（CRLF 换行）
    let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
    if line.isEmpty {
      return dispatch()
    }
    if line.hasPrefix(":") {
      return nil
    }
    let colon = line.firstIndex(of: ":")
    let field = colon.map { String(line[line.startIndex..<$0]) } ?? line
    var value = colon.map { String(line[line.index(after: $0)...]) } ?? ""
    if value.hasPrefix(" ") {
      value = String(value.dropFirst())
    }
    switch field {
    case "data":
      dataLines.append(value)
    case "event":
      eventName = value
    default:
      break
    }
    return nil
  }

  /// 流结束时把尚未闭合的事件也吐出来
  mutating func finish() -> Event? {
    dispatch()
  }

  private mutating func dispatch() -> Event? {
    defer {
      dataLines.removeAll()
      eventName = ""
    }
    guard !dataLines.isEmpty else { return nil }
    return Event(event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"))
  }
}
