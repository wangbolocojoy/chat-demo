import AVFoundation
import SwiftUI

struct WatchChatView: View {
  @Environment(WatchChatStore.self) private var store
  @State private var draft = ""
  @State private var synthesizer = AVSpeechSynthesizer()
  @FocusState private var focused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if store.messages.isEmpty {
          Text("问点什么吧").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(store.messages) { message in
          if message.role == "user" {
            Text(message.text)
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.blue)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } else {
            Text(message.text.isEmpty ? "…" : message.text)
              .font(.footnote)
          }
        }
        if let errorText = store.errorText {
          Text(errorText).font(.caption2).foregroundStyle(.red)
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 6) {
        TextField("问 DeepSeek", text: $draft)
          .focused($focused)
          .onSubmit(send)
        HStack(spacing: 8) {
          Button(action: send) {
            Image(systemName: "arrow.up")
          }
          .disabled(!canSend)
          Button {
            speakLast()
          } label: {
            Image(systemName: "speaker.wave.2")
          }
          .disabled(store.messages.last?.text.isEmpty ?? true)
        }
      }
      .padding(.top, 4)
      .background(.ultraThinMaterial)
    }
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.busy
  }

  private func send() {
    guard canSend else { return }
    let text = draft
    draft = ""
    store.ask(text)
  }

  private func speakLast() {
    guard let text = store.messages.last?.text, !text.isEmpty else { return }
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
    synthesizer.speak(utterance)
  }
}
