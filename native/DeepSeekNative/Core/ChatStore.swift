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
  /// 最近一次请求的错误文案，界面上用 toast 展示
  var lastError: String?
  /// 正在生成回答的会话
  var streamingSessionID: UUID?

  private let settings = AppSettings.shared
  private var streamTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?

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

  // MARK: - 发送

  /// 发送一条消息并流式写入回答；onDelta 收到的是回答的完整文本（语音模式用来切句朗读）
  func send(_ text: String, onDelta: ((String) -> Void)? = nil) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
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

    let userMessage = ChatMessage(role: .user, text: trimmed)
    let assistantMessage = ChatMessage(role: .assistant, status: .streaming)
    sessions[index].messages.append(userMessage)
    sessions[index].messages.append(assistantMessage)
    sessions[index].updatedAt = Date()
    streamingSessionID = sessionID
    persist()

    let history = sessions[index].messages.dropLast(2).compactMap { message -> WireMessage? in
      guard !message.text.isEmpty, message.status != .failed else { return nil }
      return WireMessage(role: message.role.rawValue, content: message.text)
    }
    // 加上刚发出的这句，去掉空的助手占位
    let wireMessages = history + [WireMessage(role: "user", content: trimmed)]

    let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
    let stream = client.streamReply(
      system: Self.systemPrompt,
      messages: wireMessages,
      thinking: settings.thinkingEnabled
    )

    streamTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await event in stream {
          if Task.isCancelled { break }
          self.apply(event, sessionID: sessionID, messageID: assistantMessage.id, onDelta: onDelta)
        }
        self.finishMessage(sessionID: sessionID, messageID: assistantMessage.id, status: .done)
      } catch is CancellationError {
        self.finishMessage(sessionID: sessionID, messageID: assistantMessage.id, status: .stopped)
      } catch {
        self.finishMessage(sessionID: sessionID, messageID: assistantMessage.id, status: .failed)
        self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      self.streamingSessionID = nil
      self.streamTask = nil
      self.autoTitleIfNeeded(sessionID: sessionID, firstUserText: trimmed)
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
    case .text(let text):
      sessions[index].messages[messageIndex].text += text
      changed = true
    case .thinking(let text):
      sessions[index].messages[messageIndex].thinking += text
      changed = true
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
    // 上次异常退出时留下「生成中」的消息，统一收尾
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
}
