// fc/adapters/page-backtest.ts：回测页（page-backtest）逻辑适配器。
// 三子页：参数（本地表单，run 时一次写回 backtest.run）/ 进度 / 结果。
// phase/result 由原生 StrategyBacktestRunner 发布，backtest.changed 推送回读；
// 取消后自动回策略详情（仅运行态转入 cancelled 才关页）。
import { klineBus } from '../../bridge/klineBus'
import type { BacktestSnapshot } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'

type SubPage = 'params' | 'progress' | 'result'

let ctxRef: HostContext | null = null
let subPage: SubPage = 'params'
let prevPhase: string | null = null

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  api.updateRule(name, { style: { display: hidden ? 'none' : '' } })
}

/** 子页切换：显隐三段（无动态标题/右侧按钮需求，各子页 nav 已静态声明） */
function applySubPage(api: FcApi, page: SubPage): void {
  subPage = page
  api.setValue({
    paramsVisible: page === 'params',
    progressVisible: page === 'progress',
    resultVisible: page === 'result',
  })
}

/** 进度页内容（准备 / 逐日 / 失败 / 占位） */
function applyProgressPage(api: FcApi, snap: BacktestSnapshot): void {
  const p = snap.progress
  if (snap.phase === 'preparing') {
    api.setValue({ backtestProgress: { state: 'preparing', done: p?.done ?? 0, total: p?.total ?? 0 } })
    setRowHidden(api, 'cancelRunBtn', false)
    setRowHidden(api, 'failLine', true)
    setRowHidden(api, 'failBackBtn', true)
  } else if (snap.phase === 'simulating') {
    api.setValue({ backtestProgress: { state: 'simulating', done: 0, total: 0 } })
    setRowHidden(api, 'cancelRunBtn', false)
    setRowHidden(api, 'failLine', true)
    setRowHidden(api, 'failBackBtn', true)
  } else if (snap.phase === 'failed') {
    api.setValue({ backtestProgress: { state: 'failed' } })
    api.updateRule('failLine', { props: { text: snap.failMessage ?? '回测失败' } })
    setRowHidden(api, 'cancelRunBtn', true)
    setRowHidden(api, 'failLine', false)
    setRowHidden(api, 'failBackBtn', false)
  } else {
    api.setValue({ backtestProgress: { state: 'idle', done: 0, total: 0 } })
    setRowHidden(api, 'cancelRunBtn', true)
    setRowHidden(api, 'failLine', true)
    setRowHidden(api, 'failBackBtn', true)
  }
}

/** 结果页数据注入（指标 / 净值 / 明细 / 提示） */
function applyResult(api: FcApi, snap: BacktestSnapshot): void {
  const result = snap.result
  if (!result) {
    api.setValue({ emptyVisible: false, tradesVisible: false })
    return
  }
  const s = result.stats
  api.setValue({
    resultStats: {
      firstline: `初始资金 ${fmtAmount0(s.initialCapital)} → 期末净值 ${fmtAmount0(s.finalEquity)} · 平仓 ${s.roundTrips} 笔`,
      cells: [
        { title: '总收益', value: fmtPct(s.totalReturn), tone: changeClass(s.totalReturn) },
        { title: '年化', value: fmtPct(s.annualized), tone: changeClass(s.annualized) },
        { title: '最大回撤', value: fmtPct(-Math.abs(s.maxDrawdown)), tone: 'down' },
        { title: '胜率', value: fmtPct(s.winRate), tone: '' },
        { title: '盈亏比', value: s.profitFactor.toFixed(2), tone: '' },
        { title: '成交 / 平均持仓', value: `${s.tradeCount} 笔 · ${s.avgHoldDays.toFixed(1)} 天`, tone: '' },
      ],
    },
    netChart: { equity: result.equity, initialCapital: s.initialCapital, maxDrawdownRange: result.maxDrawdownRange },
    tradeTable: { rows: result.trades },
    emptyVisible: result.trades.length === 0,
    tradesVisible: result.trades.length > 0,
    noticeCard: {
      scanned: `扫描 ${result.scannedCount} 只 · 命中 ${result.hitCount} 只`,
      warnings: result.warnings,
      skipped: result.skipped,
    },
  })
}

function applyPhase(api: FcApi, snap: BacktestSnapshot): void {
  const prev = prevPhase
  prevPhase = snap.phase
  if (snap.phase === 'finished' && snap.result) {
    applyResult(api, snap)
    applySubPage(api, 'result')
  }
  if (snap.phase === 'cancelled' && (prev === 'preparing' || prev === 'simulating')) {
    // 取消后自动回策略详情（仅从运行态转入 cancelled 才关页）
    ctxRef?.close()
  }
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  let snap: BacktestSnapshot
  try {
    snap = ((await klineBus.request('backtest', 'snapshot')) ?? {}) as unknown as BacktestSnapshot
  } catch (e) {
    console.error('backtest.snapshot 失败', e)
    return
  }
  // 打开时按策略绑定账户初始化默认资金（对齐原生 init；用户已改则不覆盖）
  const cap = snap.doc?.defaultCapital
  const curCapital = String(api.getValue('capitalText') ?? '100000')
  const patch: Record<string, unknown> = {}
  if (cap && curCapital === '100000') patch.capitalText = plainNumber(cap)
  if (Object.keys(patch).length > 0) api.setValue(patch)
  api.updateRule('tradeWarn', { style: { display: snap.doc?.tradeEmpty ? '' : 'none' } })
  const running = snap.phase === 'preparing' || snap.phase === 'simulating'
  api.updateRule('paramsNav', { props: { rightDisabled: running } })
  prevPhase = snap.phase
  // 已有 finished 结果时（例如返回后重进）直接进结果页
  if (snap.phase === 'finished' && snap.result) {
    applyResult(api, snap)
    applySubPage(api, 'result')
  } else {
    applySubPage(api, 'params')
  }
}

async function run(api: FcApi): Promise<void> {
  const capital = Number.parseFloat(String(api.getValue('capitalText') ?? '').trim())
  try {
    await klineBus.request('backtest', 'run', {
      days: Number(api.getValue('days') ?? 250),
      initialCapital: Number.isFinite(capital) && capital > 0 ? capital : 100000,
      pool: String(api.getValue('pool') ?? 'market'),
      executeNextOpen: api.getValue('executeNextOpen') === true,
      includeEntry: api.getValue('includeEntry') === true,
    })
    applySubPage(api, 'progress')
  } catch (e) {
    console.error('backtest.run 失败', e)
  }
}

function cancelAndClose(): void {
  // 对齐原生 closeBacktestRun：运行中先取消，再回详情页
  void klineBus.request('backtest', 'cancel').catch(() => {})
  ctxRef?.close()
}

// ===== 格式化（对齐 SimFormat：红涨绿跌、千分位、带符号） =====

function plainNumber(v: number): string {
  return v === Math.round(v) ? String(Math.round(v)) : String(v)
}

function fmtAmount0(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function fmtPct(ratio: number): string {
  const v = ratio * 100
  return (v < 0 ? '-' : '+') + Math.abs(v).toFixed(2) + '%'
}

/** A 股语义：盈利红 / 亏损绿 */
function changeClass(v: number): string {
  if (v < 0) return 'down'
  if (v > 0) return 'up'
  return ''
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    run: (inj) => void run(inj.api),

    cancelAndClose: () => cancelAndClose(),

    closePage: () => ctxRef?.close(),

    capitalChip: (inj) => {
      const value = inj.args[0]
      if (value !== undefined && value !== null) inj.api.setValue({ capitalText: String(value) })
    },
  },

  subscribe: (api) => {
    const handler = (): void => {
      void klineBus.request('backtest', 'snapshot').then((s) => {
        const snap = (s ?? {}) as unknown as BacktestSnapshot
        api.updateRule('tradeWarn', { style: { display: snap.doc?.tradeEmpty ? '' : 'none' } })
        if (snap.phase === 'preparing' || snap.phase === 'simulating' || snap.phase === 'failed') {
          applyProgressPage(api, snap)
        }
        applyPhase(api, snap)
      }).catch((e) => console.error('backtest.changed 回读失败', e))
    }
    klineBus.on('backtest.changed', handler)
    return () => {
      ctxRef = null
    }
  },
}

export default adapter
