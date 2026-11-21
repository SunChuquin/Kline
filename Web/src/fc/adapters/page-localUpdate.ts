// fc/adapters/page-localUpdate.ts：本地更新页（page-localUpdate）逻辑适配器。
// 快照：update.snapshot；动作：reconnectServer / checkApp / installApp / checkEngine /
// installEngine / syncNow / runGapBackfill / queryBaselineMissing；
// 基准缺失名单经 update.changed(baselineReady) 推送 → 弹层；baselineFailed → alert。
// 值行锚点用复合 aria-label（gapBackfill.<key>|<值>），GapBackfillUITests 前缀匹配读值。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'
import type { SnapRow } from '../components/KSnapCard.vue'
import type { BaselineItem } from '../components/KBaselineSheet.vue'

type RowState = 'idle' | 'checking' | 'latest' | 'outdated' | 'downloading' | 'failed'

interface UpdateRowSnap {
  state: RowState
  percent: number
  title: string
}

interface UpdateSnapshot {
  server: { ok: boolean; probing: boolean }
  app: UpdateRowSnap
  engine: UpdateRowSnap
  watchlist: {
    enabled: boolean
    isRunning: boolean
    stateText: string
    stateTone: 'gray' | 'yellow' | 'green' | 'red'
    lastResultText: string
    unionCount: number
    requestText: string
    lastTradeDate: string
    slots: { time: string; title: string; value: string }[]
    note: string
  }
  gap: {
    statusText: string
    coverageText: string
    baselineText: string
    baselineStale: boolean
    fetchText: string
    verdictText: string
    isRunning: boolean
    baselineLoading: boolean
    detailLines: string[]
  }
  baseline: { mainLatest: number; items: BaselineItem[] } | null
}

let snap: UpdateSnapshot | null = null

function safe(fn: () => void, tag: string): void {
  try {
    fn()
  } catch (e) {
    console.warn(`[fc] localUpdate ${tag} 跳过（面板可能已关闭）`, e)
  }
}

// ===== 状态图标语义（对齐源 serverIcon / remoteStateIcon / watchlistStateIcon） =====

function stateGlyph(state?: RowState): string {
  switch (state) {
    case 'idle': return '='
    case 'checking': return '…'
    case 'latest': return '✓'
    case 'outdated':
    case 'failed': return '✕'
    default: return '='
  }
}

function stateClass(state?: RowState): string {
  switch (state) {
    case 'checking':
    case 'downloading': return 'state-yellow'
    case 'latest': return 'state-green'
    case 'outdated':
    case 'failed': return 'state-red'
    default: return 'state-gray'
  }
}

function serverGlyph(s: UpdateSnapshot | null): string {
  if (s?.server.probing) return '='
  return s?.server.ok ? '✓' : '✕'
}

function serverClass(s: UpdateSnapshot | null): string {
  if (s?.server.probing) return 'state-yellow'
  return s?.server.ok ? 'state-green' : 'state-red'
}

function watchClass(w: UpdateSnapshot['watchlist'] | undefined): string {
  if (!w) return 'state-gray'
  if (!w.enabled) return 'state-gray'
  if (w.isRunning) return 'state-yellow'
  return w.stateTone === 'green' ? 'state-green' : w.stateTone === 'red' ? 'state-red' : 'state-gray'
}

function watchGlyph(w: UpdateSnapshot['watchlist'] | undefined): string {
  if (!w) return '='
  if (!w.enabled) return '='
  if (w.isRunning) return '…'
  return w.stateTone === 'green' ? '✓' : w.stateTone === 'red' ? '✕' : '='
}

function resultTone(text: string): string {
  if (text.startsWith('失败')) return 'tone-red'
  if (text.startsWith('成功')) return 'tone-green'
  return ''
}

function gapTone(s: UpdateSnapshot | null): string {
  const st = s?.gap.statusText ?? ''
  const v = s?.gap.verdictText ?? ''
  if (st === 'running' || s?.gap.isRunning) return 'tone-yellow'
  if (v.startsWith('失败')) return 'tone-red'
  if (v.startsWith('完成') || v.includes('缺口已补') || v.includes('无缺口')) return 'tone-green'
  return ''
}

function buildRemoteRows(s: UpdateSnapshot | null): SnapRow[] {
  const disabled = !!s && (s.server.ok || s.server.probing)
  return [
    { button: true, title: '在线服务', glyph: serverGlyph(s), iconTone: serverClass(s), disabled, act: 'tapServer' },
    {
      button: true,
      title: s?.app.title ?? '检查新版',
      glyph: s?.app.state === 'downloading' ? String(s.app.percent) : stateGlyph(s?.app.state),
      iconTone: stateClass(s?.app.state),
      disabled: !!s && (s.app.state === 'checking' || s.app.state === 'downloading'),
      act: 'tapApp',
    },
    {
      button: true,
      title: s?.engine.title ?? '更新引擎',
      glyph: s?.engine.state === 'downloading' ? String(s.engine.percent) : stateGlyph(s?.engine.state),
      iconTone: stateClass(s?.engine.state),
      disabled: !!s && (s.engine.state === 'checking' || s.engine.state === 'downloading'),
      act: 'tapEngine',
    },
  ]
}

function buildWatchlistRows(s: UpdateSnapshot | null): SnapRow[] {
  const w = s?.watchlist
  const rows: SnapRow[] = [
    { title: '状态', value: w?.stateText ?? '—', tone: `tone-${w?.stateTone ?? 'gray'}`, glyph: watchGlyph(w), iconTone: watchClass(w) },
    { title: '最近结果', value: w?.lastResultText ?? '—', tone: resultTone(w?.lastResultText ?? '') },
    { title: '清单并集', value: (w?.unionCount ?? 0) > 0 ? `${w?.unionCount} 只` : '—' },
    { title: '本次请求', value: w?.requestText ?? '—' },
    { title: '当日交易日', value: w?.lastTradeDate ?? '—' },
  ]
  for (const slot of w?.slots ?? []) {
    rows.push({ title: slot.title, value: slot.value })
  }
  rows.push({
    button: true,
    title: '立即更新',
    dim: !w?.enabled || !!w?.isRunning,
    glyph: w?.isRunning ? '◌' : '⟳',
    iconTone: w?.isRunning ? 'state-yellow' : 'state-blue',
    disabled: !w?.enabled || !!w?.isRunning,
    act: 'syncNow',
  })
  rows.push({ kind: 'note', value: w?.note ?? '' })
  return rows
}

function buildGapRows(s: UpdateSnapshot | null): SnapRow[] {
  const g = s?.gap
  const rows: SnapRow[] = [
    { title: '状态', value: g?.statusText ?? '—', tone: gapTone(s), valueAria: 'gapBackfill.status|' + (g?.statusText ?? '') },
    { title: '主库 → 今日', value: g?.coverageText ?? '—', valueAria: 'gapBackfill.coverage|' + (g?.coverageText ?? '') },
    { title: '主库基线', value: g?.baselineText ?? '—', tone: g?.baselineStale ? 'tone-orange' : '' },
    { title: '补齐结果', value: g?.fetchText ?? '—', valueAria: 'gapBackfill.fetch|' + (g?.fetchText ?? '') },
    { title: '结论', value: g?.verdictText ?? '—', tone: gapTone(s), valueAria: 'gapBackfill.verdict|' + (g?.verdictText ?? '') },
    {
      button: true,
      title: '补一次缺口',
      aria: 'gapBackfill.run',
      dim: !!g?.isRunning,
      glyph: g?.isRunning ? '◌' : '⤓',
      iconTone: g?.isRunning ? 'state-yellow' : 'state-blue',
      disabled: !!g?.isRunning,
      act: 'runGapBackfill',
    },
    {
      button: true,
      title: '基准缺失名单',
      aria: 'gapBackfill.baselineMissing',
      glyph: g?.baselineLoading ? '◌' : '≡',
      iconTone: g?.baselineLoading ? 'state-yellow' : 'state-blue',
      disabled: !!g?.baselineLoading,
      act: 'queryBaselineMissing',
    },
  ]
  const details = g?.detailLines ?? []
  details.forEach((line, i) => {
    rows.push({ kind: 'detail', value: line, aria: `gapBackfill.detail.${i}|${line}` })
  })
  return rows
}

function baselineSummary(s: UpdateSnapshot | null): string {
  const b = s?.baseline
  if (!b) return ''
  const latest = b.mainLatest === 0 ? '-' : String(b.mainLatest)
  return `共 ${b.items.length} 只 · 主库最新 ${latest} · 缺自校准锚点，补缺口本轮跳过`
}

async function pull(api: FcApi): Promise<void> {
  try {
    snap = ((await klineBus.request('update', 'snapshot')) ?? {}) as unknown as UpdateSnapshot
  } catch (e) {
    console.error('update.snapshot 失败', e)
    return
  }
  const curBaseline = (api.getValue('baseline') as { show?: boolean } | undefined) ?? {}
  safe(() => {
    api.setValue({
      cardRemote: { rows: buildRemoteRows(snap) },
      cardWatchlist: { rows: buildWatchlistRows(snap) },
      cardGap: { rows: buildGapRows(snap) },
      baseline: {
        // 弹层显隐是 Web 本地态（源 baselineOpen ref），快照回填不重置
        show: curBaseline.show ?? false,
        summary: baselineSummary(snap),
        items: snap?.baseline?.items ?? [],
      },
    })
  }, 'pull')
}

function act(action: string, payload?: Record<string, unknown>): void {
  void klineBus.request('update', action, payload).catch((e) => console.error(`update.${action} 失败`, e))
}

// ===== 行点击语义（对齐源 onRemoteRowTap / onEngineRowTap） =====

function dispatchRowAct(api: FcApi, actName: string): void {
  switch (actName) {
    case 'tapServer':
      // 仅离线且非探测中可点 = 重连（onAppear 自动探测；回前台由原生通知驱动）
      if (!snap?.server.ok && !snap?.server.probing) act('reconnectServer')
      break
    case 'tapApp': {
      const st = snap?.app.state
      if (st === 'outdated') act('installApp')
      else if (st === 'idle' || st === 'latest' || st === 'failed') act('checkApp')
      break
    }
    case 'tapEngine': {
      const st = snap?.engine.state
      if (st === 'outdated') act('installEngine')
      else if (st === 'idle' || st === 'latest' || st === 'failed') act('checkEngine')
      break
    }
    case 'syncNow':
      act('syncNow')
      break
    case 'runGapBackfill':
      act('runGapBackfill')
      break
    case 'queryBaselineMissing':
      act('queryBaselineMissing')
      break
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    rowAct: (inj) => {
      dispatchRowAct(inj.api, String(inj.args[0] ?? ''))
    },

    baselineClose: (inj) => {
      safe(() => {
        const cur = (inj.api.getValue('baseline') as Record<string, unknown> | undefined) ?? {}
        inj.api.setValue({ baseline: { ...cur, show: false } })
      }, 'baselineClose')
    },
  },

  subscribe: (api) => {
    // klineBus 无 off：面板卸载后 handler 内 safe() 静默跳过陈旧 api 调用
    klineBus.on('update.changed', (ev: BridgeEvent) => {
      const p = ev.payload ?? {}
      const reason = String(p['reason'] ?? '')
      if (reason === 'baselineReady') {
        const cur = (api.getValue('baseline') as Record<string, unknown> | undefined) ?? {}
        safe(() => api.setValue({ baseline: { ...cur, show: true } }), 'baselineReady')
      } else if (reason === 'baselineFailed') {
        safe(() => {
          api.updateRule('alertDlg', { props: { message: String(p['message'] ?? '') } })
          api.setValue({ alertShow: true })
        }, 'baselineFailed')
      }
      void pull(api)
    })
    return () => {}
  },
}

export default adapter
