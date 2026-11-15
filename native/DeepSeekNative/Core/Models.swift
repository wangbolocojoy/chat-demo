import Foundation

/// 一条消息在界面上的状态
enum MessageStatus: String, Codable {
  case streaming
  case done
  case stopped
  case failed
}

enum MessageRole: String, Codable {
  case user
  case assistant
}

/// 会话里的一条消息。思考内容单独存，界面上折叠展示。
struct ChatMessage: Codable, Identifiable, Hashable {
  var id = UUID()
  var role: MessageRole
  var text = ""
  var thinking = ""
  var createdAt = Date()
  var status: MessageStatus = .done

  var isEmptyAssistant: Bool { role == .assistant && text.isEmpty && thinking.isEmpty }
}

/// 一次会话：标题 + 消息列表
struct ChatSession: Codable, Identifiable, Hashable {
  var id = UUID()
  var title = ""
  var createdAt = Date()
  var updatedAt = Date()
  var messages: [ChatMessage] = []

  var displayTitle: String {
    !title.isEmpty ? title : "新对话"
  }

  var preview: String {
    messages.last?.text ?? ""
  }
}

/// 发给 Messages API 的一条消息（Anthropic 兼容格式，这里只发纯文本）
struct WireMessage: Codable {
  let role: String
  let content: String
}

/// 流式事件
enum ChatStreamEvent {
  case text(String)
  case thinking(String)
  case title(String)
  case finished(stopReason: String?)
}
