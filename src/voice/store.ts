import { create } from 'zustand'
import type { TranslationKey } from '../i18n/index.js'

/**
 * 全双工语音通话的界面状态。
 * idle：未开始；starting：建立音频通道；listening：在听；thinking：等识别 / 等回答；
 * speaking：正在朗读回答（此时也能被打断）
 */
export type VoiceCallStatus = 'idle' | 'starting' | 'listening' | 'thinking' | 'speaking'

type VoiceCallState = {
  open: boolean
  status: VoiceCallStatus
  /** 麦克风音量 0..1，驱动光球的呼吸 */
  level: number
  muted: boolean
  /** 最近一句识别结果 */
  userText: string
  /** 当前回答的实时文本 */
  assistantText: string
  /** 出错时展示的文案 key，恢复倾听后清空 */
  errorKey: TranslationKey | null
}

export const useVoiceCall = create<VoiceCallState>(() => ({
  open: false,
  status: 'idle',
  level: 0,
  muted: false,
  userText: '',
  assistantText: '',
  errorKey: null,
}))

export const resetVoiceCall = () => {
  useVoiceCall.setState({
    open: false,
    status: 'idle',
    level: 0,
    muted: false,
    userText: '',
    assistantText: '',
    errorKey: null,
  })
}
