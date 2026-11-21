// fc/adapters/page-search.ts：搜索页（page-search）逻辑适配器。
// 查询：search.query（300ms 防抖，与 chart.search.query 同口径 searchMeta）；
// 选中：search.openDetail（原生 openDetail 成功后自动关搜索页进详情）。
import { klineBus } from '../../bridge/klineBus'
import type { FcApi, FcPageAdapter } from '../types'

let searchTimer: ReturnType<typeof setTimeout> | null = null
let latestSeq = 0

function syncClearBtn(api: FcApi, keyword: string): void {
  try {
    api.updateRule('searchClearBtn', { style: { display: keyword ? '' : 'none' } })
  } catch (e) {
    console.warn('[fc] search syncClearBtn 跳过（面板可能已关闭）', e)
  }
}

function resetResults(api: FcApi): void {
  latestSeq += 1
  api.setValue({ results: { rows: [], emptyText: '' } })
  syncClearBtn(api, '')
}

const adapter: FcPageAdapter = {
  // 无快照：打开即空态（字段默认值由规则 JSON 提供）
  pull: async () => {},

  actions: {
    clearSearch: (inj) => {
      inj.api.setValue({ keyword: '' })
      resetResults(inj.api)
    },

    pick: (inj) => {
      const row = inj.args[0] as { file: string } | undefined
      if (!row) return
      // 原生 openDetail 成功后自动关搜索页并进详情（Web 不主动 close）
      void klineBus.request('search', 'openDetail', { file: row.file }).catch((e) => console.error(e))
      inj.api.setValue({ keyword: '' })
      resetResults(inj.api)
    },
  },

  onChange: (field, value, api) => {
    if (field !== 'keyword') return
    if (searchTimer) clearTimeout(searchTimer)
    const kw = String(value ?? '').trim()
    syncClearBtn(api, kw)
    if (!kw) {
      resetResults(api)
      return
    }
    // 300ms 防抖 + 序号防乱序（慢响应回包晚于新查询时丢弃）
    const seq = ++latestSeq
    searchTimer = setTimeout(() => {
      void klineBus.request('search', 'query', { keyword: kw }).then((s) => {
        if (seq !== latestSeq) return
        const data = (s ?? {}) as Record<string, unknown>
        const rows = (Array.isArray(data.results) ? (data.results as Record<string, unknown>[]) : []).map((r) => ({
          file: String(r.file ?? ''),
          name: String(r.name ?? ''),
          code: String(r.code ?? ''),
          type: String(r.type ?? ''),
        }))
        api.setValue({ results: { rows, emptyText: rows.length === 0 ? '没有匹配的标的' : '' } })
      }).catch((e) => console.error('search.query 失败', e))
    }, 300)
  },
}

export default adapter
