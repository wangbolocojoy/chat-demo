/**
 * iOS 原生外壳的初始化。
 *
 * 只在 Capacitor 原生容器里生效；浏览器打开时整个模块是空操作，
 * 因此 Web 版的行为保持不变。
 */
import { Capacitor } from '@capacitor/core'

export const isNativeApp = Capacitor.isNativePlatform()

/**
 * 让页面铺满整个屏幕：viewport-fit=cover 之后 env(safe-area-inset-*) 才会有非零值，
 * 再由 native.css 把安全区换算成 --native-safe-* 变量交给布局使用。
 */
const applyNativeLayout = () => {
  const meta = document.querySelector('meta[name="viewport"]')
  if (meta) {
    meta.setAttribute('content', 'width=device-width,initial-scale=1,viewport-fit=cover')
  }
  document.documentElement.classList.add('capacitor-native')
}

/** 状态栏文字跟随页面主题：深色背景用浅色文字，浅色背景用深色文字 */
const watchStatusBar = async () => {
  const { StatusBar, Style } = await import('@capacitor/status-bar')
  await StatusBar.setOverlaysWebView({ overlay: true })
  const sync = () => {
    const dark = document.body.classList.contains('dark')
    void StatusBar.setStyle({ style: dark ? Style.Dark : Style.Light }).catch(() => {})
  }
  sync()
  new MutationObserver(sync).observe(document.body, {
    attributes: true,
    attributeFilter: ['class'],
  })
}

/**
 * 键盘弹出时由原生收缩 WebView，此时屏幕底部的安全区已经被键盘盖住，
 * 需要把预留的底部安全区去掉，否则输入框上方会多出一条空隙。
 */
const watchKeyboard = async () => {
  const { Keyboard } = await import('@capacitor/keyboard')
  const root = document.documentElement
  await Keyboard.addListener('keyboardWillShow', () => root.classList.add('keyboard-open'))
  await Keyboard.addListener('keyboardWillHide', () => root.classList.remove('keyboard-open'))
}

/**
 * 外链用 App 内的 Safari 视图打开，而不是把用户送去 Safari 或让 WebView 自己跳走。
 * 聊天气泡里的引用链接默认是 target="_blank"，原生容器会把它交给系统打开，体验很割裂。
 */
const interceptExternalLinks = async () => {
  const { Browser } = await import('@capacitor/browser')
  document.addEventListener(
    'click',
    (event) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey) {
        return
      }
      const anchor = event.target instanceof Element ? event.target.closest('a[href]') : null
      if (!(anchor instanceof HTMLAnchorElement)) {
        return
      }
      const href = anchor.href
      if (!/^https?:/i.test(href)) {
        return
      }
      // 页内同源跳转保持原行为
      try {
        if (new URL(href).origin === location.origin) {
          return
        }
      } catch {
        return
      }
      event.preventDefault()
      void Browser.open({ url: href }).catch(() => {})
    },
    true
  )
}

/** 等首屏渲染出来再收启动图，避免白闪 */
const hideSplash = async () => {
  const { SplashScreen } = await import('@capacitor/splash-screen')
  requestAnimationFrame(() => {
    requestAnimationFrame(() => {
      setTimeout(() => void SplashScreen.hide().catch(() => {}), 80)
    })
  })
}

export const setupNativeShell = () => {
  if (!isNativeApp) {
    return
  }
  applyNativeLayout()
  void watchStatusBar()
  void watchKeyboard()
  void interceptExternalLinks()
  void hideSplash()
}
