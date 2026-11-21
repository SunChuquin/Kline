// fc/adapters/page-strategyDetail.ts：策略详情页（page-strategyDetail）逻辑适配器。
// 快照：strategyDetail.snapshot（基础信息同步直出 + 一次性 toast）；引擎取值（选股摘要/
// 交易摘要/规则触发文案）经 strategyDetail.changed(values) 推送（占位→就绪两段式，
// 对齐原生 StrategyDetailView 的 E 组口径）。
// 动作：编辑 → strategyDetail.edit；跑选股/生成条件单 → page.open pickRun；
// 回测 → strategyDetail.backtest。toast 3 秒自动消失。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

/** k-card-lines 文本行（对齐 KCardLines.vue 的 CardLine） */
interface CardLine {
  idx?: string
  text: string
  tone?: 'text' | 'rule' | 'sub' | 'sec' | 'warn' | 'err'
}

interface DetailSnapshot {
  id?: string
  name?: string
  tradeConfigured?: boolean
  canGenerate?: boolean
  boundAccounts?: string[]
  missingCount?: number
  valuesQueued?: boolean
  toast?: string
}

interface DetailValues {
  pickSummary: string
  tradeSummary: string
  rules: { kindTitle: string; trigger: string }[]
  parseErrors: string[]
  unavailable: boolean
}

let lastSnap: DetailSnapshot | null = null
let toastTimer: ReturnType<typeof setTimeout> | null = null

function showToast(api: FcApi, text: string): void {
  api.setValue({ toastText: text })
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => {
    try {
      api.setValue({ toastText: '' })
    } catch {
      // 面板已卸载，忽略
    }
  }, 3000)
}

/** 交易卡行（tradeConfigured=false 时显示引导文案） */
function tradeLines(snap: DetailSnapshot, values: DetailValues | null): CardLine[] {
  if (!snap.tradeConfigured) {
    return [{ text: '尚未配置交易指令与绑定账户，请点右上角编辑', tone: 'warn' }]
  }
  const lines: CardLine[] = [{ text: values?.unavailable ? '—' : values?.tradeSummary ?? '…', tone: 'text' }]
  if ((snap.boundAccounts ?? []).length > 0) {
    lines.push({ text: `绑定账户：${snap.boundAccounts!.join('、')}`, tone: 'sub' })
  }
  if ((snap.missingCount ?? 0) > 0) {
    lines.push({ text: `${snap.missingCount} 个账户已失效`, tone: 'warn' })
  }
  return lines
}

/** 交易规则卡行：空规则/解析错误/引擎不可用三种占位 */
function rulesLines(values: DetailValues | null): CardLine[] {
  if (!values) return [{ text: '…', tone: 'sec' }]
  if (values.unavailable) return [{ text: '—', tone: 'sec' }]
  const lines: CardLine[] = values.rules.map((r, i) => ({ idx: `${i + 1}.`, text: r.trigger, tone: 'rule' }))
  for (const e of values.parseErrors) lines.push({ text: `✗ ${e}`, tone: 'err' })
  if (values.rules.length === 0 && values.parseErrors.length === 0) {
    return [{ text: '还没有交易规则', tone: 'sub' }]
  }
  return lines
}

function applyValues(api: FcApi, snap: DetailSnapshot, values: DetailValues | null): void {
  api.setValue({
    pickCard: { title: '选股条件', lines: [{ text: values?.unavailable ? '—' : values?.pickSummary ?? '…', tone: 'text' }] },
    tradeCard: { title: '交易指令与绑定账户', lines: tradeLines(snap, values) },
    rulesCard: { title: '交易规则', lines: rulesLines(values) },
  })
}

async function pull(api: FcApi): Promise<void> {
  let snap: DetailSnapshot
  try {
    snap = ((await klineBus.request('strategyDetail', 'snapshot')) ?? {}) as DetailSnapshot
  } catch (e) {
    console.error('strategyDetail.snapshot 失败', e)
    return
  }
  lastSnap = snap
  api.setValue({
    toastText: '',
    execCard: { title: '执行', lines: snap.canGenerate === true ? [] : [{ text: '请先在编辑里配置交易指令与绑定账户', tone: 'warn' }] },
    execButtons: {
      buttons: [
        { label: '跑选股', act: 'openPickRun', tone: 'tint', ariaLabel: 'strategyDetail.runPick' },
        { label: '生成条件单', act: 'openPickRun', tone: 'tint', disabled: snap.canGenerate !== true, ariaLabel: 'strategyDetail.generate' },
        { label: '回测', act: 'runBacktest', tone: 'tint', ariaLabel: 'strategyDetail.backtest' },
      ],
    },
  })
  applyValues(api, snap, null)
  // 生成成功 toast（原生一次性带出）：3 秒自动消失
  if (snap.toast) showToast(api, snap.toast)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    edit: (inj) => {
      void klineBus.request('strategyDetail', 'edit', {}).catch((e) => console.error('strategyDetail.edit 失败', e))
      void inj
    },

    dispatchExec: (inj) => {
      const act = String(inj.args[0] ?? '')
      if (act === 'openPickRun') {
        // 跑选股 / 生成条件单入口：Web 页内切 pickRun（勾选与确认在 pickRun 内完成）
        void klineBus.request('page', 'open', { name: 'pickRun' })
          .catch((e) => console.error('page.open pickRun 失败', e))
      } else if (act === 'runBacktest') {
        void klineBus.request('strategyDetail', 'backtest', {}).catch((e) => console.error('strategyDetail.backtest 失败', e))
      }
    },
  },

  subscribe: (api) => {
    const handler = (ev: BridgeEvent): void => {
      const p = (ev.payload ?? {}) as Record<string, unknown>
      if (String(p['reason'] ?? '') !== 'values') return
      const values: DetailValues = {
        pickSummary: String(p['pickSummary'] ?? ''),
        tradeSummary: String(p['tradeSummary'] ?? ''),
        rules: (p['rules'] ?? []) as DetailValues['rules'],
        parseErrors: (p['parseErrors'] ?? []) as string[],
        unavailable: p['unavailable'] === true,
      }
      try {
        // 交易卡绑定账户/失效数来自缓存 snapshot（对齐源内存响应式合并，无额外请求）
        applyValues(api, lastSnap ?? {}, values)
      } catch (e) {
        console.warn('[fc] strategyDetail values 应用跳过（面板可能已关闭）', e)
      }
    }
    klineBus.on('strategyDetail.changed', handler)
    return () => {
      if (toastTimer) {
        clearTimeout(toastTimer)
        toastTimer = null
      }
    }
  },
}

export default adapter
