import { createRoot } from 'react-dom/client'
import { App } from './app/App.js'
import { setupTheme } from './app/theme.js'
import './native/native.css'
import { setupNativeShell } from './native/index.js'
import { ensureKatex } from './services/markdown/katex.js'
import './app/theme.css'
import './app/global.css'

ensureKatex()
setupTheme()
// 原生容器（iOS App）里补齐安全区、状态栏和启动图，浏览器里是空操作
setupNativeShell()

createRoot(document.getElementById('root') as HTMLElement).render(<App />)
