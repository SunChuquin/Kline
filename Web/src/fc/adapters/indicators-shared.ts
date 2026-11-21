// fc/adapters/indicators-shared.ts：主图/副图指标面板共用逻辑（写回模式 v2）。
// 快照：chart.indicators.snapshot；动作经 chart.indicators.<action> 写回后回读快照。
import { klineBus } from '../../bridge/klineBus'
import type { FcApi, FcInject, FcPageAdapter, HostContext } from '../types'

interface IndicatorDefSnap { id: string; name: string; on: boolean }
interface CustomIndicatorSnap { id: string; name: string; colorHex: string; active: boolean }
interface SubSlotSnap {
  slot: string
  title: string
  kind: string
  customID: string | null
  hasTemplate: boolean
  groups: { group: string; kinds: string[] }[]
  customs: CustomIndicatorSnap[]
}
interface IndicatorsSnapshot {
  period: string
  mainDefs: IndicatorDefSnap[]
  mainCustoms: CustomIndicatorSnap[]
  subSlots: SubSlotSnap[]
}

/** 主图模式 or 副图模式（ctx.pageName 区分） */
function isMainMode(pageName: string): boolean {
  return pageName === 'sheet-mainIndicators'
}

/** 指标写回公共路径：动作成功即回读快照（重算由原生 recomputeHandler 执行） */
async function actIndicators(api: FcApi, action: string, payload: Record<string, unknown>, ctx: HostContext): Promise<void> {
  try {
    await klineBus.request('chart', `indicators.${action}`, payload)
    await pull(api, ctx)
  } catch (e) {
    console.error(`indicators.${action} 失败`, e)
  }
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  let s: IndicatorsSnapshot
  try {
    const snap = ((await klineBus.request('chart', 'indicators.snapshot')) ?? {}) as Record<string, unknown>
    s = {
      period: String(snap.period ?? ''),
      mainDefs: (snap.mainDefs ?? []) as IndicatorDefSnap[],
      mainCustoms: (snap.mainCustoms ?? []) as CustomIndicatorSnap[],
      subSlots: (snap.subSlots ?? []) as SubSlotSnap[],
    }
  } catch (e) {
    console.error('indicators.snapshot 失败', e)
    return
  }

  if (isMainMode(ctx.pageName)) {
    api.setValue({
      mainTiles: {
        sections: [{ title: '技术指标公式 · 主图', tiles: s.mainDefs.map((d) => ({
          id: d.id, label: d.name, on: d.on === true, ariaLabel: `chart.indicator.main.${d.name}`,
        })) }],
        checkable: true,
      },
      mainCustoms: {
        rows: s.mainCustoms.map((c) => ({ id: c.id, name: c.name, colorHex: c.colorHex, active: c.active === true })),
        showCurrent: false,
        emptyText: '暂无主图自定义技术指标',
      },
    })
    return
  }

  // 副图模式：sheet.open 可带 slot 定向（无则取首个）
  const wantSlot = typeof ctx.openPayload?.slot === 'string' ? ctx.openPayload.slot : null
  const slot = (wantSlot ? s.subSlots.find((x) => x.slot === wantSlot) : null) ?? s.subSlots[0] ?? null
  api.setValue({
    subTiles: {
      sections: (slot?.groups ?? []).map((g) => ({
        title: g.group,
        tiles: (g.kinds ?? []).map((k) => ({
          id: k, label: k,
          on: !slot?.customID && slot?.kind === k,
          ariaLabel: `chart.indicator.sub.${slot?.slot ?? ''}.${k}`,
        })),
      })),
      checkable: false,
    },
    subCustoms: {
      rows: (slot?.customs ?? []).map((c) => ({ id: c.id, name: c.name, colorHex: c.colorHex, active: c.active === true })),
      showCurrent: true,
      emptyText: '暂无副图自定义技术指标',
    },
  })
  api.updateRule('subSlotTitle', { props: { text: `选择副图指标 · ${slot?.title ?? ''}` } })
  const showSystem = !slot?.customID && slot?.hasTemplate === true
  api.updateRule('subSystemEntry', { props: { label: `⚙ ${slot?.kind ?? ''} 公式编辑 · 技术指标公式 ›` } })
  try {
    api.hidden(!showSystem, 'subSystemEntry')
  } catch {
    // 旧版 API 无 hidden：用样式兜底
    api.updateRule('subSystemEntry', { style: { display: showSystem ? '' : 'none' } })
  }
}

function makeAdapter(mode: 'main' | 'sub'): FcPageAdapter {
  return {
    pull,

    actions: {
      toggleMain: (inj, ctx) => {
        const id = inj.args[0] as string
        const tiles = inj.api.getValue('mainTiles') as { sections: { tiles: { id: string; on: boolean }[] }[] }
        const tile = tiles?.sections[0]?.tiles.find((t) => t.id === id)
        if (!tile) return
        void actIndicators(inj.api, 'toggleMain', { id, on: !tile.on }, ctx)
      },

      selectSubKind: (inj, ctx) => {
        const kind = inj.args[0] as string
        void klineBus.request('chart', 'indicators.snapshot').then((snap) => {
          const slot = ((snap ?? {}) as IndicatorsSnapshot).subSlots[0]
          if (!slot) return
          return actIndicators(inj.api, 'selectSub', { slot: slot.slot, kind }, ctx)
        }).catch((e) => console.error(e))
      },

      selectSubCustom: (inj, ctx) => {
        const row = inj.args[0] as { id: string } | undefined
        if (!row) return
        void klineBus.request('chart', 'indicators.snapshot').then((snap) => {
          const slot = ((snap ?? {}) as IndicatorsSnapshot).subSlots[0]
          if (!slot) return
          return actIndicators(inj.api, 'selectSub', { slot: slot.slot, customID: row.id }, ctx)
        }).catch((e) => console.error(e))
      },

      activateMainCustom: (inj, ctx) => {
        const row = inj.args[0] as { id: string; active: boolean } | undefined
        if (!row) return
        void actIndicators(inj.api, 'activateMainCustom', { customID: row.active ? null : row.id }, ctx)
      },

      openSystemEditorMain: (inj, ctx) => {
        void actIndicators(inj.api, 'openSystemEditor', { isMain: true, subId: null }, ctx)
        ctx.close()   // 原生同款交互：先关面板再进编辑器（原生编辑器盖全屏）
      },

      openSystemEditorSub: (inj, ctx) => {
        void klineBus.request('chart', 'indicators.snapshot').then((snap) => {
          const slot = ((snap ?? {}) as IndicatorsSnapshot).subSlots[0]
          return actIndicators(inj.api, 'openSystemEditor', { isMain: false, subId: slot?.kind ?? null }, ctx)
        }).catch((e) => console.error(e))
        ctx.close()
      },

      openCustomMain: (inj, ctx) => {
        void actIndicators(inj.api, 'openCustomEditor', { target: 'main' }, ctx)
        ctx.close()
      },

      openCustomSub: (inj, ctx) => {
        void actIndicators(inj.api, 'openCustomEditor', { target: 'sub' }, ctx)
        ctx.close()
      },

      resetBuiltinAsk: (inj) => {
        inj.api.setValue({ resetBuiltinConfirm: true })
      },

      doResetBuiltin: (inj, ctx) => {
        inj.api.setValue({ resetBuiltinConfirm: false })
        void actIndicators(inj.api, 'resetBuiltin', {}, ctx)
      },
    },
  }
}

export default makeAdapter
