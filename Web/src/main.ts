import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import { klineBus } from './bridge/klineBus'
import { initWebTheme } from './theme'
import { installFormCreate } from './fc/formCreate'
import './styles/theme.css'
// Vant 函数式 API（Toast/Dialog）样式需手动引入（组件样式由 VantResolver 按需注入）
import 'vant/es/toast/style'
import 'vant/es/dialog/style'

// 全局主题：启动即注册 theme.changed 监听并回读权威值（Vue 挂载前完成 data-theme
// 设置——夜间模式首帧即深色，不等页面各自 mounted）
initWebTheme()

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

createApp(App).use(router).use(installFormCreate).mount('#app')

// Tab 切换事件（协议 nav.tab）：原生底栏切换时由此切路由（P2-1 接入发送方）
klineBus.on('nav.tab', (e) => {
  const index = Number((e.payload ?? {})['index'])
  const pathByTab = ['/home', '/favorites', '/market', '/simulation']
  if (index >= 0 && index < pathByTab.length) {
    router.push(pathByTab[index])
  }
})
