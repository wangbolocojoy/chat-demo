import AVFoundation
import Capacitor
import Foundation

/// 全双工语音的通话音频通道。
///
/// 网页里的 getUserMedia 拿不到 iOS 的「通话」音频会话：麦克风和播放会抢路由，
/// 也没有硬件回声消除。这里用 AVAudioEngine 起一个 `.voiceChat` 会话：
/// - 输入：VAD 需要的 16 kHz 单声道 PCM，按 32 ms 一包发给 JS
/// - 输出：JS 传来的 24 kHz PCM 排队播放，可随时 flush 打断
/// - 通话模式自带回声消除和默认扬声器，适合边听边说
@objc(VoiceDuplexPlugin)
public class VoiceDuplexPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "VoiceDuplexPlugin"
    public let jsName = "VoiceDuplex"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "flush", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSpeaker", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getStatus", returnType: CAPPluginReturnPromise)
    ]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var pending = Data()
    private var running = false
    private var muted = false
    private var playerAttached = false
    private let chunkSamples = 512

    // MARK: - 生命周期

    override public func load() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        teardown()
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }
        if type == .began {
            notifyListeners("interrupted", data: nil)
        } else if type == .ended, running {
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                if !player.isPlaying {
                    player.play()
                }
                notifyListeners("resumed", data: nil)
            } catch {
                CAPLog.print("⚡️ VoiceDuplex: 恢复音频会话失败 \(error)")
            }
        }
    }

    // MARK: - 插件方法

    @objc func start(_ call: CAPPluginCall) {
        requestMicrophone { [weak self] granted in
            guard let self else {
                return
            }
            guard granted else {
                call.reject("permission_denied")
                return
            }
            do {
                try self.startEngine()
                call.resolve(["sampleRate": 16_000, "outputSampleRate": 24_000])
            } catch {
                call.reject("audio_start_failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        teardown()
        call.resolve()
    }

    @objc func play(_ call: CAPPluginCall) {
        guard
            let base64 = call.getString("pcm"),
            let data = Data(base64Encoded: base64),
            data.count >= 2
        else {
            call.reject("invalid_pcm")
            return
        }
        guard running else {
            call.resolve()
            return
        }
        let frames = data.count / 2
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(frames)
            )
        else {
            call.reject("buffer_alloc_failed")
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                channel[index] = Float(samples[index]) / 32_768
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
        call.resolve()
    }

    @objc func flush(_ call: CAPPluginCall) {
        if running {
            player.stop()
            player.play()
        }
        call.resolve()
    }

    @objc func setMuted(_ call: CAPPluginCall) {
        muted = call.getBool("muted") ?? false
        call.resolve(["muted": muted])
    }

    /// 扬声器 / 听筒切换，默认外放
    @objc func setSpeaker(_ call: CAPPluginCall) {
        let speaker = call.getBool("speaker") ?? true
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
            call.resolve()
        } catch {
            call.reject("override_output_failed: \(error.localizedDescription)")
        }
    }

    @objc func getStatus(_ call: CAPPluginCall) {
        call.resolve(["running": running, "muted": muted, "playing": player.isPlaying])
    }

    // MARK: - 音频引擎

    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        let respond: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                respond(true)
            case .denied:
                respond(false)
            case .undetermined:
                AVAudioApplication.requestRecordPermission { respond($0) }
            @unknown default:
                respond(false)
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                respond(true)
            case .denied:
                respond(false)
            case .undetermined:
                session.requestRecordPermission { respond($0) }
            @unknown default:
                respond(false)
            }
        }
    }

    private func startEngine() throws {
        if running {
            return
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        // 通话模式下系统会做回声消除，扬声器外放时 mic 不会一直把 TTS 当人声
        try session.setActive(true, options: [])

        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hardwareFormat, to: inputFormat) else {
            throw NSError(
                domain: "VoiceDuplex",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法重采样麦克风音频"]
            )
        }
        self.converter = converter
        pending.removeAll(keepingCapacity: true)

        input.installTap(onBus: 0, bufferSize: 1_024, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }

        engine.prepare()
        try engine.start()
        player.play()
        running = true
        muted = false
    }

    private func teardown() {
        guard running else {
            return
        }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if playerAttached {
            engine.detach(player)
            playerAttached = false
        }
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        pending.removeAll()
    }

    /// 把硬件采样率转成 16 kHz / Int16，攒满一个包就发给 JS
    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard running, let converter else {
            return
        }
        let ratio = inputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard
            let converted = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity)
        else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else {
            return
        }

        let frames = Int(converted.frameLength)
        let byteCount = frames * MemoryLayout<Int16>.size
        guard let samples = converted.int16ChannelData?[0] else {
            return
        }
        pending.append(Data(bytes: samples, count: byteCount))

        let chunkBytes = chunkSamples * MemoryLayout<Int16>.size
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            guard !muted else {
                continue
            }
            let base64 = chunk.base64EncodedString()
            // 音频线程里不做桥接调用，切到主线程再发给 JS
            DispatchQueue.main.async { [weak self] in
                self?.notifyListeners("audio", data: ["pcm": base64])
            }
        }
    }
}
