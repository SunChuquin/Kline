// fc/adapters/page-cacheManage.ts：缓存管理页（page-cacheManage）逻辑适配器。
// 快照：cacheManage.stats；动作：clear / generate / cancelGenerate；
// 进度：cacheManage.changed(progress|done|cancelled|cleared) 推送 + 2s 轮询兜底。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

interface CacheCombo {
  comboKey: string
  label: string
  count: number
  bytes: number
}

interface CacheStatsSnapshot {
  combos: CacheCombo[]
  scopes: { key: string; label: string }[]
  warmupN: number
  bufferNote?: string
  running: { state: string; done?: number; total?: number; comboLabel?: string }
}

const PULL_CTX = { domain: 'page', pageName: 'page-cacheManage', close: () => {} } as const

let stats: CacheStatsSnapshot | null = null
let scopeKey = 'all'
let pollTimer: number | undefined

function syncButtons(api: FcApi, running: boolean): void {
  const checked = ((api.getValue('combos') as { checked?: string[] } | undefined)?.checked) ?? []
  api.updateRule('clearBtn', { props: { disabled: checked.length === 0 } })
  api.updateRule('generateBtn', { props: { disabled: checked.length === 0 || running, loading: running } })
  api.updateRule('cancelBtn', { props: { disabled: !running } })
}

function applyProgress(api: FcApi, p: { state: string; done?: number; total?: number; comboLabel?: string }): void {
  try {
    api.setValue({ progress: p })
    syncButtons(api, p.state === 'running')
  } catch (e) {
    // 面板已卸载（宿主 pageSeq 重挂载/关闭），忽略陈旧 api 调用
    console.warn('[fc] cacheManage applyProgress 跳过（面板可能已关闭）', e)
  }
}

async function pull(api: FcApi): Promise<void> {
  try {
    stats = ((await klineBus.request('cacheManage', 'stats')) ?? {}) as CacheStatsSnapshot
  } catch (e) {
    console.error('cacheManage.stats 失败', e)
    return
  }
  const r = stats.running
  const firstScope = stats.scopes?.[0]
  scopeKey = firstScope?.key ?? 'all'
  api.setValue({
    combos: { rows: stats.combos ?? [], checked: [] },
    genCombos: [],
    genMode: 'warm',
    warmupN: stats.warmupN ?? 80,
    selPeriods: ['日线'],
    scopeLabel: firstScope?.label ?? '',
    scopeOpen: false,
    progress: { state: r.state, done: r.done ?? 0, total: r.total ?? 0, comboLabel: r.comboLabel ?? '' },
  })
  api.updateRule('genCombos', {
    props: {
      multiple: true,
      options: (stats.combos ?? []).map((c) => ({ label: c.label, value: c.comboKey })),
    },
  })
  syncButtons(api, r.state === 'running')
}

function startPolling(api: FcApi): void {
  if (pollTimer !== undefined) return
  // 2s 轮询兜底：生成是分钟级后台任务，stats 查询 <5ms，开销可忽略
  pollTimer = window.setInterval(() => {
    void klineBus.request('cacheManage', 'stats').then((s) => {
      const snap = s as CacheStatsSnapshot | undefined
      if (!snap) return
      stats = snap
      const r = snap.running
      const cur = api.getValue('combos') as { checked?: string[] } | undefined
      api.setValue({ combos: { rows: snap.combos ?? [], checked: cur?.checked ?? [] } })
      if (r.state === 'running') {
        applyProgress(api, { state: 'running', done: r.done ?? 0, total: r.total ?? 0, comboLabel: r.comboLabel ?? '' })
      } else if (r.state === 'finished' || r.state === 'cancelled') {
        applyProgress(api, { state: r.state })
      } else {
        syncButtons(api, false)
      }
    }).catch(() => {})
  }, 2000)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    toggleCombo: (inj) => {
      const comboKey = inj.args[0] as string
      const cur = (inj.api.getValue('combos') as { rows: unknown[]; checked: string[] }) ?? { rows: [], checked: [] }
      const checked = cur.checked.includes(comboKey)
        ? cur.checked.filter((k) => k !== comboKey)
        : [...cur.checked, comboKey]
      inj.api.setValue({ combos: { ...cur, checked } })
      syncButtons(inj.api, false)
    },

    clearSelected: (inj) => {
      const checked = ((inj.api.getValue('combos') as { checked?: string[] } | undefined)?.checked) ?? []
      if (checked.length === 0) return
      void klineBus.request('cacheManage', 'clear', { ids: checked }).then(() => {
        return pull(inj.api)
      }).catch((e) => console.error('cacheManage.clear 失败', e))
    },

    generate: (inj) => {
      const checked = ((inj.api.getValue('combos') as { checked?: string[] } | undefined)?.checked) ?? []
      if (checked.length === 0) return
      // 本地立即反馈：不等 changed 推送（事件链路偶发丢失时按钮应有可见变化）
      applyProgress(inj.api, { state: 'running', done: 0, total: 0, comboLabel: '启动中…' })
      void klineBus.request('cacheManage', 'generate', {
        combos: checked,
        mode: inj.api.getValue('genMode') ?? 'warm',
        periods: (inj.api.getValue('selPeriods') as string[]) ?? ['日线'],
        scopes: [scopeKey],
        warmupN: inj.api.getValue('warmupN') ?? 80,
      }).catch((e) => {
        console.error('cacheManage.generate 失败', e)
        applyProgress(inj.api, { state: 'idle' })
      })
    },

    cancelGenerate: (inj) => {
      void klineBus.request('cacheManage', 'cancelGenerate', {}).catch((e) => console.error(e))
      void inj
    },

    openScope: (inj) => {
      const scopes = stats?.scopes ?? []
      inj.api.setValue({
        scopeActions: scopes.map((s) => ({ name: s.label, value: s.key })),
        scopeOpen: true,
      })
    },

    scopeSelect: (inj) => {
      const action = inj.args[0] as { name: string; value: string } | undefined
      if (!action) return
      scopeKey = action.value
      inj.api.setValue({ scopeLabel: action.name, scopeOpen: false })
    },
  },

  onChange: (field, value, api) => {
    if (field === 'genMode') {
      // 预热模式显示根数行；全量隐藏（rule.style 控制显隐，须显式复位）
      api.updateRule('warmupNRow', { style: { display: value === 'warm' ? '' : 'none' } })
    }
  },

  subscribe: (api) => {
    startPolling(api)
    // changed 事件推送（进度加速反馈）；轮询兜底已覆盖正确性
    const handler = (ev: BridgeEvent): void => {
      const p = ev.payload ?? {}
      const reason = String(p['reason'] ?? '')
      if (reason === 'progress') {
        applyProgress(api, {
          state: String(p['state'] ?? 'running'),
          done: Number(p['done'] ?? 0),
          total: Number(p['total'] ?? 0),
          comboLabel: String(p['comboLabel'] ?? ''),
        })
      } else if (reason === 'done' || reason === 'cancelled') {
        applyProgress(api, { state: reason === 'done' ? 'finished' : 'cancelled' })
        void pull(api)
      } else if (reason === 'cleared') {
        void pull(api)
      }
    }
    klineBus.on('cacheManage.changed', handler)
    return () => {
      if (pollTimer !== undefined) {
        window.clearInterval(pollTimer)
        pollTimer = undefined
      }
    }
  },
}

export default adapter
