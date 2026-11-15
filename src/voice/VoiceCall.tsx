import { useEffect } from 'react'
import { IconCloseOutline16, IconMicOutline16 } from '../components/base/icons.js'
import { isNativeApp } from '../native/index.js'
import { useTranslate } from '../i18n/index.js'
import {
  interruptVoiceCall,
  setVoiceCallMuted,
  startVoiceCall,
  stopVoiceCall,
} from './engine.js'
import { IconCallEnd16, IconMicOffOutline16 } from './icons.js'
import { useVoiceCall } from './store.js'
import styles from './VoiceCall.module.css'

/** 全屏语音通话界面：光球显示音量，点光球可以打断朗读 */
export const VoiceCall = () => {
  const t = useTranslate()
  const open = useVoiceCall((state) => state.open)
  const status = useVoiceCall((state) => state.status)
  const level = useVoiceCall((state) => state.level)
  const muted = useVoiceCall((state) => state.muted)
  const userText = useVoiceCall((state) => state.userText)
  const assistantText = useVoiceCall((state) => state.assistantText)
  const errorKey = useVoiceCall((state) => state.errorKey)

  // 通话期间禁止页面滚动，避免顶栏跟着动
  useEffect(() => {
    if (!open) {
      return
    }
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = previous
    }
  }, [open])

  if (!open) {
    return null
  }

  const statusText = {
    starting: t('voiceCallConnecting'),
    idle: t('voiceCallConnecting'),
    listening: muted ? t('voiceCallMuted') : t('voiceCallListening'),
    thinking: t('voiceCallThinking'),
    speaking: t('voiceCallSpeaking'),
  }[status]

  return (
    <div className={styles.root} role="dialog" aria-modal="true" aria-label={t('voiceCallTitle')}>
      <div className={styles.header}>
        <button
          type="button"
          className={styles.headerButton}
          aria-label={t('voiceCallClose')}
          onClick={() => void stopVoiceCall()}
        >
          <IconCloseOutline16 />
        </button>
        <div className={styles.title}>{t('voiceCallTitle')}</div>
        <span className={styles.headerButton} aria-hidden />
      </div>

      <div className={styles.stage}>
        <div
          className={styles.orb}
          style={{ ['--level' as string]: level.toFixed(3) }}
          onClick={() => {
            if (status === 'speaking') {
              interruptVoiceCall()
            }
          }}
          role="button"
          aria-label={status === 'speaking' ? t('voiceCallInterrupt') : t('voiceCallTitle')}
        >
          <span className={styles.orbCore} />
        </div>
        <div className={styles.status}>{statusText}</div>
        {errorKey ? <div className={styles.error}>{t(errorKey)}</div> : null}
        <div className={styles.hint}>{t('voiceCallHint')}</div>
      </div>

      {userText || assistantText ? (
        <div className={styles.captions}>
          {userText ? (
            <div className={styles.caption}>
              <div className={styles.captionLabel}>{t('voiceCallYou')}</div>
              <div className={styles.captionText}>{userText}</div>
            </div>
          ) : null}
          {assistantText ? (
            <div className={styles.caption}>
              <div className={styles.captionLabel}>{t('voiceCallAssistant')}</div>
              <div className={`${styles.captionText} ${styles.captionTextAssistant}`}>
                {assistantText}
              </div>
            </div>
          ) : null}
        </div>
      ) : null}

      <div className={styles.footer}>
        <button
          type="button"
          className={`${styles.circleButton} ${muted ? styles.circleButtonActive : ''}`}
          aria-label={muted ? t('voiceCallUnmute') : t('voiceCallMute')}
          onClick={() => setVoiceCallMuted(!muted)}
        >
          {muted ? <IconMicOffOutline16 /> : <IconMicOutline16 />}
        </button>
        <button
          type="button"
          className={`${styles.circleButton} ${styles.endButton}`}
          aria-label={t('voiceCallEnd')}
          onClick={() => void stopVoiceCall()}
        >
          <IconCallEnd16 />
        </button>
      </div>
    </div>
  )
}

/** 输入框上的入口：只有原生 App 里才提供全双工语音 */
export const startVoiceCallFromUi = () => {
  if (!isNativeApp) {
    return
  }
  void startVoiceCall()
}
