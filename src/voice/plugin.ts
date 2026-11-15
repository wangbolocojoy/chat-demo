import { registerPlugin, type PluginListenerHandle } from '@capacitor/core'

export type { PluginListenerHandle }

/**
 * iOS 原生全双工音频通道（见 ios/App/CapApp-SPM/Sources/CapApp-SPM/VoiceDuplexPlugin.swift）。
 * 麦克风 16 kHz PCM 按 32 ms 一包推送，TTS 的 24 kHz PCM 排队播放。
 */
export interface VoiceDuplexPlugin {
  /** 建立通话级音频会话（AVAudioSession .voiceChat，带硬件回声消除） */
  start(): Promise<{ sampleRate: number; outputSampleRate: number }>
  stop(): Promise<void>
  /** 播放一段 24 kHz、16-bit 单声道 PCM */
  play(options: { pcm: string }): Promise<void>
  /** 立即丢弃尚未播放的音频（打断） */
  flush(): Promise<void>
  setMuted(options: { muted: boolean }): Promise<{ muted: boolean }>
  setSpeaker(options: { speaker: boolean }): Promise<void>
  getStatus(): Promise<{ running: boolean; muted: boolean; playing: boolean }>
  addListener(
    eventName: 'audio',
    listener: (event: { pcm: string }) => void
  ): Promise<PluginListenerHandle>
  addListener(
    eventName: 'interrupted' | 'resumed',
    listener: () => void
  ): Promise<PluginListenerHandle>
  removeAllListeners(): Promise<void>
}

export const VoiceDuplex = registerPlugin<VoiceDuplexPlugin>('VoiceDuplex')
