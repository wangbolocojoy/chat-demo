import SwiftUI

/// 全屏语音通话界面
struct VoiceCallView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var session = VoiceSession()

  private let brand = Color(red: 0.22, green: 0.39, blue: 1.0)

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: .systemBackground), Color(uiColor: .secondarySystemBackground)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 0) {
        header
        Spacer(minLength: 12)
        orb
        status
        Text(session.debugLine)
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.tertiary)
          .padding(.top, 4)
        if let errorText = session.errorText {
          Text(errorText)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 8)
        }
        Text(session.manualMode ? "按住下方按钮说话；也可以直接说，说完停顿一下" : "说完停顿一下就行，我说话的时候你也可以插话")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
          .padding(.top, 10)
        Spacer(minLength: 12)
        captions
        footer
      }
      .padding(.vertical, 8)
    }
    .task {
      await session.start()
    }
    .onDisappear {
      session.stop()
    }
  }

  private var header: some View {
    HStack {
      Button {
        session.stop()
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 36, height: 36)
          .background(Color(uiColor: .secondarySystemBackground), in: Circle())
      }
      .accessibilityIdentifier("close-voice")
      Spacer()
      Text("语音通话")
        .font(.headline)
      Spacer()
      Color.clear.frame(width: 36, height: 36)
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
  }

  private var orb: some View {
    ZStack {
      Circle()
        .fill(brand.opacity(0.16))
        .frame(width: 200, height: 200)
        .scaleEffect(1 + session.level * 0.35)
        .animation(.easeOut(duration: 0.12), value: session.level)
      Circle()
        .fill(brand.opacity(0.22))
        .frame(width: 150, height: 150)
        .scaleEffect(1 + session.level * 0.18)
        .animation(.easeOut(duration: 0.12), value: session.level)
      Circle()
        .fill(
          RadialGradient(
            colors: [brand.opacity(0.9), brand],
            center: .topLeading,
            startRadius: 4,
            endRadius: 90
          )
        )
        .frame(width: 108, height: 108)
        .shadow(color: brand.opacity(0.5), radius: 24)
      Image(systemName: "waveform")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(height: 210)
    .onTapGesture {
      if session.status == .speaking {
        session.interrupt()
      }
    }
    .accessibilityIdentifier("voice-orb")
  }

  private var status: some View {
    Text(statusText)
      .font(.title3.weight(.semibold))
      .padding(.top, 6)
      .accessibilityIdentifier("voice-status")
  }

  private var statusText: String {
    if session.muted { return "已静音" }
    switch session.status {
    case .idle: return "未开始"
    case .starting: return "正在连接…"
    case .listening: return "我在听，直接说"
    case .thinking: return "让我想想…"
    case .speaking: return "正在回答，点一下可以打断"
    }
  }

  @ViewBuilder
  private var captions: some View {
    if !session.userText.isEmpty || !session.assistantText.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if !session.userText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("你").font(.caption).foregroundStyle(.tertiary)
              Text(session.userText).font(.callout).foregroundStyle(.secondary)
            }
          }
          if !session.assistantText.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("DeepSeek").font(.caption).foregroundStyle(.tertiary)
              Text(session.assistantText).font(.callout)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
      }
      .frame(maxHeight: 180)
    }
  }

  private var footer: some View {
    HStack(spacing: 44) {
      Button {
        session.setMuted(!session.muted)
      } label: {
        Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 20))
          .foregroundStyle(session.muted ? .white : .primary)
          .frame(width: 58, height: 58)
          .background(
            session.muted ? brand : Color(uiColor: .secondarySystemBackground),
            in: Circle()
          )
      }
      .accessibilityIdentifier("toggle-mute")

      talkButton

      Button {
        session.stop()
        dismiss()
      } label: {
        Image(systemName: "phone.down.fill")
          .font(.system(size: 22))
          .foregroundStyle(.white)
          .frame(width: 66, height: 66)
          .background(Color.red, in: Circle())
      }
      .accessibilityIdentifier("end-voice")
    }
    .padding(.top, 10)
  }

  /// 按住说话：手动录音，不依赖 VAD
  private var talkButton: some View {
    Text(session.manualRecording ? "松开发送" : "按住说话")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .frame(width: 104, height: 58)
      .background(session.manualRecording ? Color.red : brand, in: Capsule())
      .contentShape(Capsule())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if !session.manualRecording, session.status == .listening {
              session.beginManualUtterance()
            }
          }
          .onEnded { _ in
            session.endManualUtterance()
          }
      )
      .accessibilityIdentifier("push-to-talk")
  }
}
