import CoreSpotlight
import SwiftUI

/// 应用根视图：左边会话列表，右边聊天；设置和语音通话都是覆盖层
struct RootView: View {
  @State private var store = ChatStore.shared
  @State private var settings = AppSettings.shared
  @State private var showSettings = false
  @State private var showVoice = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationSplitView {
      SessionListView()
        .navigationTitle("对话")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              store.newSession()
            } label: {
              Image(systemName: "square.and.pencil")
            }
            .accessibilityIdentifier("new-session")
          }
          ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
              showVoice = true
            } label: {
              Image(systemName: "waveform")
            }
            .accessibilityIdentifier("open-voice")
            Button {
              showSettings = true
            } label: {
              Image(systemName: "gearshape")
            }
            .accessibilityIdentifier("open-settings")
          }
        }
    } detail: {
      if store.activeSession != nil {
        ChatView()
      } else {
        ContentUnavailableView(
          "开始对话",
          systemImage: "bubble.left.and.bubble.right",
          description: Text("在左侧新建一个对话，或者直接问 DeepSeek。")
        )
      }
    }
    .sheet(isPresented: $showSettings) {
      SettingsView()
    }
    .fullScreenCover(isPresented: $showVoice) {
      VoiceCallView()
    }
    .alert(
      "出错了",
      isPresented: Binding(
        get: { store.lastError != nil },
        set: { if !$0 { store.lastError = nil } }
      )
    ) {
      Button("好") { store.lastError = nil }
    } message: {
      Text(store.lastError ?? "")
    }
    .onOpenURL { url in
      handleDeepLink(url)
    }
    .onContinueUserActivity(CSSearchableItemActionType) { activity in
      if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
        let id = SpotlightIndexer.sessionID(from: identifier) {
        store.select(id)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        consumePendingRequests()
      }
    }
    .task {
      consumePendingRequests()
    }
  }

  /// deepseeknative://ask?text=... 或 deepseeknative://voice（Widget、分享扩展用）
  private func handleDeepLink(_ url: URL) {
    guard url.scheme == SharedConfig.urlScheme else { return }
    switch url.host {
    case "ask":
      let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "text" })?
        .value ?? ""
      if !text.isEmpty {
        store.newSession()
        Task { await store.send(text) }
      }
    case "voice":
      showVoice = true
    case "new":
      store.newSession()
    case "session":
      let idString = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "id" })?
        .value ?? ""
      if let id = UUID(uuidString: idString) {
        store.select(id)
      }
    default:
      break
    }
  }

  /// 处理 Siri / 快捷指令留下的请求
  private func consumePendingRequests() {
    if PendingIntentStore.consumeVoice() {
      showVoice = true
    }
    if let question = PendingIntentStore.consumeQuestion(), !question.isEmpty {
      store.newSession()
      Task {
        await store.send(question)
      }
    }
  }
}

/// 会话列表
struct SessionListView: View {
  @State private var store = ChatStore.shared
  @State private var search = ""

  private var filtered: [ChatSession] {
    guard !search.isEmpty else { return store.sessions }
    return store.sessions.filter {
      $0.displayTitle.localizedCaseInsensitiveContains(search)
        || $0.preview.localizedCaseInsensitiveContains(search)
    }
  }

  var body: some View {
    List(selection: Binding(
      get: { store.activeID },
      set: { if let id = $0 { store.select(id) } }
    )) {
      ForEach(filtered) { session in
        VStack(alignment: .leading, spacing: 4) {
          Text(session.displayTitle)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(session.preview.isEmpty ? "还没有消息" : session.preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .tag(Optional(session.id))
        .contextMenu {
          Button(role: .destructive) {
            store.deleteSession(session.id)
          } label: {
            Label("删除", systemImage: "trash")
          }
        }
        .swipeActions {
          Button(role: .destructive) {
            store.deleteSession(session.id)
          } label: {
            Label("删除", systemImage: "trash")
          }
        }
      }
    }
    .searchable(text: $search, prompt: "搜索对话")
    .overlay {
      if store.sessions.isEmpty {
        ContentUnavailableView(
          "还没有对话",
          systemImage: "text.bubble",
          description: Text("点左上角的新建按钮开始。")
        )
      }
    }
  }
}
