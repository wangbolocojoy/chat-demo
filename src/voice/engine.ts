import type { TranslationKey } from '../i18n/index.js'
import { isNativeApp } from '../native/index.js'
import { classifyApiError } from '../services/api/errors.js'
import { synthesize, transcribe } from '../services/api/speech.js'
import { getVisibleMessages } from '../services/chat/branches.js'
import { setDraftText } from '../services/chat/drafts.js'
import { sendMessage, stopReply, useChatStore } from '../services/chat/store.js'
import type { TextPart } from '../services/chat/types.js'
import { useSettings } from '../services/settings.js'
import { stopReadAloud } from '../services/speech/readAloud.js'
import { VoiceDuplex, type PluginListenerHandle } from './plugin.js'
import { resetVoiceCall, useVoiceCall } from './store.js'

/** 麦克风采样率（与原生插件约定） */
const INPUT_RATE = 16_000
/** TTS 输出采样率（与官方接口一致） */
const TTS_RATE = 24_000
/** 每包 32 ms，和原生插件的 chunkSamples 一致 */
const FRAME_MS = 32
/** 保留说话前的音频，避免吞掉第一个字 */
const PRE_ROLL_MS = 300
/** 连续这么久的能量才算开口 */
const SPEECH_START_MS = 128
/** 停顿这么久算一句话说完 */
const SILENCE_END_MS = 700
/** 回答期间持续这么久的人声才判定为打断，避免环境噪音误触发 */
const BARGE_IN_MS = 320
/** 单句最长时长，防止一口气说不完卡住 */
const MAX_UTTERANCE_MS = 45_000
/** 朗读时允许打断的能量阈值（硬件回声消除之后，自己声音的残留应低于它） */
const BARGE_IN_THRESHOLD = 0.032
/** 安静时的开口阈值 */
const SPEECH_THRESHOLD = 0.012

const now = () => performance.now() / 1000

const decodePcm = (base64: string): Int16Array => {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index)
  }
  return new Int16Array(bytes.buffer, 0, bytes.length >> 1)
}

const rmsOf = (samples: Int16Array): number => {
  if (samples.length === 0) {
    return 0
  }
  let sum = 0
  for (let index = 0; index < samples.length; index++) {
    const value = samples[index] / 32_768
    sum += value * value
  }
  return Math.sqrt(sum / samples.length)
}

/** 把若干段 Int16 PCM 拼成 16 kHz 单声道 WAV，交给 ASR 接口 */
const toWav = (chunks: Int16Array[]): Blob => {
  const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0)
  const buffer = new ArrayBuffer(44 + length * 2)
  const view = new DataView(buffer)
  const writeText = (offset: number, text: string) => {
    for (let index = 0; index < text.length; index++) {
      view.setUint8(offset + index, text.charCodeAt(index))
    }
  }
  writeText(0, 'RIFF')
  view.setUint32(4, 36 + length * 2, true)
  writeText(8, 'WAVE')
  writeText(12, 'fmt ')
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, INPUT_RATE, true)
  view.setUint32(28, INPUT_RATE * 2, true)
  view.setUint16(32, 2, true)
  view.setUint16(34, 16, true)
  writeText(36, 'data')
  view.setUint32(40, length * 2, true)
  const pcm = new Int16Array(buffer, 44)
  let offset = 0
  for (const chunk of chunks) {
    pcm.set(chunk, offset)
    offset += chunk.length
  }
  return new Blob([buffer], { type: 'audio/wav' })
}

const TERMINATORS = '。！？!?；;\n'
const SOFT_BREAKS = '，,、'

/** 从模型正文里切出可以马上朗读的句子，剩余部分留在缓冲区 */
const takeSentences = (text: string, flush: boolean): { sentences: string[]; rest: string } => {
  const sentences: string[] = []
  let start = 0
  for (let index = 0; index < text.length; index++) {
    const char = text[index]
    const hard = TERMINATORS.includes(char)
    const soft = SOFT_BREAKS.includes(char) && index - start >= 48
    if (!hard && !soft) {
      continue
    }
    const sentence = text.slice(start, index + 1).trim()
    if (sentence) {
      sentences.push(sentence)
    }
    start = index + 1
  }
  let rest = text.slice(start)
  if (flush && rest.trim()) {
    sentences.push(rest.trim())
    rest = ''
  }
  return { sentences, rest }
}

const lastAssistantText = (sessionId: string): string => {
  const session = useChatStore.getState().sessionCache[sessionId]
  if (!session) {
    return ''
  }
  const messages = getVisibleMessages(session)
  const last = messages[messages.length - 1]
  if (!last || last.role !== 'assistant') {
    return ''
  }
  return last.blocks
    .filter((block): block is TextPart => block.type === 'text')
    .map((block) => block.text)
    .join('')
}

const isReplyFinished = (sessionId: string): boolean => {
  const session = useChatStore.getState().sessionCache[sessionId]
  if (!session) {
    return false
  }
  const messages = getVisibleMessages(session)
  const last = messages[messages.length - 1]
  if (!last || last.role !== 'assistant') {
    return true
  }
  return last.status === 'done' || last.status === 'stopped' || last.status === 'error'
}

const errorKeyOf = (error: unknown): TranslationKey => {
  switch (classifyApiError(error)) {
    case 'unauthorized':
      return 'apiKeyInvalidRetry'
    case 'insufficientBalance':
      return 'insufficientBalance'
    case 'rateLimited':
      return 'rateLimited'
    case 'network':
      return 'voiceCallNetwork'
    default:
      return 'voiceCallFailed'
  }
}

class VoiceCallEngine {
  private running = false
  private handles: PluginListenerHandle[] = []
  private unsubChat: (() => void) | null = null

  // —— VAD 状态 ——
  private capturing = false
  private speechMs = 0
  private silenceMs = 0
  private preRoll: Int16Array[] = []
  private preRollMs = 0
  private utterance: Int16Array[] = []
  private utteranceMs = 0
  private noiseFloor = 0.005
  private lastLevelAt = 0

  // —— 回答回合状态 ——
  private turnActive = false
  private bargeMs = 0
  private sessionId: string | null = null
  private seenText = ''
  private pendingText = ''
  private generationDone = true
  private ttsQueue: string[] = []
  private ttsBusy = false
  private ttsControllers = new Set<AbortController>()
  private asrController: AbortController | null = null
  private audioClock = 0
  private turnEndTimer: number | null = null

  get active() {
    return this.running
  }

  async start() {
    if (this.running) {
      return
    }
    if (!isNativeApp) {
      useVoiceCall.setState({ errorKey: 'voiceCallUnsupported' })
      return
    }
    if (!useSettings.getState().apiKey) {
      useVoiceCall.setState({ errorKey: 'voiceCallNeedApiKey' })
      return
    }
    resetVoiceCall()
    useVoiceCall.setState({ open: true, status: 'starting' })
    stopReadAloud()

    try {
      await VoiceDuplex.start()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      useVoiceCall.setState({
        open: false,
        status: 'idle',
        errorKey: message.includes('permission') ? 'voiceCallNoMic' : 'voiceCallFailed',
      })
      return
    }

    this.running = true
    this.handles.push(
      await VoiceDuplex.addListener('audio', ({ pcm }) => this.onFrame(decodePcm(pcm))),
      await VoiceDuplex.addListener('interrupted', () => this.fail('voiceCallFailed')),
      await VoiceDuplex.addListener('resumed', () => undefined)
    )
    this.resetVad()
    useVoiceCall.setState({ status: 'listening', errorKey: null })
  }

  async stop() {
    if (!this.running) {
      resetVoiceCall()
      return
    }
    this.running = false
    this.abortTurn()
    this.unsubChat?.()
    this.unsubChat = null
    this.clearTurnTimer()
    for (const handle of this.handles) {
      void handle.remove()
    }
    this.handles = []
    try {
      await VoiceDuplex.removeAllListeners()
      await VoiceDuplex.stop()
    } catch {
      // 音频通道已经释放
    }
    resetVoiceCall()
  }

  setMuted(muted: boolean) {
    void VoiceDuplex.setMuted({ muted })
    useVoiceCall.setState({ muted })
  }

  /** 手动打断：停止朗读和生成，回到倾听 */
  interrupt() {
    if (!this.running) {
      return
    }
    this.abortTurn()
    useVoiceCall.setState({ status: 'listening' })
  }

  // —— 音频帧入口 ——

  private onFrame(samples: Int16Array) {
    if (!this.running || samples.length === 0) {
      return
    }
    const rms = rmsOf(samples)
    this.updateLevel(rms)

    // 自适应底噪：安静时慢慢跟，避免把风声/空调声当成说话
    if (!this.capturing && rms < this.noiseFloor * 2) {
      this.noiseFloor = this.noiseFloor * 0.97 + rms * 0.03
    }
    this.pushPreRoll(samples, FRAME_MS)

    if (this.turnActive) {
      this.onTurnFrame(rms)
      return
    }
    this.onListenFrame(samples, rms)
  }

  private updateLevel(rms: number) {
    const timestamp = now()
    if (timestamp - this.lastLevelAt < 0.05) {
      return
    }
    this.lastLevelAt = timestamp
    useVoiceCall.setState({ level: Math.min(1, rms * 9) })
  }

  private pushPreRoll(samples: Int16Array, ms: number) {
    this.preRoll.push(samples)
    this.preRollMs += ms
    while (this.preRollMs > PRE_ROLL_MS && this.preRoll.length > 1) {
      const dropped = this.preRoll.shift()
      this.preRollMs -= dropped ? (dropped.length / INPUT_RATE) * 1000 : FRAME_MS
    }
  }

  private resetVad() {
    this.capturing = false
    this.speechMs = 0
    this.silenceMs = 0
    this.preRoll = []
    this.preRollMs = 0
    this.utterance = []
    this.utteranceMs = 0
    this.bargeMs = 0
  }

  // —— 倾听状态：检测一句话的开始与结束 ——

  private onListenFrame(samples: Int16Array, rms: number) {
    const speakingNow = rms > Math.max(this.noiseFloor * 2.5, SPEECH_THRESHOLD)
    if (!this.capturing) {
      if (speakingNow) {
        this.speechMs += FRAME_MS
        if (this.speechMs >= SPEECH_START_MS) {
          this.startUtterance()
        }
      } else {
        this.speechMs = Math.max(0, this.speechMs - FRAME_MS)
      }
      return
    }

    this.utterance.push(samples)
    this.utteranceMs += FRAME_MS
    if (speakingNow) {
      this.silenceMs = 0
    } else {
      this.silenceMs += FRAME_MS
    }
    if (this.silenceMs >= SILENCE_END_MS || this.utteranceMs >= MAX_UTTERANCE_MS) {
      this.finishUtterance()
    }
  }

  private startUtterance() {
    this.capturing = true
    this.utterance = [...this.preRoll]
    this.utteranceMs = this.preRollMs
    this.silenceMs = 0
    this.speechMs = 0
    useVoiceCall.setState({ status: 'listening', userText: '' })
  }

  private finishUtterance() {
    const chunks = this.utterance
    const durationMs = this.utteranceMs
    this.resetVad()
    if (durationMs < 320) {
      return
    }
    void this.handleUtterance(toWav(chunks))
  }

  // —— 回答回合：边播边等，随时可以被打断 ——

  private onTurnFrame(rms: number) {
    const playing = now() < this.audioClock + 0.4
    const threshold = playing ? BARGE_IN_THRESHOLD : Math.max(this.noiseFloor * 2.5, SPEECH_THRESHOLD)
    if (rms > threshold) {
      this.bargeMs += FRAME_MS
      if (this.bargeMs >= BARGE_IN_MS) {
        this.interrupt()
      }
    } else {
      this.bargeMs = Math.max(0, this.bargeMs - FRAME_MS)
    }
  }

  private async handleUtterance(wav: Blob) {
    this.turnActive = true
    this.bargeMs = 0
    useVoiceCall.setState({ status: 'thinking' })

    const apiKey = useSettings.getState().apiKey ?? ''
    const controller = new AbortController()
    this.asrController = controller
    try {
      const text = (await transcribe(apiKey, wav, controller.signal)).trim()
      if (!this.running || controller.signal.aborted) {
        return
      }
      if (!text) {
        this.abortTurn()
        useVoiceCall.setState({ status: 'listening', errorKey: 'voiceCallEmpty' })
        return
      }
      useVoiceCall.setState({ userText: text, assistantText: '', errorKey: null })
      this.sendToChat(text)
    } catch (error) {
      if (!controller.signal.aborted) {
        this.fail(errorKeyOf(error))
      }
    }
  }

  private sendToChat(text: string) {
    const state = useChatStore.getState()
    const activeId = state.activeId
    if (activeId) {
      stopReply(activeId)
    }
    setDraftText(activeId, text)
    if (!sendMessage(activeId)) {
      this.fail('voiceCallFailed')
      return
    }
    this.sessionId = useChatStore.getState().activeId
    this.seenText = ''
    this.pendingText = ''
    this.generationDone = false
    this.ttsQueue = []
    this.audioClock = now()
    this.unsubChat?.()
    this.unsubChat = useChatStore.subscribe(this.syncChat)
    this.syncChat()
  }

  /** 跟随会话里的回答增量：切句 → 排队朗读 */
  private syncChat = () => {
    const sessionId = this.sessionId
    if (!this.running || !sessionId) {
      return
    }
    const text = lastAssistantText(sessionId)
    if (text.length > this.seenText.length) {
      this.pendingText += text.slice(this.seenText.length)
      this.seenText = text
      useVoiceCall.setState({ assistantText: text })
      this.drainSentences(false)
    }
    if (!this.generationDone && isReplyFinished(sessionId)) {
      this.generationDone = true
      this.drainSentences(true)
      this.scheduleTurnEnd()
    }
  }

  private drainSentences(flush: boolean) {
    const { sentences, rest } = takeSentences(this.pendingText, flush)
    this.pendingText = rest
    for (const sentence of sentences) {
      this.ttsQueue.push(sentence)
    }
    void this.pumpTts()
  }

  private async pumpTts() {
    if (!this.running || this.ttsBusy) {
      return
    }
    const next = this.ttsQueue.shift()
    if (!next) {
      this.scheduleTurnEnd()
      return
    }
    this.ttsBusy = true
    const controller = new AbortController()
    this.ttsControllers.add(controller)
    useVoiceCall.setState({ status: 'speaking' })

    try {
      const { apiKey, ttsVoice } = useSettings.getState()
      const stream = await synthesize(apiKey ?? '', next, ttsVoice, controller.signal)
      const reader = stream.getReader()
      controller.signal.addEventListener('abort', () => void reader.cancel().catch(() => {}))
      let rest = new Uint8Array(0)
      for (;;) {
        const { done, value } = await reader.read()
        if (done || !this.running) {
          break
        }
        const bytes = new Uint8Array(rest.length + value.length)
        bytes.set(rest)
        bytes.set(value, rest.length)
        // PCM 是 16-bit 小端，奇数字节留到下一包
        const usable = bytes.length - (bytes.length % 2)
        rest = bytes.slice(usable)
        if (usable === 0) {
          continue
        }
        this.enqueueAudio(bytes.subarray(0, usable))
      }
    } catch (error) {
      if (!controller.signal.aborted) {
        this.fail(errorKeyOf(error))
        return
      }
    } finally {
      this.ttsBusy = false
      this.ttsControllers.delete(controller)
      if (this.running) {
        if (this.ttsQueue.length > 0) {
          void this.pumpTts()
        } else {
          this.scheduleTurnEnd()
        }
      }
    }
  }

  private enqueueAudio(bytes: Uint8Array) {
    let binary = ''
    for (let index = 0; index < bytes.length; index++) {
      binary += String.fromCharCode(bytes[index])
    }
    const duration = bytes.length / 2 / TTS_RATE
    this.audioClock = Math.max(now(), this.audioClock) + duration
    void VoiceDuplex.play({ pcm: btoa(binary) }).catch(() => {})
  }

  private scheduleTurnEnd() {
    if (!this.running || !this.turnActive) {
      return
    }
    this.clearTurnTimer()
    const wait = Math.max(0, this.audioClock - now() + 0.35) * 1000
    this.turnEndTimer = window.setTimeout(() => this.finishTurnIfIdle(), wait)
  }

  private finishTurnIfIdle() {
    if (!this.running || !this.turnActive) {
      return
    }
    if (!this.generationDone || this.ttsBusy || this.ttsQueue.length > 0) {
      return
    }
    if (now() < this.audioClock + 0.3) {
      this.scheduleTurnEnd()
      return
    }
    this.finishTurn()
  }

  private finishTurn() {
    this.clearTurnTimer()
    this.turnActive = false
    this.bargeMs = 0
    if (!this.running) {
      return
    }
    useVoiceCall.setState({ status: 'listening', level: 0 })
    this.resetVad()
  }

  private clearTurnTimer() {
    if (this.turnEndTimer !== null) {
      window.clearTimeout(this.turnEndTimer)
      this.turnEndTimer = null
    }
  }

  /** 结束当前回合：丢弃朗读、停止生成，回到倾听 */
  private abortTurn() {
    this.clearTurnTimer()
    this.asrController?.abort()
    this.asrController = null
    for (const controller of this.ttsControllers) {
      controller.abort()
    }
    this.ttsControllers.clear()
    this.ttsBusy = false
    this.ttsQueue = []
    this.unsubChat?.()
    this.unsubChat = null
    if (this.sessionId) {
      stopReply(this.sessionId)
    }
    void VoiceDuplex.flush().catch(() => {})
    this.turnActive = false
    this.generationDone = true
    this.resetVad()
  }

  private fail(errorKey: TranslationKey) {
    this.abortTurn()
    if (!this.running) {
      return
    }
    useVoiceCall.setState({ status: 'listening', errorKey })
    window.setTimeout(() => {
      if (this.running && useVoiceCall.getState().errorKey === errorKey) {
        useVoiceCall.setState({ errorKey: null })
      }
    }, 3500)
  }
}

const engine = new VoiceCallEngine()

export const startVoiceCall = () => engine.start()
export const stopVoiceCall = () => engine.stop()
export const interruptVoiceCall = () => engine.interrupt()
export const setVoiceCallMuted = (muted: boolean) => engine.setMuted(muted)
export const isVoiceCallActive = () => engine.active
