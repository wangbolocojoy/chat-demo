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

/// 用户消息里带的图片：服务端 file_id + 本地缩略图（界面展示用）
struct ChatAttachment: Codable, Identifiable, Hashable {
  var id = UUID()
  var fileId: String
  var mimeType: String
  var thumbnail: Data?
  var width: Int
  var height: Int
}

/// 会话里的一条消息。思考内容单独存，界面上折叠展示。
/// rawBlocks 是服务端返回的内容块原文（含思考签名与工具块），下一轮请求原样回传。
struct ChatMessage: Codable, Identifiable, Hashable {
  var id = UUID()
  var role: MessageRole
  var text = ""
  var thinking = ""
  var attachments: [ChatAttachment] = []
  var rawBlocks: [JSONValue]? = nil
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

/// 发给 Messages API 的一条消息；content 可能是纯文本，也可能是内容块数组
struct WireMessage: Encodable {
  let role: String
  let content: JSONValue
}

/// 流式事件：既有给界面用的正文增量，也有用于原样回传的内容块事件
enum ChatStreamEvent {
  case text(index: Int, String)
  case thinking(index: Int, String)
  case title(String)
  case blockStart(index: Int, block: JSONValue)
  case signature(index: Int, signature: String)
  case blockStop(index: Int)
  case finished(stopReason: String?)
}
