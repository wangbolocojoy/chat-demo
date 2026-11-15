import SwiftUI
import WidgetKit

@main
struct DeepSeekWidgetBundle: WidgetBundle {
  var body: some Widget {
    QuickAskWidget()
    VoiceCallLiveActivity()
  }
}
