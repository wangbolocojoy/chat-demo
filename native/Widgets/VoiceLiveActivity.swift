import ActivityKit
import SwiftUI
import WidgetKit

/// 语音通话的 Live Activity：锁屏卡片 + 灵动岛
struct VoiceCallLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
      HStack(spacing: 12) {
        Image(systemName: "waveform")
          .font(.title3)
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(Color(red: 0.22, green: 0.39, blue: 1.0), in: Circle())
        VStack(alignment: .leading, spacing: 2) {
          Text(context.attributes.title).font(.headline)
          Text(context.state.statusText).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(context.state.startedAt, style: .timer)
          .font(.system(.body, design: .rounded).monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding()
      .activityBackgroundTint(Color(uiColor: .systemBackground))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "waveform")
            .foregroundStyle(Color(red: 0.22, green: 0.39, blue: 1.0))
            .padding(.leading, 6)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 1) {
            Text("语音通话").font(.caption2).foregroundStyle(.secondary)
            Text(context.state.statusText).font(.caption.weight(.semibold)).lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.startedAt, style: .timer)
            .font(.system(.caption, design: .rounded).monospacedDigit())
            .padding(.trailing, 6)
        }
      } compactLeading: {
        Image(systemName: "waveform")
      } compactTrailing: {
        Text(context.state.startedAt, style: .timer)
          .font(.system(.caption2, design: .rounded).monospacedDigit())
          .frame(width: 34)
      } minimal: {
        Image(systemName: "waveform")
      }
      .keylineTint(Color(red: 0.22, green: 0.39, blue: 1.0))
    }
  }
}
