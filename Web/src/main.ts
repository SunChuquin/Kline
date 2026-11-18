import { createApp } from 'vue'
import App from './App.vue'
import { klineBus } from './bridge/klineBus'
import './styles/theme.css'

// 全局 JS 异常回报（桥接排障通道）：页面侧任何脚本异常 → Swift debug_log。
// 请求响应本身可能不通（正是排障对象），故只要求 postMessage 单向到达。
window.onerror = (message, source, lineno) => {
  klineBus
    .request('app', 'jsError', { message: String(message), source: String(source ?? ''), line: lineno })
    .catch(() => {})
  return false
}
if (typeof window.addEventListener === 'function') {
  window.addEventListener('unhandledrejection', (event) => {
    const reason = (event as PromiseRejectionEvent).reason
    klineBus.request('app', 'jsError', { message: `unhandledrejection: ${String(reason)}` }).catch(() => {})
  })
}

createApp(App).mount('#app')
