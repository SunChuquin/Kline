// fc/adapters/sheet-training.ts：训练设置浮层（sheet-training）逻辑适配器。
// 偏好：training.setup.snapshot / training.setPrefs；搜索：training.search（300ms 防抖）；
// 随机：training.pickRandom（金额路径 queued 等 training.changed picked/pickFailed）；
// 锚点：training.anchor（日期区间）；开训：training.begin；事件：training.changed。
import { klineBus } from '../../bridge/klineBus'
import { ymd, ymdInt } from '../format'
import type { FcApi, FcInject, FcPageAdapter, HostContext } from '../types'

interface TrainingSetupSnapshot {
  groups?: { id: string; name: string }[]
  prefs?: { accountType?: string; capitalText?: string; tradeMode?: string }
}

let ctxRef: HostContext | null = null
let groups: { id: string; name: string }[] = []
let selected: { file: string; name: string; code: string } | null = null
let range: { min: number; max: number; trainable: boolean } | null = null
let startDate = 0
let searchTimer: ReturnType<typeof setTimeout> | null = null

function setNote(api: FcApi, name: string, text: string): void {
  api.updateRule(name, { props: { text } })
}

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  api.updateRule(name, { style: { display: hidden ? 'none' : '' } })
}

function refreshStartState(api: FcApi): void {
  const capital = Number.parseFloat(String(api.getValue('trainCapitalText') ?? '').replace(/[^0-9.]/g, ''))
  const accountType = String(api.getValue('trainAccountType') ?? 'percent')
  const ok = !!selected && startDate > 0 && !!range?.trainable
    && (accountType !== 'fixedAmount' || (Number.isFinite(capital) && capital > 0))
  api.updateRule('startBtn', { props: { disabled: !ok } })
}

async function savePrefs(patch: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('training', 'setPrefs', patch)
  } catch (e) {
    console.error('training.setPrefs 失败', e)
  }
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  let s: TrainingSetupSnapshot
  try {
    s = ((await klineBus.request('training', 'setup.snapshot')) ?? {}) as TrainingSetupSnapshot
  } catch (e) {
    console.error('training.setup.snapshot 失败', e)
    return
  }
  groups = s.groups ?? []
  api.setValue({
    trainCategory: '全部',
    trainAccountType: String(s.prefs?.accountType ?? 'percent'),
    trainCapitalText: String(s.prefs?.capitalText ?? '100000'),
    trainTradeMode: String(s.prefs?.tradeMode ?? 'sameDayClose'),
    trainKeyword: '',
    trainResults: { rows: [] },
    reselectOpen: false,
  })
  api.updateRule('groupChips', { props: { options: groups.map((g) => ({ label: g.name, value: g.id })) } })
  // 未选标的/未选日期（面板重开即复位）
  selected = null
  range = null
  startDate = 0
  api.updateRule('startDateRow', { props: { title: '未选择' } })
  setNote(api, 'dateRangeNote', '')
  setNote(api, 'warnLine', '')
  setNote(api, 'trainError', '')
  setRowHidden(api, 'groupTitle', true)
  setRowHidden(api, 'groupChips', true)
  setRowHidden(api, 'capitalRow', true)
  refreshStartState(api)
}

/** 抽中/选中后：拉日期区间并设起始日（抽中自带起始日；搜索选中随机一个自然日） */
async function applyTrainPick(api: FcApi, pick: { file: string; name: string; code: string; startDate?: number }): Promise<void> {
  try {
    const a = (await klineBus.request('training', 'anchor', { file: pick.file })) as Record<string, unknown>
    selected = { file: pick.file, name: pick.name, code: pick.code }
    range = { min: Number(a.minDate ?? 0), max: Number(a.maxDate ?? 0), trainable: a.trainable === true }
    api.updateRule('startDateRow', { props: { title: `${selected.name} ${selected.code}` } })
    const r = range
    if (r.trainable) {
      if (pick.startDate) startDate = pick.startDate
      else randomizeDate(api)
      api.updateRule('startDateRow', { props: { title: `${selected.name} ${selected.code} · ${ymd(startDate)}` } })
      api.setValue({ trainDate: ymd(startDate) })
      setNote(api, 'dateRangeNote', `可选区间 ${ymd(r.min)} ~ ${ymd(r.max)}`)
      setNote(api, 'warnLine', '')
    } else {
      startDate = 0
      setNote(api, 'dateRangeNote', '')
      setNote(api, 'warnLine', '该标的历史数据不足（需至少能取到最新库日期前 65 天）')
    }
    api.updateRule('randomDateBtn', { props: { disabled: !r.trainable } })
    refreshStartState(api)
  } catch (e) {
    console.error('training.anchor 失败', e)
  }
}

/** [min, max] 自然日随机（对齐原生 randomDate） */
function randomizeDate(api: FcApi): void {
  const r = range
  if (!r?.trainable || r.min <= 0 || r.max <= 0) return
  const lower = ymdToDate(r.min)
  const upper = ymdToDate(r.max)
  const days = Math.round((upper.getTime() - lower.getTime()) / 86_400_000)
  const offset = days > 0 ? Math.floor(Math.random() * (days + 1)) : 0
  startDate = dateToYmdInt(new Date(lower.getTime() + offset * 86_400_000))
  void api
}

function ymdToDate(v: number): Date {
  const s = String(v)
  return new Date(Number(s.slice(0, 4)), Number(s.slice(4, 6)) - 1, Number(s.slice(6, 8)))
}

function dateToYmdInt(d: Date): number {
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate()
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    pickRandom: (inj) => {
      const category = String(inj.api.getValue('trainCategory') ?? '全部')
      const accountType = String(inj.api.getValue('trainAccountType') ?? 'percent')
      const capital = accountType === 'fixedAmount'
        ? Number.parseFloat(String(inj.api.getValue('trainCapitalText') ?? '').replace(/[^0-9.]/g, '')) || null
        : null
      setNote(inj.api, 'trainError', '')
      void klineBus.request('training', 'pickRandom', {
        category,
        groupID: category === '我的分组' ? (String(inj.api.getValue('trainGroupID') ?? '') || null) : null,
        accountType,
        capital,
      }).then((data) => {
        const d = data as { file?: string; name?: string; code?: string; startDate?: number } | undefined
        if (d?.file) void applyTrainPick(inj.api, d as { file: string; name: string; code: string; startDate?: number })
      }).catch((e) => {
        setNote(inj.api, 'trainError', String((e as Error).message ?? e).replace(/^invalid_payload: /, ''))
      })
    },

    selectTarget: (inj) => {
      const row = inj.args[0] as { file: string; name: string; code: string } | undefined
      if (!row) return
      setNote(inj.api, 'trainError', '')
      inj.api.setValue({ trainKeyword: '', trainResults: { rows: [] } })
      void applyTrainPick(inj.api, row)
    },

    openDatePicker: (inj) => {
      // fc-date-picker 由字段触发弹层：聚焦字段即可（原生 popup 由组件内部管理）
      void inj
    },

    randomDate: (inj) => {
      randomizeDate(inj.api)
      if (selected && startDate > 0) {
        inj.api.updateRule('startDateRow', { props: { title: `${selected.name} ${selected.code} · ${ymd(startDate)}` } })
        inj.api.setValue({ trainDate: ymd(startDate) })
      }
      refreshStartState(inj.api)
    },

    startTraining: (inj) => {
      if (!selected || startDate <= 0) return
      setNote(inj.api, 'trainError', '')
      const accountType = String(inj.api.getValue('trainAccountType') ?? 'percent')
      void klineBus.request('training', 'begin', {
        file: selected.file,
        startDate,
        accountType,
        capital: accountType === 'fixedAmount'
          ? Number.parseFloat(String(inj.api.getValue('trainCapitalText') ?? '').replace(/[^0-9.]/g, '')) || null
          : null,
        tradeMode: String(inj.api.getValue('trainTradeMode') ?? 'sameDayClose'),
      }).catch((e) => {
        setNote(inj.api, 'trainError', String((e as Error).message ?? e).replace(/^invalid_payload: /, ''))
      })
    },

    clearTarget: (inj) => {
      selected = null
      range = null
      startDate = 0
      inj.api.updateRule('startDateRow', { props: { title: '未选择' } })
      setNote(inj.api, 'dateRangeNote', '')
      refreshStartState(inj.api)
    },
  },

  onChange: (field, value, api) => {
    switch (field) {
      case 'trainCategory': {
        const isGroup = value === '我的分组'
        setRowHidden(api, 'groupTitle', !isGroup)
        setRowHidden(api, 'groupChips', !isGroup)
        setNote(api, 'trainError', '')
        break
      }
      case 'trainAccountType': {
        const fixed = value === 'fixedAmount'
        setRowHidden(api, 'capitalRow', !fixed)
        setNote(api, 'accountNote', fixed
          ? '固定本金，买入前校验资金；开启训练要求本金至少买得起 2 手（200 股）'
          : '不占用资金，按仓位比例（1/4、1/3、1/2、全仓）买卖，任何标的都买得起')
        void savePrefs({ accountType: value })
        refreshStartState(api)
        break
      }
      case 'trainTradeMode': {
        setNote(api, 'tradeModeNote', value === 'sameDayClose'
          ? '点下单立刻以当前训练日收盘价成交（成交日 = 当前训练日）'
          : '隔日限价委托：点下单只挂单，仅下一训练日有效；该日行情触及委托价才按委托价成交，未触及即作废')
        void savePrefs({ tradeMode: value })
        break
      }
      case 'trainCapitalText':
        void savePrefs({ capitalText: String(value ?? '') })
        refreshStartState(api)
        break
      case 'trainKeyword': {
        if (searchTimer) clearTimeout(searchTimer)
        const kw = String(value ?? '').trim()
        if (!kw) {
          api.setValue({ trainResults: { rows: [] } })
          break
        }
        searchTimer = setTimeout(() => {
          void klineBus.request('training', 'search', { keyword: kw }).then((s) => {
            const data = (s ?? {}) as Record<string, unknown>
            const rows = (Array.isArray(data.results) ? (data.results as Record<string, unknown>[]) : []).map((r) => ({
              file: String(r.file ?? ''),
              name: String(r.name ?? ''),
              code: String(r.code ?? ''),
              mark: r.trainable === false ? '历史不足' : '',
              markTone: 'warn' as const,
            }))
            api.setValue({ trainResults: { rows } })
          }).catch((e) => console.error('training.search 失败', e))
        }, 300)
        break
      }
      case 'trainDate': {
        // date input 变更 → 起始日（钳制到区间内）
        const v = ymdInt(String(value ?? ''))
        if (!v) break
        const r = range
        startDate = r && r.min > 0 && r.max > 0 ? Math.min(Math.max(v, r.min), r.max) : v
        if (selected) {
          api.updateRule('startDateRow', { props: { title: `${selected.name} ${selected.code} · ${ymd(startDate)}` } })
        }
        refreshStartState(api)
        break
      }
    }
  },

  subscribe: (api) => {
    const handler = (ev: { payload?: Record<string, unknown> }): void => {
      const p = ev.payload ?? {}
      const reason = String(p['reason'] ?? '')
      const ctx = ctxRef
      if (reason === 'begun') {
        // 已开训：关面板进训练态
        ctx?.close()
      } else if (reason === 'beginFailed') {
        setNote(api, 'trainError', String(p['message'] ?? ''))
      } else if (reason === 'beginReselect') {
        api.updateRule('reselectDialog', { props: { message: String(p['message'] ?? '') } })
        api.setValue({ reselectOpen: true })
      } else if (reason === 'picked') {
        void applyTrainPick(api, p as unknown as { file: string; name: string; code: string; startDate?: number })
      } else if (reason === 'pickFailed') {
        setNote(api, 'trainError', String(p['message'] ?? ''))
      }
    }
    klineBus.on('training.changed', handler as never)
    return () => {
      ctxRef = null
    }
  },
}

export default adapter
