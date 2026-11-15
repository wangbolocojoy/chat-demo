import SwiftUI

/// 手表上的设置：API Key 直接在小屏上输入不方便，所以也支持用手机端同一套 Key（各自 Keychain）
struct WatchSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var settings = AppSettings.shared
  @State private var key = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("API Key") {
          SecureField("sk-...", text: $key)
        }
        Section("接口地址") {
          TextField("https://api.deepseek.com", text: Binding(
            get: { settings.apiBaseURL },
            set: { settings.apiBaseURL = $0 }
          ))
        }
        Section {
          Button("保存") {
            settings.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            dismiss()
          }
        }
      }
      .onAppear { key = settings.apiKey }
    }
  }
}
