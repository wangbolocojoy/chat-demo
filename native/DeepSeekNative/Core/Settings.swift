import Foundation
import Observation

/// 本地设置：API Key 走 Keychain，其余存 UserDefaults。
/// apiBaseURL 默认是官方地址，调试时可以指到本地 mock 服务。
@MainActor
@Observable
final class AppSettings {
  static let shared = AppSettings()

  private enum Keys {
    static let baseURL = "apiBaseURL"
    static let thinking = "thinkingEnabled"
    static let voice = "ttsVoice"
    static let locale = "locale"
    static let search = "searchEnabled"
  }

  var apiKey: String {
    didSet { Keychain.write(apiKey, account: "api-key") }
  }

  var apiBaseURL: String {
    didSet { UserDefaults.standard.set(apiBaseURL, forKey: Keys.baseURL) }
  }

  var thinkingEnabled: Bool {
    didSet { UserDefaults.standard.set(thinkingEnabled, forKey: Keys.thinking) }
  }

  var ttsVoice: String {
    didSet { UserDefaults.standard.set(ttsVoice, forKey: Keys.voice) }
  }

  /// 是否声明联网搜索工具（关闭时仍会声明读链接工具）
  var searchEnabled: Bool {
    didSet { UserDefaults.standard.set(searchEnabled, forKey: Keys.search) }
  }

  var hasAPIKey: Bool { !apiKey.isEmpty }

  /// 请求用到的根地址，去掉结尾斜杠
  var origin: URL {
    URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "https://api.deepseek.com")!
  }

  private init() {
    let defaults = UserDefaults.standard
    apiKey = Keychain.read("api-key") ?? ""
    apiBaseURL = defaults.string(forKey: Keys.baseURL) ?? "https://api.deepseek.com"
    thinkingEnabled = defaults.object(forKey: Keys.thinking) as? Bool ?? true
    ttsVoice = defaults.string(forKey: Keys.voice) ?? "stella"
    searchEnabled = defaults.object(forKey: Keys.search) as? Bool ?? true

    #if DEBUG
    // 调试 / 自动化测试时可以用启动环境变量覆盖，避免手输
    let environment = ProcessInfo.processInfo.environment
    if let base = environment["DEEPSEEK_BASE_URL"], !base.isEmpty {
      apiBaseURL = base
    }
    if let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty {
      apiKey = key
    }
    #endif
  }
}
