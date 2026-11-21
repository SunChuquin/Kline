// fc/adapters/sheet-settings.ts：K线设置弹层（sheet-settings）逻辑适配器。
// 快照：chart.settings.snapshot；写回：chart.settings.set / settings.resetLinked；
// 组合编辑跳转：preset.openEditor；弹层内 ActionSheet 四种 picker + 重置确认 Dialog。
import { klineBus } from '../../bridge/klineBus'
import { showToast } from 'vant'
import 'vant/es/toast/style'
import type { FcApi, FcInject, FcPageAdapter, HostContext } from '../types'

interface ChartOption {
  label: string
  value: unknown
}

interface SettingsSnapshot {
  period: string
  periodOptions: ChartOption[]
  chartStyle: string
  styleOptions: ChartOption[]
  linkedViewCount: number
  viewCountOptions: ChartOption[]
  showGap: boolean
  gapDisappearAfterFill: boolean
  showLatestPriceLine: boolean
  indicatorNotSqueezeKline: boolean
  showBareK: boolean
  activeMode: string
  presetOptions: ChartOption[]
}

let snapshot: SettingsSnapshot | null = null
let pickerKind: 'period' | 'chartStyle' | 'viewCount' | 'preset' | null = null

/** preset.changed 单例订阅（klineBus 无 off API；面板重挂载不重复注册） */
let activeApi: FcApi | null = null
let presetSubscribed = false

function ensurePresetSub(): void {
  if (presetSubscribed) return
  presetSubscribed = true
  klineBus.on('preset.changed', () => {
    const api = activeApi
    if (!api) return
    void klineBus.request('chart', 'settings.snapshot').then((s) => {
      const snap = s as Record<string, unknown> | undefined
      if (!snap) return
      const mode = String(snap.activeMode ?? 'local')
      const opts = (snap.presetOptions ?? []) as ChartOption[]
      if (snapshot) {
        snapshot.activeMode = mode
        snapshot.presetOptions = opts
      }
      api.updateRule('presetRow', { props: { value: opts.find((o) => o.value === mode)?.label ?? mode } })
    }).catch((e) => console.error('preset.changed 刷新失败', e))
  })
}

function presetLabel(s: SettingsSnapshot): string {
  return s.presetOptions.find((o) => o.value === s.activeMode)?.label ?? s.activeMode
}

async function setSetting(key: string, value: unknown): Promise<void> {
  try {
    await klineBus.request('chart', 'settings.set', { [key]: value })
  } catch (e) {
    console.error('settings.set 失败', e)
  }
}

function toActions(opts: ChartOption[]): { name: string; value: string }[] {
  return opts.map((o) => ({ name: o.label, value: String(o.value) }))
}

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  const s = ((await klineBus.request('chart', 'settings.snapshot')) ?? {}) as Record<string, unknown>
  snapshot = {
    period: String(s.period ?? '日线'),
    periodOptions: (s.periodOptions ?? []) as ChartOption[],
    chartStyle: String(s.chartStyle ?? ''),
    styleOptions: (s.styleOptions ?? []) as ChartOption[],
    linkedViewCount: typeof s.linkedViewCount === 'number' ? s.linkedViewCount : 2,
    viewCountOptions: (s.viewCountOptions ?? []) as ChartOption[],
    showGap: s.showGap === true,
    gapDisappearAfterFill: s.gapDisappearAfterFill === true,
    showLatestPriceLine: s.showLatestPriceLine === true,
    indicatorNotSqueezeKline: s.indicatorNotSqueezeKline === true,
    showBareK: s.showBareK === true,
    activeMode: String(s.activeMode ?? 'local'),
    presetOptions: (s.presetOptions ?? []) as ChartOption[],
  }
  pickerKind = null
  api.setValue({
    showGap: snapshot.showGap,
    gapDisappearAfterFill: snapshot.gapDisappearAfterFill,
    showLatestPriceLine: snapshot.showLatestPriceLine,
    indicatorNotSqueezeKline: snapshot.indicatorNotSqueezeKline,
    showBareK: snapshot.showBareK,
    pickerOpen: false,
    resetConfirm: false,
  })
  api.updateRule('periodRow', { props: { value: snapshot.period } })
  api.updateRule('viewCountRow', { props: { value: `${snapshot.linkedViewCount} 个视图` } })
  api.updateRule('presetRow', { props: { value: presetLabel(snapshot) } })
  api.updateRule('styleRow', { props: { value: snapshot.chartStyle } })
  void ctx
}

function openPicker(kind: 'period' | 'chartStyle' | 'viewCount' | 'preset'): (inj: FcInject, ctx: HostContext) => void {
  return (_inj, ctx) => {
    const s = snapshot
    if (!s) return
    pickerKind = kind
    const api = _inj.api
    const opts = kind === 'period' ? s.periodOptions
      : kind === 'chartStyle' ? s.styleOptions
      : kind === 'preset' ? s.presetOptions
      : s.viewCountOptions
    api.setValue({ pickerActions: toActions(opts), pickerOpen: true })
    void ctx
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    openPeriod: openPicker('period'),
    openChartStyle: openPicker('chartStyle'),
    openPreset: openPicker('preset'),
    openViewCount: openPicker('viewCount'),

    openPresetEditor: (_inj, _ctx) => {
      void klineBus.request('preset', 'openEditor', {}).catch((e) => console.error('preset.openEditor 失败', e))
    },

    resetLinked: (inj) => {
      inj.api.setValue({ resetConfirm: true })
    },

    doResetLinked: (inj) => {
      inj.api.setValue({ resetConfirm: false })
      void klineBus.request('chart', 'settings.resetLinked', {}).catch((e) => console.error('resetLinked 失败', e))
    },

    pickerSelect: (inj) => {
      const s = snapshot
      const action = inj.args[0] as { name: string; value: string } | undefined
      if (!s || !action || !pickerKind) return
      switch (pickerKind) {
        case 'period':
          void setSetting('period', action.name)
          break
        case 'chartStyle':
          void setSetting('chartStyle', action.name)
          break
        case 'viewCount':
          void setSetting('linkedViewCount', Number(action.value))
          break
        case 'preset':
          void setSetting('activeMode', action.value)
          break
      }
      inj.api.setValue({ pickerOpen: false })
    },
  },

  onChange: (field, value, api, ctx) => {
    // 五个显示开关：即时写回（幂等目标态，面板保持打开）
    const toggles = ['showGap', 'gapDisappearAfterFill', 'showLatestPriceLine', 'indicatorNotSqueezeKline', 'showBareK']
    if (toggles.includes(field)) {
      void setSetting(field, value)
      return
    }
    void api
    void ctx
  },

  subscribe: (api) => {
    ensurePresetSub()
    activeApi = api
    return () => {
      activeApi = null
    }
  },
}

export default adapter
