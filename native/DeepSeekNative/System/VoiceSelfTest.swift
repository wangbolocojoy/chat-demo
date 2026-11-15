import Foundation

/// 调试用自检：可通过 DeviceCTL 环境变量远程触发，把整条语音链路跑一遍并写日志。
/// - DEEPSEEK_SELFTEST=acoustic：只开听，等待外部声音（用来验证麦克风/VAD）
/// - DEEPSEEK_SELFTEST=inject：用 TTS 生成一段"用户说话"，注入 ASR→回答→TTS→播放
@MainActor
enum VoiceSelfTest {
  static var requestedMode: String? {
    ProcessInfo.processInfo.environment["DEEPSEEK_SELFTEST"]
  }

  static func run(mode: String) async {
    DLog.log("=== SELFTEST(\(mode)) begin ===")
    // 等语音界面把音频会话拉起来
    try? await Task.sleep(nanoseconds: 2_500_000_000)
    let session = VoiceSession.shared
    DLog.log("selftest: status=\(session.status) route=\(session.routeText) debug=\(session.debugLine)")

    switch mode {
    case "acoustic":
      DLog.log("selftest: acoustic waiting 45s")
      try? await Task.sleep(nanoseconds: 45_000_000_000)
      DLog.log(
        "selftest: acoustic done status=\(session.status) user=\\(session.userText) reply=\\(session.assistantText.prefix(120))"
      )
    case "inject":
      await runInject(session: session)
    case "beep":
      DLog.log("selftest: beep test start")
      for index in 0..<5 {
        session.playBeep()
        DLog.log("selftest: beep \(index)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
      DLog.log("selftest: beep test done")
    default:
      DLog.log("selftest: unknown mode")
    }
    DLog.log("=== SELFTEST end ===")
  }

  private static func runInject(session: VoiceSession) async {
    let settings = AppSettings.shared
    guard settings.hasAPIKey else {
      DLog.log("selftest: no api key")
      return
    }
    let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
    let sentence = "你好，请用一句话介绍你自己"
    DLog.log("selftest: generating prompt speech via tts")
    var pcm = Data()
    do {
      for try await chunk in client.synthesize(text: sentence, voice: settings.ttsVoice) {
        pcm.append(chunk)
      }
    } catch {
      DLog.log("selftest: tts gen failed \(error)")
      return
    }
    DLog.log("selftest: prompt speech bytes=\(pcm.count)")
    guard pcm.count > 1_000 else {
      DLog.log("selftest: prompt speech too short")
      return
    }
    let samples = stride(from: 0, to: pcm.count - 1, by: 2).map { index -> Int16 in
      Int16(bitPattern: UInt16(pcm[index]) | (UInt16(pcm[index + 1]) << 8))
    }
    let wav = VoiceSession.makeWAV(samples: samples, sampleRate: 24_000)
    DLog.log("selftest: inject wav bytes=\(wav.count)")
    session.injectUtterance(wav: wav)

    // 等这一轮跑完（最多 60 秒）
    for _ in 0..<60 {
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      if session.status == .listening, !session.assistantText.isEmpty {
        break
      }
    }
    DLog.log("selftest: inject done status=\(session.status)")
    DLog.log("selftest: asr=\(session.userText)")
    DLog.log("selftest: reply=\(session.assistantText.prefix(160))")
  }
}
