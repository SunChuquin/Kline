// fc/adapters/page-profile.ts：个人中心页（page-profile）逻辑适配器。
// 快照：profile.snapshot（版本/主库状态/同步调度/仅交易日）；主题走 theme.get/set
// （theme.changed 广播全实例跟随）；公式管理桥原生公式中心；本地更新/缓存管理/
// 联机同步/引擎实验室入口经 page.open 在同一切换 WebView 内切换。
import { klineBus } from '../../bridge/klineBus'
import type { FcApi, FcPageAdapter } from '../types'
import type { SnapRow } from '../components/KSnapCard.vue'

interface ProfileSnapshot {
  version: string
  build: string
  syncEnabled: boolean
  scheduleTimes: string[]
  tradingDaysOnly: boolean
  dbLoaded: boolean
}

const THEMES = [
  { value: 'system', title: '跟随系统' },
  { value: 'light', title: '日间' },
  { value: 'dark', title: '夜间' },
]

function themeTitle(preference: string): string {
  return THEMES.find((t) => t.value === preference)?.title ?? '跟随系统'
}

function syncScheduleText(s: ProfileSnapshot | null): string {
  return s?.syncEnabled ? (s.scheduleTimes.join(' / ') || '已启用') : '未启用'
}

function buildInfoRows(s: ProfileSnapshot | null): SnapRow[] {
  return [
    { title: '主库状态', value: s?.dbLoaded ? '已加载' : '加载中', tone: s?.dbLoaded ? 'tone-green' : 'tone-yellow' },
    { title: '同步调度', value: syncScheduleText(s) },
    { title: '仅交易日', value: s?.tradingDaysOnly ? '是' : '否' },
  ]
}

async function pull(api: FcApi): Promise<void> {
  let snap: ProfileSnapshot | null = null
  let preference = 'system'
  try {
    snap = ((await klineBus.request('profile', 'snapshot')) ?? {}) as unknown as ProfileSnapshot
  } catch (e) {
    console.error('profile.snapshot 失败', e)
  }
  try {
    const t = (await klineBus.request('theme', 'get')) as Record<string, unknown>
    preference = String(t?.preference ?? 'system')
  } catch { /* 主题读取失败保持默认 */ }
  try {
    api.setValue({
      header: { version: snap?.version ?? '', build: snap?.build ?? '' },
      info: { rows: buildInfoRows(snap) },
      theme: {
        value: preference,
        multiple: false,
        sections: [
          {
            title: '',
            options: THEMES,
          },
        ],
      },
    })
    api.updateRule('themeRow', { props: { value: themeTitle(preference) } })
  } catch (e) {
    console.error('profile pull 回填失败', e)
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    setTheme: (inj) => {
      const value = String(inj.args[0] ?? 'system')
      // k-chip-sections 已双向更新字段值；标题行值跟随（对齐源 themeText computed）
      try {
        inj.api.updateRule('themeRow', { props: { value: themeTitle(value) } })
      } catch (e) {
        console.warn('[fc] profile themeRow 更新跳过', e)
      }
      void klineBus.request('theme', 'set', { preference: value }).catch((e) => {
        console.error('theme.set 失败', e)
      })
    },

    entryAct: (inj, ctx) => {
      const act = String(inj.args[0] ?? '')
      if (act === 'formulaCenter') {
        // 公式管理：桥原生公式中心（tech 段 = Web 弹层面板；picker/strategy = 原生全屏中心）
        void klineBus.request('sheet', 'close', {}).catch(() => {})
        void klineBus.request('chart', 'formula.openCenter', {}).catch((e) => console.error(e))
        ctx.close()
        return
      }
      // 全屏 Web 页入口：请求原生切换 activePage（同 WebView 内 page.open 驱动切换，无缝）
      const name = act === 'openLocalUpdate' ? 'localUpdate'
        : act === 'openCacheManage' ? 'cacheManage'
        : act === 'openLanSync' ? 'lanSync'
        : act === 'openPythonLab' ? 'pythonLab'
        : null
      if (name) void klineBus.request('page', 'open', { name }).catch((e) => console.error(e))
    },
  },
}

export default adapter
