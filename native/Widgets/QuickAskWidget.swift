import SwiftUI
import WidgetKit

/// 桌面小组件：最近对话 + 快捷入口
struct QuickAskProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuickAskEntry {
    QuickAskEntry(date: Date(), sessions: [
      SessionSnapshot(id: UUID(), title: "今天有什么可以帮到你？", preview: "你好", updatedAt: Date())
    ])
  }

  func getSnapshot(in context: Context, completion: @escaping (QuickAskEntry) -> Void) {
    completion(QuickAskEntry(date: Date(), sessions: RecentSessionsStore.read()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAskEntry>) -> Void) {
    let entry = QuickAskEntry(date: Date(), sessions: RecentSessionsStore.read())
    let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
    completion(Timeline(entries: [entry], policy: .after(next)))
  }
}

struct QuickAskEntry: TimelineEntry {
  let date: Date
  let sessions: [SessionSnapshot]
}

struct QuickAskWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "QuickAskWidget", provider: QuickAskProvider()) { entry in
      QuickAskView(entry: entry)
        .containerBackground(for: .widget) {
          Color(uiColor: .systemBackground)
        }
    }
    .configurationDisplayName("问 DeepSeek")
    .description("快速发起对话、查看最近的会话。")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct QuickAskView: View {
  @Environment(\.widgetFamily) private var family
  let entry: QuickAskEntry

  private let brand = Color(red: 0.22, green: 0.39, blue: 1.0)

  private func sessionURL(_ session: SessionSnapshot) -> URL {
    URL(string: "\(SharedConfig.urlScheme)://session?id=\(session.id.uuidString)")!
  }

  var body: some View {
    switch family {
    case .systemSmall:
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "waveform").foregroundStyle(brand)
          Text("DeepSeek").font(.caption.weight(.semibold))
        }
        if let session = entry.sessions.first {
          Link(destination: sessionURL(session)) {
            Text(session.title)
              .font(.footnote.weight(.medium))
              .lineLimit(2)
              .foregroundStyle(.primary)
          }
          Text(session.preview)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text("还没有对话")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Link(destination: URL(string: "\(SharedConfig.urlScheme)://new")!) {
          Label("新对话", systemImage: "plus.bubble")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(brand, in: Capsule())
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    default:
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "waveform").foregroundStyle(brand)
          Text("DeepSeek").font(.caption.weight(.semibold))
          Spacer()
          Link(destination: URL(string: "\(SharedConfig.urlScheme)://voice")!) {
            Image(systemName: "phone.fill")
              .font(.caption)
              .foregroundStyle(brand)
          }
        }
        if entry.sessions.isEmpty {
          Text("还没有对话，点下面的按钮开始")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          ForEach(entry.sessions.prefix(3)) { session in
            Link(destination: sessionURL(session)) {
              HStack(spacing: 6) {
                Image(systemName: "bubble.left").font(.caption2).foregroundStyle(.secondary)
                Text(session.title).font(.footnote).lineLimit(1)
              }
              .foregroundStyle(.primary)
            }
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
          Link(destination: URL(string: "\(SharedConfig.urlScheme)://new")!) {
            Label("新对话", systemImage: "plus.bubble")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(brand, in: Capsule())
          }
          Link(destination: URL(string: "\(SharedConfig.urlScheme)://voice")!) {
            Label("语音对话", systemImage: "waveform")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(brand)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .overlay(Capsule().stroke(brand.opacity(0.4)))
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }
}
