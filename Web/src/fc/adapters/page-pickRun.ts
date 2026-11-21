// fc/adapters/page-pickRun.ts：跑选股 + 生成确认页（page-pickRun）逻辑适配器。
// 清单态由 strategyDetail.changed(pickPhase/pickHits) 驱动（StrategyPickRunner 转发）；
// 勾选后 generate 组装草稿 → changed(genConfirm) 切确认态（草稿文案投影缓存直读，
// 就绪后重推）；confirmGenerate 一次性落盘，成功由原生切回 strategyDetail（toast 经
// snapshot 一次性带出）；失败收 changed(genResult)。口径对齐原生 StrategyPickListView /
// StrategyGenConfirmView。
import { klineBus } from '../../bridge/klineBus'
import type { StrategyGenConfirmPayload, StrategyPickHitSnap, StrategyPickPhaseSnap } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'

let ctxRef: HostContext | null = null
let phase: StrategyPickPhaseSnap = { state: 'idle' }
let prepareTimedOut = false
let hits: StrategyPickHitSnap[] = []
let selected = new Set<number>()
let writing = false
let genError = ''
let draftCount = 0
/** genConfirm 回填的 includeEntry 认知值（onChange 比对，避免回填触发写桥环） */
let expectedEntry: boolean | null = null

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  api.updateRule(name, { style: { display: hidden ? 'none' : '' } })
}

function isAllSelected(): boolean {
  return hits.length > 0 && selected.size === hits.length
}

function emptyText(state: string): string {
  switch (state) {
    case 'idle': return '点击开始跑选股'
    case 'preparing': return '正在准备行情数据…'
    case 'running': return '正在扫描…'
    case 'finished': return '当前没有命中的标的'
    default: return '已取消'
  }
}

/** 清单态整体回填（池/进度/空态/命中/全选链接/nav 生成按钮态） */
function applyList(api: FcApi): void {
  const running = phase.state === 'preparing' || phase.state === 'running'
  api.setValue({
    listVisible: true,
    confirmVisible: false,
    pickProgress: { state: phase.state, done: phase.done, total: phase.total, hitCount: hits.length },
    emptyState: { title: emptyText(phase.state), sub: phase.state === 'finished' ? '命中 = 选股公式最后一条输出线的最新值 > 0' : '' },
    listEmptyVisible: hits.length === 0,
    hitList: { rows: hits, selected: [...selected] },
    toggleAllText: isAllSelected() ? '取消全选' : '全选',
  })
  api.updateRule('poolChips', { props: { disabled: running } })
  api.updateRule('toggleAllLink', { props: { disabled: hits.length === 0 } })
  api.updateRule('listNav', { props: { rightDisabled: selected.size === 0 } })
  setRowHidden(api, 'timeoutNote', !(phase.state === 'finished' && prepareTimedOut))
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  writing = false
  genError = ''
  draftCount = 0
  expectedEntry = null
  phase = { state: 'idle' }
  prepareTimedOut = false
  hits = []
  selected = new Set()
  api.setValue({
    pool: 'market',
    entryOn: false,
    confirmBar: { error: '', label: '确认生成（0 条）', disabled: true },
  })
  setRowHidden(api, 'limitWarn', true)
  applyList(api)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    start: (inj) => {
      void klineBus.request('strategyDetail', 'runPick', { pool: inj.api.getValue('pool') ?? 'market' })
        .catch((e) => console.error('strategyDetail.runPick 失败', e))
    },

    cancelPick: (inj) => {
      void klineBus.request('strategyDetail', 'cancelPick', {})
        .catch((e) => console.error('strategyDetail.cancelPick 失败', e))
    },

    toggleHit: (inj) => {
      const metaID = Number(inj.args[0])
      if (selected.has(metaID)) selected.delete(metaID)
      else selected.add(metaID)
      inj.api.setValue({ hitList: { rows: hits, selected: [...selected] } })
      inj.api.updateRule('listNav', { props: { rightDisabled: selected.size === 0 } })
    },

    toggleAll: (inj) => {
      selected = isAllSelected() ? new Set() : new Set(hits.map((h) => h.metaID))
      applyList(inj.api)
    },

    generate: (inj) => {
      if (selected.size === 0) return
      genError = ''
      void klineBus.request('strategyDetail', 'generate', {
        metaIDs: [...selected],
        includeEntry: false,
      }).catch((e) => {
        genError = String(e instanceof Error ? e.message : e).slice(0, 60)
      })
    },

    backToList: (inj) => {
      // 确认态返回 = 回清单（草稿保留可重新勾选）
      applyList(inj.api)
    },

    confirmGenerate: (inj) => {
      writing = true
      genError = ''
      inj.api.setValue({ confirmBar: { error: '', label: '写入中…', disabled: true } })
      void klineBus.request('strategyDetail', 'confirmGenerate', {})
        .catch((e) => {
          // 成功由原生切回 strategyDetail（本组件随 activeName 切换销毁）；失败恢复按钮
          genError = String(e instanceof Error ? e.message : e).slice(0, 60)
          writing = false
          inj.api.setValue({ confirmBar: { error: genError, label: `确认生成（${draftCount} 条）`, disabled: false } })
        })
    },
  },

  onChange: (field, value, api) => {
    if (field === 'entryOn') {
      // 仅用户切换时写回桥；genConfirm 回填（与原生认知一致）不触发
      const on = value === true
      if (expectedEntry !== null && on === expectedEntry) return
      expectedEntry = on
      void klineBus.request('strategyDetail', 'toggleEntry', { includeEntry: on })
        .catch((e) => console.error('strategyDetail.toggleEntry 失败', e))
    }
  },

  subscribe: (api) => {
    const handler = (ev: { payload?: Record<string, unknown> }): void => {
      const p = (ev.payload ?? {}) as Record<string, unknown>
      const reason = String(p['reason'] ?? '')
      if (reason === 'pickPhase') {
        const ph = (p['phase'] ?? {}) as StrategyPickPhaseSnap
        phase = { state: ph.state ?? 'idle', done: ph.done, total: ph.total }
        prepareTimedOut = p['prepareTimedOut'] === true
        try {
          api.setValue({ pickProgress: { state: phase.state, done: phase.done, total: phase.total, hitCount: hits.length } })
          api.updateRule('poolChips', { props: { disabled: phase.state === 'preparing' || phase.state === 'running' } })
          setRowHidden(api, 'timeoutNote', !(phase.state === 'finished' && prepareTimedOut))
          if (hits.length === 0) {
            api.setValue({ emptyState: { title: emptyText(phase.state), sub: phase.state === 'finished' ? '命中 = 选股公式最后一条输出线的最新值 > 0' : '' } })
          }
        } catch (e) {
          console.warn('[fc] pickRun pickPhase 应用跳过（面板可能已关闭）', e)
        }
      } else if (reason === 'pickHits') {
        hits = (p['hits'] ?? []) as StrategyPickHitSnap[]
        // 结果变化默认全选（原生 onChange(hits) 同款；用户已手动改过勾选则此处重置）
        selected = new Set(hits.map((h) => h.metaID))
        try {
          applyList(api)
          if (hits.length === 0) {
            api.setValue({ emptyState: { title: emptyText(phase.state), sub: phase.state === 'finished' ? '命中 = 选股公式最后一条输出线的最新值 > 0' : '' } })
          }
        } catch (e) {
          console.warn('[fc] pickRun pickHits 应用跳过（面板可能已关闭）', e)
        }
      } else if (reason === 'genConfirm') {
        const confirm = p as unknown as StrategyGenConfirmPayload
        draftCount = confirm.draftCount
        try {
          api.setValue({
            confirmVisible: true,
            listVisible: false,
            overviewCard: {
              title: '概览',
              lines: [
                { text: `将写入 ${confirm.draftCount} 条条件单 · 跳过 ${confirm.skipCount} 条`, tone: 'text' },
                { text: `来自 ${confirm.metaCount} 只勾选标的`, tone: 'sub' },
              ],
            },
            entryOn: confirm.includeEntry,
            draftGroups: { groups: confirm.groups },
            skipList: { rows: confirm.skips },
            confirmBar: { error: genError, label: `确认生成（${confirm.draftCount} 条）`, disabled: confirm.draftCount === 0 || writing },
          })
          expectedEntry = confirm.includeEntry
          api.updateRule('entryCard', { style: { display: confirm.canToggleEntry ? '' : 'none' } })
          setRowHidden(api, 'limitWarn', !confirm.truncatedByLimit)
          writing = false
        } catch (e) {
          console.warn('[fc] pickRun genConfirm 应用跳过（面板可能已关闭）', e)
        }
      } else if (reason === 'genResult') {
        writing = false
        genError = '写入失败，请稍后重试'
        try {
          api.setValue({ confirmBar: { error: genError, label: `确认生成（${draftCount} 条）`, disabled: false } })
        } catch (e) {
          console.warn('[fc] pickRun genResult 应用跳过（面板可能已关闭）', e)
        }
      }
    }
    klineBus.on('strategyDetail.changed', handler)
    // 清单态初值：读执行器当前状态（page.ready 触发原生重放积压 changed——进入前可能
    // 已有上一轮结果；start 会先清空）。handler 已注册后再拉，事件不丢。
    void klineBus.request('page', 'ready', {}).catch(() => { /* 事件拉取失败不阻断 */ })
    return () => {
      ctxRef = null
    }
  },
}

export default adapter
