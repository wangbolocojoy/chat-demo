import SwiftUI

@main
struct DeepSeekWatchApp: App {
  @State private var store = WatchChatStore()

  var body: some Scene {
    WindowGroup {
      WatchChatView()
        .environment(store)
    }
  }
}
