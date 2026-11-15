import PhotosUI
import SwiftUI
import UIKit

/// 聊天主界面：消息列表 + 输入栏
struct ChatView: View {
  @State private var store = ChatStore.shared
  @State private var draft = ""
  @State private var picked: [ChatAttachment] = []
  @State private var photoItem: PhotosPickerItem?
  @State private var showPhotoPicker = false
  @FocusState private var inputFocused: Bool

  private let bottomAnchor = "bottom-anchor"

  var body: some View {
    let session = store.activeSession
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            if let session {
              ForEach(session.messages) { message in
                MessageRow(message: message)
              }
            }
            Color.clear
              .frame(height: 1)
              .id(bottomAnchor)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: session?.messages.count) { _, _ in
          scrollToBottom(proxy, animated: true)
        }
        .onChange(of: session?.messages.last?.text) { _, _ in
          scrollToBottom(proxy, animated: false)
        }
      }

      ComposerBar(
        draft: $draft,
        isStreaming: store.isStreaming,
        attachments: picked,
        onPickImage: { showPhotoPicker = true },
        onRemoveAttachment: { id in picked.removeAll { $0.id == id } },
        onSend: send,
        onStop: { store.stop() }
      )
    }
    .navigationTitle(session?.displayTitle ?? "DeepSeek")
    .navigationBarTitleDisplayMode(.inline)
    .background(Color(uiColor: .systemBackground))
    .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      Task { await loadPhoto(item) }
    }
  }

  private func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (!text.isEmpty || !picked.isEmpty), !store.isStreaming else { return }
    let attachments = picked
    draft = ""
    picked = []
    inputFocused = false
    Task {
      await store.send(text, attachments: attachments)
    }
  }

  /// 图片压缩到最长边 1568 再上传，避免请求体过大
  private func loadPhoto(_ item: PhotosPickerItem) async {
    defer { photoItem = nil }
    guard let data = try? await item.loadTransferable(type: Data.self),
      let image = UIImage(data: data)
    else { return }
    let maxSide: CGFloat = 1568
    let scale = min(1, maxSide / max(image.size.width, image.size.height))
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return }
    if let attachment = await store.uploadImage(
      data: jpeg,
      mimeType: "image/jpeg",
      width: Int(size.width),
      height: Int(size.height)
    ) {
      picked.append(attachment)
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }
  }
}

// MARK: - 消息

struct MessageRow: View {
  let message: ChatMessage
  private let brand = Color(red: 0.22, green: 0.39, blue: 1.0)

  var body: some View {
    switch message.role {
    case .user:
      HStack {
        Spacer(minLength: 44)
        VStack(alignment: .trailing, spacing: 6) {
          ForEach(message.attachments) { attachment in
            if let data = attachment.thumbnail, let image = UIImage(data: data) {
              Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: 180, maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
          }
          if !message.text.isEmpty {
            Text(message.text)
              .font(.body)
              .foregroundStyle(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .background(brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
              .textSelection(.enabled)
          }
        }
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 10) {
        if !message.thinking.isEmpty {
          ThinkingBlock(text: message.thinking, streaming: message.status == .streaming && message.text.isEmpty)
        }
        if message.text.isEmpty, message.status == .streaming {
          TypingIndicator()
        } else {
          MarkdownView(text: message.text)
        }
        if message.status == .failed {
          Label("回答中断，请重试", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if message.status == .stopped {
          Text("已停止生成")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
      .contextMenu {
        if message.status != .streaming {
          Button {
            Task { await ChatStore.shared.regenerate(answerID: message.id) }
          } label: {
            Label("重新生成", systemImage: "arrow.clockwise")
          }
          Button {
            UIPasteboard.general.string = message.text
          } label: {
            Label("复制", systemImage: "doc.on.doc")
          }
        }
      }
    }
  }
}

/// 深度思考：默认折叠
struct ThinkingBlock: View {
  let text: String
  let streaming: Bool
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "brain")
        Text(streaming ? "正在思考…" : "思考过程")
        Spacer()
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
  }
}

/// 回答中的三个点
struct TypingIndicator: View {
  @State private var phase = 0
  private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(spacing: 5) {
      ForEach(0..<3) { index in
        Circle()
          .fill(Color.secondary.opacity(phase == index ? 0.9 : 0.3))
          .frame(width: 6, height: 6)
      }
    }
    .padding(.vertical, 6)
    .onReceive(timer) { _ in
      phase = (phase + 1) % 3
    }
  }
}

// MARK: - Markdown

/// 轻量 Markdown 渲染：围栏代码块单独显示，其余按行内 Markdown 渲染。
struct MarkdownView: View {
  let text: String

  private enum Part: Identifiable {
    case text(String)
    case code(String, String)

    var id: Int {
      switch self {
      case .text(let value): return value.hashValue
      case .code(let value, _): return value.hashValue &+ 7
      }
    }
  }

  private var parts: [Part] {
    var result: [Part] = []
    var buffer: [String] = []
    var inCode = false
    var language = ""
    var code: [String] = []

    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        if inCode {
          result.append(.code(code.joined(separator: "\n"), language))
          code = []
          inCode = false
        } else {
          if !buffer.isEmpty {
            result.append(.text(buffer.joined(separator: "\n")))
            buffer = []
          }
          language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
          inCode = true
        }
        continue
      }
      if inCode {
        code.append(line)
      } else {
        buffer.append(line)
      }
    }
    if !code.isEmpty {
      result.append(.code(code.joined(separator: "\n"), language))
    }
    if !buffer.isEmpty {
      result.append(.text(buffer.joined(separator: "\n")))
    }
    return result.isEmpty ? [.text(text)] : result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(parts) { part in
        switch part {
        case .text(let value):
          Text(attributed(value))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
        case .code(let value, let language):
          VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
              Text(language)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
              Text(value)
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
            }
          }
          .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
      }
    }
  }

  private func attributed(_ value: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    if let parsed = try? AttributedString(markdown: value, options: options) {
      return parsed
    }
    return AttributedString(value)
  }
}

// MARK: - 输入栏

struct ComposerBar: View {
  @Binding var draft: String
  let isStreaming: Bool
  var attachments: [ChatAttachment] = []
  var onPickImage: () -> Void = {}
  var onRemoveAttachment: (UUID) -> Void = { _ in }
  let onSend: () -> Void
  let onStop: () -> Void
  @FocusState private var focused: Bool

  private var canSend: Bool {
    (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
      && !isStreaming
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              ZStack(alignment: .topTrailing) {
                if let data = attachment.thumbnail, let image = UIImage(data: data) {
                  Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Button {
                  onRemoveAttachment(attachment.id)
                } label: {
                  Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                }
                .offset(x: 4, y: -4)
              }
            }
          }
          .padding(.horizontal, 4)
        }
      }
      HStack(alignment: .bottom, spacing: 10) {
      Button {
        onPickImage()
      } label: {
        Image(systemName: "photo")
          .font(.system(size: 18))
          .foregroundStyle(.secondary)
          .frame(width: 36, height: 36)
      }
      .accessibilityIdentifier("pick-image")
      TextField("给 DeepSeek 发消息", text: $draft, axis: .vertical)
        .lineLimit(1...6)
        .focused($focused)
        .accessibilityIdentifier("composer-input")
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          Color(uiColor: .secondarySystemBackground),
          in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )

      Button {
        if isStreaming {
          onStop()
        } else {
          onSend()
        }
      } label: {
        Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(
            isStreaming ? Color.secondary : (canSend ? Color(red: 0.22, green: 0.39, blue: 1.0) : Color.secondary.opacity(0.4)),
            in: Circle()
          )
      }
      .disabled(!isStreaming && !canSend)
      .accessibilityIdentifier(isStreaming ? "stop-reply" : "send-message")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }
}
