// fc/format.ts：共享数值格式化（从 SheetPage 抽出，红涨绿跌口径对齐原生
// MarketRow.render / SimFormat）。供 adapter 与 k-* 组件共同使用。

export function fmtPrice(v: number | null | undefined): string {
  return v === null || v === undefined ? '—' : v.toFixed(2)
}

export function fmtPctRaw(v: number): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}%`
}

export function fmtPct(v: { pct: number | null | undefined }): string {
  return v.pct === null || v.pct === undefined ? '—' : fmtPctRaw(v.pct)
}

export function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

export function fmtShares(v: number): string {
  return v.toLocaleString('en-US')
}

export function fmtSigned0(v: number): string {
  return `${v > 0 ? '+' : ''}${Math.round(v).toLocaleString('en-US')}`
}

/** 涨跌幅着色类（up/down/空） */
export function pctClass(q: { pct: number | null | undefined }): string {
  const p = q.pct ?? 0
  return p > 0 ? 'up' : p < 0 ? 'down' : ''
}

/** 涨跌幅 pill 类 */
export function pillClass(q: { pct: number | null | undefined }): string {
  const p = q.pct ?? 0
  return p > 0 ? 'pill-up' : p < 0 ? 'pill-down' : 'pill-flat'
}

/** 金额盈亏类 */
export function profitClass(v: number): string {
  return v < 0 ? 'down' : 'up'
}

/** YYYYMMDD → YYYY-MM-DD（date input 用） */
export function ymd(v: number): string {
  const s = String(v)
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s
}

/** YYYY-MM-DD → YYYYMMDD（本地时区，避免 UTC 偏移） */
export function ymdInt(text: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text)
  if (!m) return 0
  return Number(m[1]) * 10000 + Number(m[2]) * 100 + Number(m[3])
}
