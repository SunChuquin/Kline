// Web 全局主题应用（P2 全页面 Vant 化）：data-theme 驱动 theme.css 变量组切换。
// ⚠️ 主题应用必须全局做——此前只在 P1 试点页（ProfilePilotPage）实现，P2 各页从未
// 设置 data-theme，夜间模式下全部 Web 页面恒为日间白底（2026-11-20 用户实测反馈）。
//
// 机制：theme.css 以 [data-theme='dark'] 覆盖 --k-* / --van-* 变量组；原生侧
// KlineThemeStore 变化经 theme.changed 推送（推全部就绪 WebView），本模块在
// main.ts 启动时注册监听并回读一次权威值，此后任意页面/实例均自动跟随。
import { klineBus } from './bridge/klineBus'

/** 解析 theme 事件/响应 payload → 设置 html 根 data-theme（mode = 解析后实际外观） */
export function applyWebTheme(t: { preference?: unknown; mode?: unknown }): void {
  if (typeof t.mode === 'string') {
    document.documentElement.setAttribute('data-theme', t.mode === 'dark' ? 'dark' : 'light')
  }
}

/** 启动即注册：监听 theme.changed 广播 + 回读一次权威主题（骨架屏期间完成，首帧即正确底色） */
export function initWebTheme(): void {
  klineBus.on('theme.changed', (e) => applyWebTheme((e.payload ?? {}) as { mode?: unknown }))
  void klineBus
    .detect()
    .then((transport) => {
      if (transport === 'none') return undefined
      return klineBus
        .request('theme', 'get')
        .then((r) => applyWebTheme((r ?? {}) as { mode?: unknown }))
        .catch(() => {})
    })
    .catch(() => {})
}
