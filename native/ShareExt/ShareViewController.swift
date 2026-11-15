import UIKit
import UniformTypeIdentifiers

/// 分享扩展：从 Safari / 微信 / 其他 App 选中文字或链接，直接问 DeepSeek。
/// 拿到内容后写进 App Group，并用 deepseeknative:// 唤起主 App。
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    handleInput()
  }

  private func handleInput() {
    guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
      finish()
      return
    }
    let providers = items.flatMap { $0.attachments ?? [] }
    guard !providers.isEmpty else {
      finish()
      return
    }
    // 优先取网页链接 + 标题，其次纯文本
    let group = DispatchGroup()
    var texts: [String] = []
    let lock = NSLock()

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          defer { group.leave() }
          var urlString: String?
          if let url = item as? URL {
            urlString = url.absoluteString
          } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            urlString = string
          }
          if let urlString {
            lock.lock()
            texts.append(urlString)
            lock.unlock()
          }
        }
      } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          defer { group.leave() }
          var text: String?
          if let string = item as? String {
            text = string
          } else if let data = item as? Data, let string = String(data: data, encoding: .utf8) {
            text = string
          }
          if let text {
            lock.lock()
            texts.append(text)
            lock.unlock()
          }
        }
      }
    }

    group.notify(queue: .main) { [weak self] in
      let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      self?.openApp(with: joined)
    }
  }

  private func openApp(with text: String) {
    guard !text.isEmpty else {
      finish()
      return
    }
    var components = URLComponents()
    components.scheme = SharedConfig.urlScheme
    components.host = "ask"
    components.queryItems = [URLQueryItem(name: "text", value: text)]
    if let url = components.url, let context = extensionContext {
      context.open(url) { [weak self] success in
        // 唤起失败时退回「待发送」队列，下次打开 App 会补发
        if !success {
          SharedConfig.setPendingQuestion(text)
        }
        self?.finish()
      }
    } else {
      SharedConfig.setPendingQuestion(text)
      finish()
    }
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
  }
}
