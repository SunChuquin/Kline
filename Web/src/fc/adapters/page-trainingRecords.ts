// fc/adapters/page-trainingRecords.ts：训练记录页（page-trainingRecords）逻辑适配器。
// 会话列表（进入/删除/清空，删除与清空带二次确认）+ 明细三分段（成交表/条件单/预警）；
// 条件单文案经引擎投影，未就绪显示「…」，projection 就绪推送后自动重拉当前明细。
import { klineBus } from '../../bridge/klineBus'
import type { TrainingRecordDetail, TrainingRecordsSnapshot, TrainingSessionSnap } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

/** k-session-rows 会话行（对齐 KSessionRows.vue 的 SessionRow） */
interface SessionRow {
  id: string
  name: string
  code: string
  sub: string
  time: string
}

let detail: TrainingRecordDetail | null = null
let deleteId = ''

function ymd(v: number | null): string {
  if (v === null || v <= 0) return '—'
  const s = String(v)
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s
}

function sessionRow(s: TrainingSessionSnap): SessionRow {
  return {
    id: s.id,
    name: s.name,
    code: s.code,
    sub: `起始 ${ymd(s.startDate)} ~ ${s.endDate ? ymd(s.endDate) : '进行中'} · 交易 ${s.tradeCount} 笔 · ${s.status === 'running' ? '进行中' : '已完成'}`,
    time: s.createdAtText,
  }
}

function summaryText(d: TrainingRecordDetail): string {
  const s = d.session
  return `${s.name} ${s.code} · 起始 ${ymd(s.startDate)} ~ ${s.endDate ? ymd(s.endDate) : '—'} · 共 ${s.tradeCount} 笔`
}

/** 仅刷新会话列表数据（不改变当前所在页，对齐源 pullRecords 只更新 sessions） */
async function applySessions(api: FcApi): Promise<void> {
  let s: TrainingRecordsSnapshot
  try {
    s = ((await klineBus.request('training', 'records.snapshot')) ?? {}) as unknown as TrainingRecordsSnapshot
  } catch (e) {
    console.error('training.records.snapshot 失败', e)
    return
  }
  const sessions = s.sessions ?? []
  api.setValue({
    sessionRows: { rows: sessions.map(sessionRow) },
    listEmptyVisible: sessions.length === 0,
  })
  api.updateRule('listNav', { props: { rightDisabled: sessions.length === 0 } })
}

/** 挂载/回列表态：重置明细 + 刷新列表 */
async function pullRecords(api: FcApi): Promise<void> {
  detail = null
  api.setValue({ listVisible: true, detailVisible: false })
  await applySessions(api)
}

function applyDetail(api: FcApi, d: TrainingRecordDetail): void {
  detail = d
  api.setValue({
    listVisible: false,
    detailVisible: true,
    detailTabs: {
      value: 'trades',
      tabs: [
        { value: 'trades', title: '成交', count: d.trades.length },
        { value: 'conditions', title: '条件单', count: d.conds.length },
        { value: 'alerts', title: '预警', count: d.alerts.length },
      ],
    },
    tradeTable: { rows: d.trades },
    condCards: { rows: d.conds },
    alertCards: { rows: d.alerts },
    tabTradesVisible: true,
    tabCondsVisible: false,
    tabAlertsVisible: false,
  })
  api.updateRule('detailNav', { props: { rightText: d.session.name } })
  api.updateRule('summaryLine', { props: { text: summaryText(d) } })
}

async function openDetail(api: FcApi, id: string): Promise<void> {
  try {
    const d = (await klineBus.request('training', 'recordDetail', { id })) as unknown as TrainingRecordDetail
    applyDetail(api, d)
  } catch (e) {
    console.error('training.recordDetail 失败', e)
  }
}

const adapter: FcPageAdapter = {
  pull: async (api) => {
    await pullRecords(api)
  },

  actions: {
    openDetail: (inj) => {
      const row = inj.args[0] as SessionRow | undefined
      if (row) void openDetail(inj.api, row.id)
    },

    openDelete: (inj) => {
      const row = inj.args[0] as SessionRow | undefined
      if (!row) return
      deleteId = row.id
      inj.api.setValue({ deleteOpen: true })
    },

    confirmDelete: (inj) => {
      const id = deleteId
      if (!id) return
      void klineBus.request('training', 'deleteRecord', { id })
        .then(() => {
          if (detail?.session.id === id) detail = null
          // 删除的是当前明细 → 回列表；否则留在明细页仅刷新列表
          return detail ? applySessions(inj.api) : pullRecords(inj.api)
        })
        .catch((e) => console.error('training.deleteRecord 失败', e))
    },

    openClear: (inj) => {
      inj.api.setValue({ clearOpen: true })
    },

    confirmClear: (inj) => {
      void klineBus.request('training', 'clearRecords')
        .then(() => pullRecords(inj.api))
        .catch((e) => console.error('training.clearRecords 失败', e))
    },

    backToList: (inj) => {
      detail = null
      inj.api.setValue({ detailVisible: false, listVisible: true })
      void inj
    },

    switchTab: (inj) => {
      const value = String(inj.args[0] ?? 'trades')
      // k-seg-tabs 的选中态由其 modelValue.value 驱动
      const tabs = inj.api.getValue('detailTabs') as { value?: string } | undefined
      inj.api.setValue({
        detailTabs: { ...(tabs ?? {}), value },
        tabTradesVisible: value === 'trades',
        tabCondsVisible: value === 'conditions',
        tabAlertsVisible: value === 'alerts',
      })
    },
  },

  subscribe: (api) => {
    const handler = (ev: { payload?: Record<string, unknown> }): void => {
      const reason = String(ev.payload?.['reason'] ?? '')
      // 条件单文案投影就绪 → 重拉当前明细；其余变化仅刷新列表数据（不退明细页）
      if (reason === 'projection' && detail) {
        void openDetail(api, detail.session.id)
      } else {
        void applySessions(api)
      }
    }
    klineBus.on('training.changed', handler)
    return () => {
      detail = null
    }
  },
}

export default adapter
