import AVFoundation
import Observation
import SwiftUI

/// 全双工语音会话：原生 AVAudioEngine 采集/播放 + 能量 VAD + ASR/TTS。
/// 人说话时持续采集，回答期间也在听，检测到插话就立刻打断。
@MainActor
@Observable
final class VoiceSession {
  static let shared = VoiceSession()
  enum Status: Equatable {
    case idle
    case starting
    case listening
    case thinking
    case speaking
  }

  var status: Status = .idle {
    didSet {
      DLog.log("voice status -> \(status)")
      syncActivity()
    }
  }
  var level: Double = 0
  var muted = false
  /// 手动模式：按住说话，不走 VAD（真机上 VAD 不灵时的兜底）
  var manualMode = true
  var manualRecording = false
  /// 界面上展示的实时诊断信息
  var debugLine = ""
  /// 当前音频输出路由（外放 / 耳机 / AirPlay / 蓝牙），用来确认声音去哪了
  var routeText = ""

  private var lastDebugAt = Date.distantPast
  var userText = ""
  var assistantText = ""
  var errorText: String?

  private let settings = AppSettings.shared
  private let store = ChatStore.shared

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let inputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
  )!
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
  )!
  private var running = false
  private var playerAttached = false
  private var interruptionObserver: NSObjectProtocol?

  // VAD
  private var noiseFloor = 0.005
  private var speechMs = 0
  private var silenceMs = 0
  private var capturing = false
  private var preRoll: [Int16] = []
  private var preRollMs = 0
  private var utterance: [Int16] = []
  private var utteranceMs = 0
  private var frameCount = 0
  private var lastRms: Double = 0
  private var loggedFirstDelta = false
  private var routeObserver: NSObjectProtocol?

  // 回答回合
  private var turnActive = false
  private var bargeMs = 0
  private var generationDone = true
  private var ttsQueue: [String] = []
  private var ttsTask: Task<Void, Never>?
  private var chatTask: Task<Void, Never>?
  private var asrTask: Task<Void, Never>?
  private var turnEndTask: Task<Void, Never>?
  private var pendingText = ""
  private var spokenCount = 0
  private var audioClock: TimeInterval = 0

  private let frameMs = 32
  private let bargeThreshold = 0.03
  /// 说话阈值下限调低，真机上麦克风增益偏小时也能断句
  private let speechThreshold = 0.004

  // MARK: - 生命周期

  func start() async {
    DLog.log("voice start requested hasKey=\(settings.hasAPIKey) origin=\(settings.origin.absoluteString)")
    guard !running else { return }
    guard settings.hasAPIKey else {
      errorText = "请先在设置里填写 API Key"
      DLog.log("voice start aborted: no api key")
      return
    }
    status = .starting
    errorText = nil

    let granted = await requestMicrophone()
    DLog.log("voice mic permission granted=\(granted)")
    guard granted else {
      errorText = "无法使用麦克风，请到系统设置里允许 DeepSeek 访问麦克风"
      status = .idle
      return
    }

    do {
      try startEngine()
      DLog.log("voice engine started")
    } catch {
      errorText = "音频通道启动失败：\(error.localizedDescription)"
      DLog.log("voice engine start failed: \(error)")
      status = .idle
      return
    }

    running = true
    resetVad()
    status = .listening
    observeInterruptions()
  }

  func stop() {
    guard running || status != .idle else { return }
    running = false
    turnActive = false
    ttsTask?.cancel()
    ttsTask = nil
    chatTask?.cancel()
    chatTask = nil
    asrTask?.cancel()
    asrTask = nil
    turnEndTask?.cancel()
    turnEndTask = nil
    ttsQueue.removeAll()
    if store.isStreaming { store.stop() }
    teardownEngine()
    status = .idle
    level = 0
    removeInterruptionObserver()
  }

  func setMuted(_ value: Bool) {
    muted = value
  }

  /// 手动模式：按下开始收音
  func beginManualUtterance() {
    guard running, !turnActive else { return }
    DLog.log("manual listen start")
    manualRecording = true
    capturing = true
    utterance.removeAll()
    utteranceMs = 0
    silenceMs = 0
    speechMs = 0
    userText = "（正在听你说…）"
    status = .listening
  }

  /// 手动模式：松手结束收音并进入识别
  func endManualUtterance() {
    guard running, manualRecording else { return }
    manualRecording = false
    DLog.log("manual listen end durationMs=\(utteranceMs)")
    let samples = utterance
    let duration = utteranceMs
    resetVad()
    userText = ""
    guard duration >= 250 else {
      errorText = "没录到声音，靠近一点再说一次"
      DLog.log("manual listen too short")
      return
    }
    asrTask = Task { await self.processUtterance(Self.makeWAV(samples: samples, sampleRate: 16_000)) }
  }

  /// 自检用：把一段现成的 WAV 直接当成"用户说的一句话"送进识别
  func injectUtterance(wav: Data) {
    guard running else {
      DLog.log("inject skipped: session not running")
      return
    }
    DLog.log("inject utterance bytes=\(wav.count)")
    turnActive = true
    bargeMs = 0
    asrTask = Task { await self.processUtterance(wav) }
  }

  /// 手动打断：停掉朗读和生成，回到倾听
  func interrupt() {
    guard running else { return }
    ttsTask?.cancel()
    ttsTask = nil
    ttsQueue.removeAll()
    player.stop()
    player.play()
    if store.isStreaming { store.stop() }
    chatTask?.cancel()
    chatTask = nil
    turnActive = false
    generationDone = true
    resetVad()
    status = .listening
  }

  private func observeInterruptions() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw),
        type == .began
      else { return }
      Task { @MainActor in
        self?.stop()
        self?.errorText = "音频被系统打断，通话已结束"
      }
    }
  }

  private func removeInterruptionObserver() {
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
      self.interruptionObserver = nil
    }
  }

  /// 把通话状态同步到锁屏 / 灵动岛
  private func syncActivity() {
    if status == .idle {
      VoiceActivityManager.end()
      return
    }
    VoiceActivityManager.start()
    let text: String
    switch status {
    case .idle: text = ""
    case .starting: text = "正在连接"
    case .listening: text = "正在倾听"
    case .thinking: text = "正在思考"
    case .speaking: text = "正在回答"
    }
    VoiceActivityManager.update(statusText: text, level: level)
  }

  // MARK: - 音频引擎

  private func requestMicrophone() async -> Bool {
    if #available(iOS 17.0, *) {
      return await AVAudioApplication.requestRecordPermission()
    } else {
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  }

  private func startEngine() throws {
    let session = AVAudioSession.sharedInstance()
    let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
      (.playAndRecord, .voiceChat, [.defaultToSpeaker, .allowBluetooth]),
      (.playAndRecord, .voiceChat, [.defaultToSpeaker]),
      (.playAndRecord, .voiceChat, []),
      (.playAndRecord, .default, [.defaultToSpeaker]),
    ]
    var configured = false
    var lastError: Error?
    for (category, mode, options) in attempts {
      do {
        try session.setCategory(category, mode: mode, options: options)
        configured = true
        DLog.log("audio session ok category=\(category.rawValue) mode=\(mode.rawValue) options=\(options.rawValue)")
        break
      } catch {
        lastError = error
        DLog.log("audio session failed category=\(category.rawValue) mode=\(mode.rawValue): \(error)")
      }
    }
    guard configured else {
      throw lastError ?? NSError(domain: "VoiceSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法配置音频会话"])
    }
    do {
      try session.setActive(true)
    } catch {
      DLog.log("audio session activate failed: \(error)")
      throw error
    }

    if !playerAttached {
      engine.attach(player)
      engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
      playerAttached = true
    }

    let input = engine.inputNode
    let hardwareFormat = input.outputFormat(forBus: 0)
    guard let converter = AVAudioConverter(from: hardwareFormat, to: inputFormat) else {
      throw NSError(domain: "VoiceSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法重采样麦克风音频"])
    }
    Self.converterBox.value = converter
    Self.inputFormatBox.value = inputFormat

    input.installTap(onBus: 0, bufferSize: 1_024, format: hardwareFormat) { [weak self] buffer, _ in
      self?.handleHardwareBuffer(buffer)
    }
    DLog.log("mic format sr=\(hardwareFormat.sampleRate) ch=\(hardwareFormat.channelCount)")
    logAudioRoute()
    observeRouteChanges()

    engine.prepare()
    try engine.start()
    player.play()
    // 开始通话时播一个短提示音，顺便验证扬声器通路
    playBeep()
  }

  /// 记录并展示当前音频路由，方便确认声音是外放还是被 AirPlay / 蓝牙 / 电脑接走
  private func logAudioRoute() {
    let session = AVAudioSession.sharedInstance()
    let outputs = session.currentRoute.outputs
      .map { "\($0.portType.rawValue):\($0.portName)" }
      .joined(separator: ", ")
    let inputs = session.currentRoute.inputs
      .map { "\($0.portType.rawValue):\($0.portName)" }
      .joined(separator: ", ")
    let volume = session.outputVolume
    let silentHint = session.secondaryAudioShouldBeSilencedHint
    DLog.log(
      "audio route out=[\(outputs)] in=[\(inputs)] outputVolume=\(String(format: "%.2f", volume)) silentHint=\(silentHint)"
    )
    routeText = "输出：\(outputs.isEmpty ? "未知" : outputs)  音量 \(String(format: "%.0f%%", volume * 100))"
  }

  private func observeRouteChanges() {
    guard routeObserver == nil else { return }
    routeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.logAudioRoute() }
    }
  }

  /// 880 Hz / 150 ms 的提示音
  func playBeep() {
    let rate = 24_000.0
    let frames = Int(rate * 0.3)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: AVAudioFrameCount(frames)
      ),
      let channel = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames {
      let envelope = min(1.0, Double(min(index, frames - index)) / 400.0)
      channel[index] = Float(sin(2 * .pi * 880 * Double(index) / rate) * 0.6 * envelope)
    }
    player.scheduleBuffer(buffer, completionHandler: nil)
    DLog.log("beep scheduled")
  }

  private func teardownEngine() {
    guard engine.isRunning || playerAttached else { return }
    engine.inputNode.removeTap(onBus: 0)
    player.stop()
    engine.stop()
    if playerAttached {
      engine.detach(player)
      playerAttached = false
    }
    Self.converterBox.value = nil
    Self.inputFormatBox.value = nil
    if let routeObserver {
      NotificationCenter.default.removeObserver(routeObserver)
      self.routeObserver = nil
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  /// 音频线程：重采样成 16 kHz / Int16 后丢给主线程处理
  private nonisolated func handleHardwareBuffer(_ buffer: AVAudioPCMBuffer) {
    guard let converter = Self.converterBox.value, let outputFormat = Self.inputFormatBox.value else {
      return
    }
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
    guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return
    }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: converted, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != AVAudioConverterOutputStatus.error, converted.frameLength > 0,
      let pointer = converted.int16ChannelData?[0]
    else {
      return
    }
    let count = Int(converted.frameLength)
    let samples: [Int16] = Array(UnsafeBufferPointer(start: pointer, count: count))
    Task { @MainActor [weak self] in
      self?.handleFrame(samples)
    }
  }

  /// 音频线程访问转换器用的共享盒子（安装 tap 时写入）
  private final class Box<T>: @unchecked Sendable {
    var value: T?
  }
  nonisolated(unsafe) private static let converterBox = Box<AVAudioConverter>()
  nonisolated(unsafe) private static let inputFormatBox = Box<AVAudioFormat>()

  // MARK: - VAD

  private func handleFrame(_ samples: [Int16]) {
    guard running else { return }
    let rms = Self.rms(of: samples)
    updateLevel(rms)
    frameCount += 1
    lastRms = rms
    if Date().timeIntervalSince(lastDebugAt) > 0.4 {
      lastDebugAt = Date()
      debugLine = String(
        format: "frames=%d  rms=%.3f  floor=%.3f  turn=%@  manual=%@",
        frameCount, rms, noiseFloor, turnActive ? "Y" : "N", manualRecording ? "Y" : "N"
      )
    }
    if frameCount % 60 == 0 {
      DLog.log("audio frames=\(frameCount) rms=\(String(format: "%.4f", rms)) floor=\(String(format: "%.4f", noiseFloor)) turn=\(turnActive)")
    }
    if !capturing && rms < noiseFloor * 2 {
      noiseFloor = noiseFloor * 0.97 + rms * 0.03
    }
    pushPreRoll(samples)

    if turnActive {
      handleTurnFrame(rms)
      return
    }
    if manualRecording {
      utterance.append(contentsOf: samples)
      utteranceMs += frameMs
      silenceMs += frameMs
      if (lastRms < max(noiseFloor * 2.5, speechThreshold) && utteranceMs > 1_500)
        || utteranceMs >= 30_000
      {
        endManualUtterance()
      }
      return
    }
    guard !muted else { return }
    handleListenFrame(samples, rms: rms)
  }

  private func updateLevel(_ rms: Double) {
    level = min(1, rms * 9)
  }

  private func pushPreRoll(_ samples: [Int16]) {
    preRoll.append(contentsOf: samples)
    preRollMs += frameMs
    let limit = 300 / frameMs
    while preRollMs > 300, preRoll.count > 512 * limit {
      preRoll.removeFirst(512)
      preRollMs -= frameMs
    }
  }

  private func resetVad() {
    capturing = false
    speechMs = 0
    silenceMs = 0
    preRoll.removeAll()
    preRollMs = 0
    utterance.removeAll()
    utteranceMs = 0
    bargeMs = 0
  }

  private func handleListenFrame(_ samples: [Int16], rms: Double) {
    let speakingNow = rms > max(noiseFloor * 3, speechThreshold)
    if !capturing {
      if speakingNow {
        speechMs += frameMs
        if speechMs >= 128 {
          startUtterance()
        }
      } else {
        speechMs = max(0, speechMs - frameMs)
      }
      return
    }

    utterance.append(contentsOf: samples)
    utteranceMs += frameMs
    if speakingNow {
      silenceMs = 0
    } else {
      silenceMs += frameMs
    }
    if silenceMs >= 700 || utteranceMs >= 45_000 {
      finishUtterance()
    }
  }

  private func startUtterance() {
    DLog.log("utterance start")
    capturing = true
    utterance = preRoll
    utteranceMs = preRollMs
    silenceMs = 0
    speechMs = 0
    userText = ""
    status = .listening
  }

  private func finishUtterance() {
    DLog.log("utterance end durationMs=\(utteranceMs)")
    let samples = utterance
    let duration = utteranceMs
    resetVad()
    guard duration >= 320 else { return }
    let wav = Self.makeWAV(samples: samples, sampleRate: 16_000)
    asrTask = Task { await self.processUtterance(wav) }
  }

  private func processUtterance(_ wav: Data) async {
    turnActive = true
    bargeMs = 0
    status = .thinking
    DLog.log("asr start bytes=\(wav.count)")
    let client = APIClient(origin: settings.origin, apiKey: settings.apiKey)
    do {
      let text = try await client.transcribe(wav: wav).trimmingCharacters(in: .whitespacesAndNewlines)
      DLog.log("asr result: \(text.isEmpty ? "<empty>" : text)")
      guard running, !Task.isCancelled else { return }
      guard !text.isEmpty else {
        abortTurn()
        status = .listening
        errorText = "没听清，再说一次吧"
        return
      }
      userText = text
      assistantText = ""
      loggedFirstDelta = false
      errorText = nil
      beginTurn(text: text)
    } catch {
      DLog.log("asr failed: \(error)")
      guard !Task.isCancelled else { return }
      fail(error)
    }
  }

  // MARK: - 回答回合

  private func beginTurn(text: String) {
    generationDone = false
    pendingText = ""
    spokenCount = 0
    ttsQueue.removeAll()
    audioClock = Date().timeIntervalSince1970

    if store.activeSession == nil {
      store.newSession()
    }
    DLog.log("voice turn send: \(text)")

    chatTask = Task { [weak self] in
      guard let self else { return }
      await self.store.send(
        text,
        onDelta: { fullText in
          self.handleAssistantDelta(fullText)
        },
        onFinish: { [weak self] in
          guard let self else { return }
          DLog.log("voice generation finished")
          self.generationDone = true
          self.drainSentences(flush: true)
          self.maybeFinishTurn()
        }
      )
    }
  }

  private func handleAssistantDelta(_ fullText: String) {
    guard running else { return }
    if !loggedFirstDelta, !fullText.isEmpty {
      loggedFirstDelta = true
      DLog.log("assistant first delta")
    }
    assistantText = fullText
    guard fullText.count > spokenCount else { return }
    let start = fullText.index(fullText.startIndex, offsetBy: spokenCount)
    pendingText += String(fullText[start...])
    spokenCount = fullText.count
    drainSentences(flush: false)
  }

  private func drainSentences(flush: Bool) {
    let terminators = "。！？!?；;\n"
    let softBreaks = "，,、"
    var sentences: [String] = []
    var startIndex = pendingText.startIndex
    var index = pendingText.startIndex
    while index < pendingText.endIndex {
      let character = pendingText[index]
      let distance = pendingText.distance(from: startIndex, to: index)
      let hard = terminators.contains(character)
      let soft = softBreaks.contains(character) && distance >= 48
      if hard || soft {
        let sentence = String(pendingText[startIndex...index]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty { sentences.append(sentence) }
        startIndex = pendingText.index(after: index)
      }
      index = pendingText.index(after: index)
    }
    pendingText = String(pendingText[startIndex...])
    if flush, !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sentences.append(pendingText.trimmingCharacters(in: .whitespacesAndNewlines))
      pendingText = ""
    }
    guard !sentences.isEmpty else { return }
    ttsQueue.append(contentsOf: sentences)
    pumpTTS()
  }

  private func pumpTTS() {
    guard running, ttsTask == nil else { return }
    ttsTask = Task { [weak self] in
      guard let self else { return }
      let client = APIClient(origin: self.settings.origin, apiKey: self.settings.apiKey)
      let voice = self.settings.ttsVoice
      while self.running, !Task.isCancelled, !self.ttsQueue.isEmpty {
        let sentence = self.ttsQueue.removeFirst()
        self.status = .speaking
        DLog.log("tts sentence: \(sentence)")
        do {
          for try await chunk in client.synthesize(text: sentence, voice: voice) {
            if Task.isCancelled { return }
            self.schedulePlayback(chunk)
          }
        } catch {
          if !Task.isCancelled {
            DLog.log("tts failed: \(error)")
            self.fail(error)
          }
          return
        }
      }
      self.ttsTask = nil
      self.maybeFinishTurn()
    }
  }

  private func schedulePlayback(_ data: Data) {
    let frameCount = data.count / 2
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else { return }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    guard let channel = buffer.floatChannelData?[0] else { return }
    // 固定播放增益：手机媒体音量偏低时也能听清（超过 ±1 的软限幅）
    let gain = 1.8
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      for index in 0..<frameCount {
        let low = UInt16(bytes[index * 2])
        let high = UInt16(bytes[index * 2 + 1])
        let sample = Float(Int16(bitPattern: low | (high << 8))) / 32_768 * Float(gain)
        channel[index] = max(-1, min(1, sample))
      }
    }
    player.scheduleBuffer(buffer, completionHandler: nil)
    if !player.isPlaying { player.play() }
    let duration = Double(frameCount) / 24_000
    let now = Date().timeIntervalSince1970
    audioClock = max(now, audioClock) + duration
  }

  private func handleTurnFrame(_ rms: Double) {
    let playing = Date().timeIntervalSince1970 < audioClock + 0.4
    let threshold = playing ? bargeThreshold : max(noiseFloor * 2.5, speechThreshold)
    if rms > threshold {
      bargeMs += frameMs
      if bargeMs >= 320 {
        interrupt()
      }
    } else {
      bargeMs = max(0, bargeMs - frameMs)
    }
  }

  private func maybeFinishTurn() {
    guard running, turnActive else { return }
    guard generationDone, ttsTask == nil, ttsQueue.isEmpty else { return }
    let remaining = audioClock + 0.3 - Date().timeIntervalSince1970
    turnEndTask?.cancel()
    if remaining > 0 {
      turnEndTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.maybeFinishTurn() }
      }
      return
    }
    finishTurn()
  }

  private func finishTurn() {
    turnEndTask?.cancel()
    turnEndTask = nil
    turnActive = false
    bargeMs = 0
    resetVad()
    guard running else { return }
    status = .listening
    level = 0
  }

  private func abortTurn() {
    ttsTask?.cancel()
    ttsTask = nil
    chatTask?.cancel()
    chatTask = nil
    asrTask?.cancel()
    asrTask = nil
    turnEndTask?.cancel()
    turnEndTask = nil
    ttsQueue.removeAll()
    player.stop()
    player.play()
    if store.isStreaming { store.stop() }
    turnActive = false
    generationDone = true
    resetVad()
  }

  private func fail(_ error: Error) {
    DLog.log("voice fail: \(error)")
    abortTurn()
    guard running else { return }
    errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    status = .listening
  }

  // MARK: - 工具

  nonisolated private static func rms(of samples: [Int16]) -> Double {
    guard !samples.isEmpty else { return 0 }
    var sum = 0.0
    for sample in samples {
      let value = Double(sample) / 32_768
      sum += value * value
    }
    return (sum / Double(samples.count)).squareRoot()
  }

  /// 16-bit 单声道 WAV；录音偏小时做峰值归一化，避免 ASR 听不清
  nonisolated static func makeWAV(samples rawSamples: [Int16], sampleRate: Int) -> Data {
    var samples = rawSamples
    var peak = 0
    for sample in samples {
      peak = max(peak, abs(Int(sample)))
    }
    if peak > 0, peak < 24_000 {
      let gain = min(6.0, 24_000.0 / Double(peak))
      for index in samples.indices {
        samples[index] = Int16(clamping: Int(Double(samples[index]) * gain))
      }
    }
    var data = Data()
    let byteCount = samples.count * 2
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    append32(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * 2))
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(UInt32(byteCount))
    for sample in samples {
      append16(UInt16(bitPattern: sample))
    }
    return data
  }
}
