import SwiftUI
import UniformTypeIdentifiers

/// 设置：API Key（Keychain）、接口地址、思考开关、朗读音色
struct SettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var settings = AppSettings.shared
  @State private var apiKey = ""
  @State private var baseURL = ""
  @State private var verifyMessage: String?
  @State private var verifying = false
  @State private var shareItem: ShareItem?
  @State private var showImporter = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("sk-...", text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("api-key-field")
          Link("去平台获取 API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
        } header: {
          Text("API Key")
        } footer: {
          Text("Key 保存在 iOS Keychain 里，只在请求 DeepSeek 接口时使用。")
        }

        Section {
          TextField("https://api.deepseek.com", text: $baseURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("base-url-field")
        } header: {
          Text("接口地址")
        } footer: {
          Text("调试时可以指向本地 mock 服务，例如 http://127.0.0.1:8099")
        }

        Section("对话") {
          Toggle("深度思考", isOn: Binding(
            get: { settings.thinkingEnabled },
            set: { settings.thinkingEnabled = $0 }
          ))
          Toggle("联网搜索", isOn: Binding(
            get: { settings.searchEnabled },
            set: { settings.searchEnabled = $0 }
          ))
        }

        Section {
          Button("导出全部会话（JSON）") {
            if let url = ChatStore.shared.exportJSONFile() {
              shareItem = ShareItem(url: url)
            }
          }
          Button("导入会话（JSON）") {
            showImporter = true
          }
        } header: {
          Text("导入导出")
        } footer: {
          Text("导出文件可以直接存到「文件」App 或分享出去；导入会按会话 ID 合并。")
        }

        Section("语音") {
          Picker("朗读音色", selection: Binding(
            get: { settings.ttsVoice },
            set: { settings.ttsVoice = $0 }
          )) {
            Text("海星（女声）").tag("stella")
            Text("暗潮（男声）").tag("tide")
          }
        }

        Section {
          Button {
            Task { await verifyAPIKey() }
          } label: {
            HStack {
              Text("校验 API Key")
              Spacer()
              if verifying { ProgressView() }
            }
          }
          .disabled(verifying)
          if let verifyMessage {
            Text(verifyMessage)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Section("系统集成") {
          LabeledContent("Siri / 快捷指令", value: "“问 DeepSeek”")
          LabeledContent("语音对话", value: "“用 DeepSeek 语音对话”")
          LabeledContent("后台通话", value: "已启用")
        }
      }
      .navigationTitle("设置")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            save()
            dismiss()
          }
        }
      }
      .onAppear {
        apiKey = settings.apiKey
        baseURL = settings.apiBaseURL
      }
      .sheet(item: $shareItem) { item in
        ShareSheet(items: [item.url])
      }
      .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
        if case .success(let url) = result {
          ChatStore.shared.importJSON(from: url)
        }
      }
    }
  }

  private func save() {
    settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.apiBaseURL = trimmed.isEmpty ? "https://api.deepseek.com" : trimmed
  }

  private func verifyAPIKey() async {
    save()
    guard settings.hasAPIKey else {
      verifyMessage = "先填 API Key"
      return
    }
    verifying = true
    defer { verifying = false }
    do {
      let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
      try await client.verifyAPIKey()
      verifyMessage = "Key 可用 ✓"
    } catch {
      verifyMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
  }
}


struct ShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

/// 系统分享面板
struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
