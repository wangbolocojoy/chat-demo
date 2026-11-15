import Foundation
import Observation
import WidgetKit

/// 会话与消息的唯一数据源：负责持久化、发送消息、流式更新。
@MainActor
@Observable
final class ChatStore {
  static let shared = ChatStore()

  var sessions: [ChatSession] = []
  var activeID: UUID?
  /// 最近一次请求的错误文案，界面上用 alert 展示
  var lastError: String?
  /// 正在生成回答的会话
  var streamingSessionID: UUID?
  /// 正在上传图片等附件
  var uploading = false

  private let settings = AppSettings.shared
  private var streamTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  /// 流式回答中按 block index 累积的原始块，回答结束后写进 rawBlocks
  private var blockBuffers: [Int: JSONValue] = [:]

  private static let systemPrompt = "该助手为DeepSeek，由深度求索公司创造。"

  var activeSession: ChatSession? {
    guard let activeID else { return nil }
    return sessions.first { $0.id == activeID }
  }

  var isStreaming: Bool { streamingSessionID != nil }

  private init() {
    load()
  }

  // MARK: - 会话

  @discardableResult
  func newSession() -> ChatSession {
    let session = ChatSession()
    sessions.insert(session, at: 0)
    activeID = session.id
    persist()
    return session
  }

  func deleteSession(_ id: UUID) {
    sessions.removeAll { $0.id == id }
    if activeID == id {
      activeID = sessions.first?.id
    }
    persist()
  }

  func select(_ id: UUID) {
    activeID = id
  }

  func rename(_ id: UUID, title: String) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    sessions[index].title = title
    sessions[index].updatedAt = Date()
    persist()
  }

  // MARK: - 附件

  /// 选好图片后先上传，拿到 file_id 再发消息
  func uploadImage(data: Data, mimeType: String, width: Int, height: Int) async -> ChatAttachment? {
    guard settings.hasAPIKey else {
      lastError = "请先在设置里填写 API Key"
      return nil
    }
    uploading = true
    defer { uploading = false }
    let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
    do {
      let fileId = try await client.uploadImage(
        data: data,
        mimeType: mimeType,
        filename: "image-\(Int(Date().timeIntervalSince1970)).jpg"
      )
      return ChatAttachment(
        fileId: fileId,
        mimeType: mimeType,
        thumbnail: makeThumbnail(data),
        width: width,
        height: height
      )
    } catch {
      lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      return nil
    }
  }

  /// 本地缩略图，仅用于界面显示，随会话一起持久化
  private func makeThumbnail(_ data: Data) -> Data? {
    data.count <= 200_000 ? data : nil
  }

  // MARK: - 发送

  /// 发送一条消息并流式写入回答；onDelta 收到的是回答的完整文本（语音模式用来切句朗读）
  func send(
    _ text: String,
    attachments: [ChatAttachment] = [],
    onDelta: ((String) -> Void)? = nil
  ) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return }
    guard settings.hasAPIKey else {
      lastError = "请先在设置里填写 API Key"
      return
    }
    guard !isStreaming else { return }

    if activeSession == nil {
      newSession()
    }
    guard let sessionID = activeID,
      let index = sessions.firstIndex(where: { $0.id == sessionID })
    else { return }

    let userMessage = ChatMessage(role: .user, text: trimmed, attachments: attachments)
    let assistantMessage = ChatMessage(role: .assistant, status: .streaming)
    sessions[index].messages.append(userMessage)
    sessions[index].messages.append(assistantMessage)
    sessions[index].updatedAt = Date()
    streamingSessionID = sessionID
    persist()

    let history = Array(sessions[index].messages.dropLast(2))
    let wire = history.compactMap(wireMessage(for:)) + [userWire(for: userMessage)]
    startStream(
      sessionID: sessionID,
      assistantID: assistantMessage.id,
      wireMessages: wire,
      firstUserText: trimmed.isEmpty ? "图片" : trimmed,
      onDelta: onDelta
    )
  }

  /// 重新生成某条回答：丢掉它和它后面的消息，用同样的提问重发
  func regenerate(answerID: UUID) async {
    guard !isStreaming else { return }
    guard let sessionID = activeID,
      let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID })
    else { return }
    let messages = sessions[sessionIndex].messages
    guard let answerIndex = messages.firstIndex(where: { $0.id == answerID }),
      answerIndex > 0,
      messages[answerIndex].role == .assistant
    else { return }
    let question = messages[answerIndex - 1]
    guard question.role == .user else { return }

    sessions[sessionIndex].messages = Array(messages.prefix(answerIndex))
    let assistant = ChatMessage(role: .assistant, status: .streaming)
    sessions[sessionIndex].messages.append(assistant)
    streamingSessionID = sessionID
    persist()

    let history = Array(sessions[sessionIndex].messages.dropLast(1))
    let wire = history.compactMap(wireMessage(for:))
    startStream(
      sessionID: sessionID,
      assistantID: assistant.id,
      wireMessages: wire,
      firstUserText: question.text,
      onDelta: nil
    )
  }

  private func userWire(for message: ChatMessage) -> WireMessage {
    if message.attachments.isEmpty {
      return WireMessage(role: "user", content: .string(message.text))
    }
    var blocks = message.attachments.map { attachment in
      JSONValue.object([
        "type": .string("image"),
        "source": .object([
          "type": .string("file"),
          "file_id": .string(attachment.fileId),
        ]),
      ])
    }
    if !message.text.isEmpty {
      blocks.append(.object(["type": .string("text"), "text": .string(message.text)]))
    }
    return WireMessage(role: "user", content: .array(blocks))
  }

  /// 历史消息按 Anthropic 内容块回传：助手消息用服务端返回的原始块（含思考签名、工具块）
  private func wireMessage(for message: ChatMessage) -> WireMessage? {
    switch message.role {
    case .user:
      if !message.attachments.isEmpty {
        return userWire(for: message)
      }
      return message.text.isEmpty ? nil : WireMessage(role: "user", content: .string(message.text))
    case .assistant:
      if let blocks = message.rawBlocks, !blocks.isEmpty {
        return WireMessage(role: "assistant", content: .array(blocks))
      }
      return message.text.isEmpty ? nil : WireMessage(role: "assistant", content: .string(message.text))
    }
  }

  private func startStream(
    sessionID: UUID,
    assistantID: UUID,
    wireMessages: [WireMessage],
    firstUserText: String,
    onDelta: ((String) -> Void)?
  ) {
    blockBuffers = [:]
    let tools: [APIClient.ToolSpec] = settings.searchEnabled
      ? [
        APIClient.ToolSpec(type: "deepseek_web_search", name: "deepseek_web_search"),
        APIClient.ToolSpec(type: "deepseek_read_url", name: "deepseek_read_url"),
      ]
      : [APIClient.ToolSpec(type: "deepseek_read_url", name: "deepseek_read_url")]

    let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
    let stream = client.streamReply(
      system: Self.systemPrompt,
      messages: wireMessages,
      thinking: settings.thinkingEnabled,
      tools: tools
    )

    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await event in stream {
          if Task.isCancelled { break }
          self.apply(event, sessionID: sessionID, messageID: assistantID, onDelta: onDelta)
        }
        self.finishMessage(sessionID: sessionID, messageID: assistantID, status: .done)
      } catch is CancellationError {
        self.finishMessage(sessionID: sessionID, messageID: assistantID, status: .stopped)
      } catch {
        self.finishMessage(sessionID: sessionID, messageID: assistantID, status: .failed)
        self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      self.saveBlocks(sessionID: sessionID, messageID: assistantID)
      self.streamingSessionID = nil
      self.streamTask = nil
      self.autoTitleIfNeeded(sessionID: sessionID, firstUserText: firstUserText)
      self.persist()
    }
  }

  func stop() {
    streamTask?.cancel()
    streamTask = nil
    if let id = streamingSessionID,
      let index = sessions.firstIndex(where: { $0.id == id }),
      let messageIndex = sessions[index].messages.lastIndex(where: { $0.role == .assistant })
    {
      sessions[index].messages[messageIndex].status = .stopped
      saveBlocks(sessionID: id, messageID: sessions[index].messages[messageIndex].id)
    }
    streamingSessionID = nil
    persist()
  }

  private func apply(
    _ event: ChatStreamEvent,
    sessionID: UUID,
    messageID: UUID,
    onDelta: ((String) -> Void)?
  ) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == messageID })
    else { return }
    var changed = false
    switch event {
    case .blockStart(let blockIndex, let block):
      blockBuffers[blockIndex] = block
    case .blockStop:
      break
    case .text(let blockIndex, let text):
      sessions[index].messages[messageIndex].text += text
      appendToBlock(blockIndex, key: "text", delta: text)
      changed = true
    case .thinking(let blockIndex, let text):
      sessions[index].messages[messageIndex].thinking += text
      appendToBlock(blockIndex, key: "thinking", delta: text)
      changed = true
    case .signature(let blockIndex, let signature):
      blockBuffers[blockIndex]?["signature"] = .string(signature)
    case .title(let title):
      if sessions[index].title.isEmpty {
        sessions[index].title = title
        changed = true
      }
    case .finished:
      sessions[index].messages[messageIndex].status = .done
      changed = true
    }
    if changed {
      sessions[index].updatedAt = Date()
      onDelta?(sessions[index].messages[messageIndex].text)
    }
  }

  private func appendToBlock(_ index: Int, key: String, delta: String) {
    guard var block = blockBuffers[index] else { return }
    let existing = block[key]?.stringValue ?? ""
    block[key] = .string(existing + delta)
    blockBuffers[index] = block
  }

  /// 回答结束后把内容块按顺序写进消息，下一轮原样回传
  private func saveBlocks(sessionID: UUID, messageID: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == messageID }),
      !blockBuffers.isEmpty
    else { return }
    let blocks = blockBuffers.keys.sorted().compactMap { blockBuffers[$0] }
    sessions[index].messages[messageIndex].rawBlocks = blocks
    blockBuffers = [:]
  }

  private func finishMessage(sessionID: UUID, messageID: UUID, status: MessageStatus) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
      let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == messageID })
    else { return }
    if sessions[index].messages[messageIndex].status == .streaming {
      sessions[index].messages[messageIndex].status = status
    }
  }

  private func autoTitleIfNeeded(sessionID: UUID, firstUserText: String) {
    guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
    guard sessions[index].title.isEmpty else { return }
    let title = firstUserText.count > 18 ? String(firstUserText.prefix(18)) + "…" : firstUserText
    sessions[index].title = title
    persist()
  }

  // MARK: - 持久化

  private var storageURL: URL {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "DeepSeekNative", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "sessions.json")
  }

  private func load() {
    guard let data = try? Data(contentsOf: storageURL) else {
      sessions = []
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    sessions = (try? decoder.decode([ChatSession].self, from: data)) ?? []
    sessions.sort { $0.updatedAt > $1.updatedAt }
    activeID = sessions.first?.id
    for sessionIndex in sessions.indices {
      for messageIndex in sessions[sessionIndex].messages.indices
      where sessions[sessionIndex].messages[messageIndex].status == .streaming {
        sessions[sessionIndex].messages[messageIndex].status = .stopped
      }
    }
  }

  func persist() {
    RecentSessionsStore.write(
      sessions.prefix(6).map {
        SessionSnapshot(id: $0.id, title: $0.displayTitle, preview: $0.preview, updatedAt: $0.updatedAt)
      }
    )
    WidgetCenter.shared.reloadAllTimelines()
    SpotlightIndexer.reindex(sessions)
    let snapshot = sessions
    saveTask?.cancel()
    saveTask = Task.detached(priority: .utility) {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(snapshot) else { return }
      let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "DeepSeekNative", directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: directory.appending(path: "sessions.json"), options: .atomic)
    }
  }

  // MARK: - 导入导出

  /// 导出全部会话为 JSON 文件（分享面板 / 文件 App）
  func exportJSONFile() -> URL? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .prettyPrinted
    guard let data = try? encoder.encode(sessions) else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appending(path: "deepseek-sessions-\(Int(Date().timeIntervalSince1970)).json")
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  /// 从 JSON 文件导入：同一会话合并消息，新会话直接插入
  func importJSON(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else {
      lastError = "读取文件失败"
      return
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let imported = try? decoder.decode([ChatSession].self, from: data) else {
      lastError = "文件格式不正确"
      return
    }
    for session in imported {
      if let index = sessions.firstIndex(where: { $0.id == session.id }) {
        sessions[index] = session
      } else {
        sessions.append(session)
      }
    }
    sessions.sort { $0.updatedAt > $1.updatedAt }
    activeID = sessions.first?.id
    persist()
  }
}
