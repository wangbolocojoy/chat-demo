import Foundation
import Observation

struct WatchMessage: Identifiable {
  let id = UUID()
  let role: String
  var text: String
}

/// 手表上极简的会话状态：一问一答，回答流式追加，可朗读
@MainActor
@Observable
final class WatchChatStore {
  var messages: [WatchMessage] = []
  var busy = false
  var errorText: String?
  private let settings = AppSettings.shared

  func ask(_ question: String) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !busy else { return }
    guard settings.hasAPIKey else {
      errorText = "先在手表上填入 API Key"
      return
    }
    messages.append(WatchMessage(role: "user", text: trimmed))
    let reply = WatchMessage(role: "assistant", text: "")
    messages.append(reply)
    let replyID = reply.id
    busy = true
    errorText = nil

    let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
    let stream = client.streamReply(
      system: "该助手为DeepSeek，由深度求索公司创造。",
      messages: [WireMessage(role: "user", content: .string(trimmed))],
      thinking: settings.thinkingEnabled
    )
    Task {
      do {
        for try await event in stream {
          if case .text(_, let delta) = event {
            self.append(delta, to: replyID)
          }
        }
      } catch {
        self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      self.busy = false
    }
  }

  private func append(_ delta: String, to id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
    messages[index].text += delta
  }

  func clear() {
    messages.removeAll()
    errorText = nil
  }
}
