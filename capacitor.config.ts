import type { CapacitorConfig } from '@capacitor/cli'

const config: CapacitorConfig = {
  appId: 'com.aicd.deepseekchat',
  appName: 'DeepSeek Chat',
  webDir: 'dist',
  ios: {
    // 页面自己处理安全区（env(safe-area-inset-*) + 100dvh），这里不要再去调整滚动视图
    contentInset: 'never',
    backgroundColor: '#ffffff',
    // 移动端布局默认就给 mobile，避免按桌面宽度渲染
    preferredContentMode: 'mobile',
    // 允许 WebView 缩放（可选，留 false 更像原生 App）
    zoomEnabled: false,
  },
  plugins: {
    SplashScreen: {
      launchAutoHide: false,
      backgroundColor: '#ffffff',
      showSpinner: false,
    },
    Keyboard: {
      // WebView 自己处理输入框滚动，键盘只把页面顶上来
      resize: 'native',
    },
    StatusBar: {
      style: 'DEFAULT',
      // 页面自己把内容放在安全区里，状态栏背景直接透出页面底色（深浅色都跟着变）
      overlaysWebView: true,
    },
  },
}

export default config
