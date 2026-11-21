// fc/adapters/page-pythonLab.ts：Python 引擎实验室页（page-pythonLab）逻辑适配器。
// 快照：lab.snapshot；动作：refresh / download / install / loadEngine / runExp(①-④) /
// cleanDownloads / exportCrash；输出行经 lab.changed 推送回读（host.objectWillChange 节流）。
// 行启用/转圈语义对齐原生 actionRow 的 enabled/showSpinner。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'
import type { SnapRow } from '../components/KSnapCard.vue'

type LabStatus = 'notInstalled' | 'installed' | 'versionMismatch' | 'corrupted'

interface LabSnapshot {
  status: LabStatus
  apiVersion: number | null
  statusText: string
  source: string
  appPath: string
  manifest: string
  isLoaded: boolean
  isBusy: boolean
  busyText: string
  downloadPercent: number
  runningExp: number
  outputLines: string[]
}

let snap: LabSnapshot | null = null

function safe(fn: () => void, tag: string): void {
  try {
    fn()
  } catch (e) {
    console.warn(`[fc] pythonLab ${tag} 跳过（面板可能已关闭）`, e)
  }
}

// ===== 行启用/转圈语义（对齐源 downloading / loadingSpinner / loadEnabled / expEnabled / expSpinner） =====

function downloading(s: LabSnapshot | null): boolean {
  return !!s?.isBusy && (s.busyText ?? '').startsWith('下载引擎包')
}

function loadingSpinner(s: LabSnapshot | null): boolean {
  const t = s?.busyText ?? ''
  return !!s?.isBusy && (t.startsWith('dlopen') || t.startsWith('Py_Initialize'))
}

function loadEnabled(s: LabSnapshot | null): boolean {
  return !!s && !s.isBusy && s.status === 'installed' && !s.isLoaded
}

function expEnabled(s: LabSnapshot | null, id: number): boolean {
  if (!s) return false
  if (id <= 3) return !s.isBusy && s.status === 'installed'
  // 实验④：进程内桥接，要求引擎空闲且未在跑其它实验
  return !s.isBusy && s.runningExp === 0 && s.status === 'installed'
}

function expSpinner(s: LabSnapshot | null, id: number): boolean {
  if (!s) return false
  if (id <= 3) return !!s.isBusy && s.busyText === 'pyrunner 运行脚本…' && s.runningExp === id
  return s.runningExp === 4
}

function statusTone(s: LabSnapshot | null): string {
  switch (s?.status) {
    case 'installed': return 'tone-green'
    case 'versionMismatch': return 'tone-yellow'
    case 'corrupted': return 'tone-red'
    default: return ''
  }
}

function buildStatusRows(s: LabSnapshot | null): SnapRow[] {
  return [
    { button: true, title: '刷新状态', glyph: '⟳', iconTone: 'state-blue', disabled: !!s?.isBusy, act: 'refresh' },
    { title: '当前状态', value: s?.statusText ?? '—', tone: statusTone(s), wrap: true },
    { title: '引擎来源', value: s?.source ?? '—' },
    { title: '引擎路径', value: s?.appPath ?? '—', wrap: true },
    { title: '引擎版本', value: s?.manifest ?? '—' },
    {
      title: '解释器',
      value: s?.isLoaded ? '已加载（进程内常驻）' : '未加载',
      tone: s?.isLoaded ? 'tone-green' : '',
    },
  ]
}

function expRow(s: LabSnapshot | null, id: number, title: string, glyph: string, act: string): SnapRow {
  const enabled = expEnabled(s, id)
  const spinning = expSpinner(s, id)
  return {
    button: true,
    title,
    dim: !enabled,
    glyph: spinning ? '◌' : glyph,
    iconTone: spinning ? 'state-yellow' : enabled ? 'state-blue' : 'state-gray',
    disabled: !enabled,
    act,
  }
}

function buildOpsRows(s: LabSnapshot | null): SnapRow[] {
  return [
    {
      button: true,
      title: '下载引擎包（.tipa）',
      dim: !!s?.isBusy,
      glyph: downloading(s) ? String(s?.downloadPercent ?? 0) : s?.isBusy ? '◌' : '⤓',
      iconTone: downloading(s) || s?.isBusy ? 'state-yellow' : 'state-blue',
      disabled: !!s?.isBusy,
      act: 'download',
    },
    { button: true, title: '用 TrollStore 安装', dim: !!s?.isBusy, glyph: '▣', iconTone: 'state-blue', disabled: !!s?.isBusy, act: 'install' },
    {
      button: true,
      title: '加载引擎（进程内 dlopen+init 计时）',
      dim: !loadEnabled(s),
      glyph: loadingSpinner(s) ? '◌' : '▶',
      iconTone: loadingSpinner(s) ? 'state-yellow' : loadEnabled(s) ? 'state-blue' : 'state-gray',
      disabled: !loadEnabled(s),
      act: 'loadEngine',
    },
    expRow(s, 1, '实验① 最小脚本（隔离）', '①', 'exp1'),
    expRow(s, 2, '实验② 冷启动与150根计时（隔离）', '②', 'exp2'),
    expRow(s, 3, '实验③ 并发吞吐（隔离）', '③', 'exp3'),
    expRow(s, 4, '实验④ 首帧端到端（进程内桥接）', '④', 'exp4'),
    {
      button: true,
      title: '清理下载文件',
      dim: !!s?.isBusy,
      danger: true,
      glyph: '✕',
      iconTone: s?.isBusy ? 'state-gray' : 'state-red',
      disabled: !!s?.isBusy,
      act: 'cleanDownloads',
    },
    {
      button: true,
      title: '导出崩溃报告',
      dim: !!s?.isBusy,
      glyph: '⤓',
      iconTone: s?.isBusy ? 'state-gray' : 'state-blue',
      disabled: !!s?.isBusy,
      act: 'exportCrash',
    },
  ]
}

async function pull(api: FcApi): Promise<void> {
  try {
    snap = ((await klineBus.request('lab', 'snapshot')) ?? {}) as unknown as LabSnapshot
  } catch (e) {
    console.error('lab.snapshot 失败', e)
    return
  }
  const downloadingNow = downloading(snap)
  safe(() => {
    api.setValue({
      cardStatus: { rows: buildStatusRows(snap) },
      cardOps: { rows: buildOpsRows(snap) },
      busy: {
        show: !!snap?.isBusy,
        text: snap?.busyText ?? '',
        pct: downloadingNow ? snap?.downloadPercent ?? 0 : null,
      },
      output: { lines: snap?.outputLines ?? [] },
    })
  }, 'pull')
}

function act(action: string, payload?: Record<string, unknown>): Promise<void> {
  return klineBus.request('lab', action, payload).then(() => undefined).catch((e) => {
    console.error(`lab.${action} 失败`, e)
  })
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    rowAct: (inj) => {
      const api = inj.api
      const actName = String(inj.args[0] ?? '')
      switch (actName) {
        case 'refresh':
          void act('refresh').then(() => pull(api))
          break
        case 'download':
          void act('download').then(() => pull(api))
          break
        case 'install':
          void act('install').then(() => pull(api))
          break
        case 'loadEngine':
          void act('loadEngine').then(() => pull(api))
          break
        case 'exp1':
        case 'exp2':
        case 'exp3':
        case 'exp4':
          void act('runExp', { id: Number(actName.slice(3)) }).then(() => pull(api))
          break
        case 'cleanDownloads':
          void act('cleanDownloads').then(() => pull(api))
          break
        case 'exportCrash':
          void act('exportCrash').then(() => pull(api))
          break
      }
    },
  },

  subscribe: (api) => {
    // klineBus 无 off：面板卸载后 pull 内 safe() 静默跳过陈旧 api 调用
    klineBus.on('lab.changed', () => void pull(api))
    return () => {}
  },
}

export default adapter
