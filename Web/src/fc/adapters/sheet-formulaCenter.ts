// fc/adapters/sheet-formulaCenter.ts：公式中心（sheet-formulaCenter）逻辑适配器。
// 快照：chart.formula.snapshot；删除：chart.formula.deleteCustom（toast + 回读）；
// 编辑/新建直进 Web 公式编辑器全屏页（chart.formula.openEditor + 关本面板）。
import { klineBus } from '../../bridge/klineBus'
import { showToast } from 'vant'
import 'vant/es/toast/style'
import type { FcApi, FcInject, FcPageAdapter } from '../types'

interface FormulaSnapshot {
  period: string
  mainItems: { id: string; name: string; isSystem: boolean; hasTemplate: boolean }[]
  subGroups: { group: string; kinds: string[] }[]
  customs: { id: string; name: string; colorHex: string; scope: 'main' | 'sub'; periods: string[] }[]
}

async function pull(api: FcApi): Promise<void> {
  let f: FormulaSnapshot
  try {
    f = ((await klineBus.request('chart', 'formula.snapshot')) ?? {}) as FormulaSnapshot
  } catch (e) {
    console.error('formula.snapshot 失败', e)
    return
  }
  api.updateRule('periodTitle', { props: { text: `技术指标 · ${f.period ?? ''}` } })
  api.setValue({
    system: {
      sections: [
        {
          title: '系统指标 · 主图',
          rows: (f.mainItems ?? []).map((d) => ({ id: d.id, name: d.name, hasTemplate: d.hasTemplate === true, isMain: true })),
        },
        ...(f.subGroups ?? []).map((g) => ({
          title: `系统指标 · ${g.group}`,
          rows: (g.kinds ?? []).map((k) => ({ id: k, name: k, hasTemplate: true, isMain: false })),
        })),
      ],
    },
    customs: {
      rows: (f.customs ?? []).map((c) => ({
        id: c.id,
        name: c.name,
        colorHex: c.colorHex,
        active: false,
        note: `${c.scope === 'main' ? '主图' : '副图'} · ${(c.periods ?? []).length} 周期`,
      })),
      showActivate: false,
      showDelete: true,
      deleteAria: 'formulaCenter.deleteCustom',
      editAria: 'formulaCenter.editCustom',
      emptyText: '暂无自定义技术指标',
    },
  })
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    editSystem: (inj, ctx) => {
      const row = inj.args[0] as { id: string; isMain?: boolean } | undefined
      if (!row) return
      // 编辑直进 Web 编辑器全屏页（原生侧关面板 + 打开 formulaEditor）
      klineBus.request('chart', 'formula.openEditor', {
        target: 'system', id: row.id, isMain: row.isMain !== false,
      } as unknown as Record<string, unknown>).catch((e) => console.error(e))
      ctx.close()
    },

    openNew: (inj, ctx) => {
      klineBus.request('chart', 'formula.openEditor', { target: 'custom' } as unknown as Record<string, unknown>)
        .catch((e) => console.error(e))
      void inj
      ctx.close()
    },

    editCustom: (inj, ctx) => {
      const row = inj.args[0] as { id: string } | undefined
      if (!row) return
      klineBus.request('chart', 'formula.openEditor', { target: 'custom', id: row.id } as unknown as Record<string, unknown>)
        .catch((e) => console.error(e))
      ctx.close()
    },

    deleteCustom: (inj) => {
      const row = inj.args[0] as { id: string; name: string } | undefined
      if (!row) return
      void klineBus.request('chart', 'formula.deleteCustom', { id: row.id }).then(() => {
        showToast({ message: `已删除「${row.name}」`, duration: 1600 })
        return pull(inj.api)
      }).catch((e) => {
        showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
      })
    },
  },
}

export default adapter
