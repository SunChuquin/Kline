// fc/adapters/sheet-search.ts：图表搜索弹层（sheet-search）逻辑适配器。
// 查询：chart.search.query（300ms 防抖）；选中：chart.search.pick（原生侧成功后自动关层）。
import { klineBus } from '../../bridge/klineBus'
import type { FcPageAdapter } from '../types'

let searchTimer: ReturnType<typeof setTimeout> | null = null

const adapter: FcPageAdapter = {
  // 无快照：打开即空态（字段默认值由规则 JSON 提供）
  pull: async () => {},

  actions: {
    close: (_inj, ctx) => {
      void ctx
      // host 兜底已处理 data-act=close；此处无需逻辑
    },

    pickResult: (inj, ctx) => {
      const row = inj.args[0] as { file: string } | undefined
      if (!row) return
      // 原生侧 pick 成功后自动 close（浮层遮罩由 Swift 切走）
      klineBus.request('chart', 'search.pick', { file: row.file }).catch((e) => console.error(e))
      inj.api.setValue({ keyword: '', results: { rows: [] } })
      ctx.close()
    },
  },

  onChange: (field, value, api) => {
    if (field !== 'keyword') return
    if (searchTimer) clearTimeout(searchTimer)
    const kw = String(value ?? '').trim()
    if (!kw) {
      api.setValue({ results: { rows: [] } })
      return
    }
    searchTimer = setTimeout(() => {
      void klineBus.request('chart', 'search.query', { keyword: kw }).then((s) => {
        const data = (s ?? {}) as Record<string, unknown>
        const rows = (Array.isArray(data.results) ? (data.results as Record<string, unknown>[]) : []).map((r) => ({
          file: String(r.file ?? ''),
          code: String(r.code ?? ''),
          name: String(r.name ?? ''),
        }))
        api.setValue({ results: { rows } })
      }).catch((e) => console.error('search.query 失败', e))
    }, 300)
  },
}

export default adapter
