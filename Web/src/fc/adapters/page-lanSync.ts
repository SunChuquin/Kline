// fc/adapters/page-lanSync.ts：联机同步页（page-lanSync）逻辑适配器。
// 快照：lan.snapshot；动作：probe / setExposed / scan / connect / start；
// 子页切换（devices/configure/running）/ 勾选粒度 / 展开集合 / 手动直连输入 = 本地态；
// 传输 phase/progress 经 lan.changed 推送回读（无轮询，与源面板一致）。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

interface LANPeerSnap {
  id: string
  name: string
  host: string
  port: number
}

interface LANCategorySnap {
  key: string
  title: string
  localSummary: string
  remoteSummary: string
  hasChildren: boolean
  children: { key: string; name: string; quantity: string }[]
}

interface LANSSnapshot {
  serverOnline: boolean
  probing: boolean
  port: number
  deviceName: string
  isExposed: boolean
  isBrowsing: boolean
  connecting: boolean
  peers: LANPeerSnap[]
  busy: boolean
  transfer: {
    phase: 'idle' | 'pairing' | 'transferring' | 'done' | 'failed'
    progress: number
    bytesPerSecond: number
    currentFile: string
    resultSummary: string
    backupDir: string | null
    needsRestart: boolean
    failMessage: string | null
  }
  configure: {
    peer: { name: string; host: string; port: number; appVersion: string }
    categories: LANCategorySnap[]
  } | null
}

type SubPage = 'devices' | 'configure' | 'running'
type Pick = 'none' | 'all' | string[]

let snap: LANSSnapshot | null = null
let subPage: SubPage = 'devices'
/** 各类别勾选粒度（未选 / 整类全选 / 自定义子项集合），语义对齐原生 CategoryPick */
let picks: Record<string, Pick> = {}
let expanded: Record<string, boolean> = {}

/** 程序化回填的安全包装：面板卸载（宿主重挂载/关闭）后 api 调用静默跳过 */
function safe(fn: () => void, tag: string): void {
  try {
    fn()
  } catch (e) {
    console.warn(`[fc] lanSync ${tag} 跳过（面板可能已关闭）`, e)
  }
}

function applyTransfer(api: FcApi): void {
  const tr = snap?.transfer
  const peerName = snap?.configure?.peer.name ?? '对端'
  safe(() => {
    api.setValue({
      transfer: {
        phase: tr?.phase ?? 'idle',
        progress: tr?.progress ?? 0,
        bytesPerSecond: tr?.bytesPerSecond ?? 0,
        currentFile: tr?.currentFile ?? '',
        // 快照无 currentStage，阶段文案由 currentFile 兜底展示
        currentStage: '',
        directionText: `拉取：${peerName} → 本机`,
        resultSummary: tr?.resultSummary ?? '',
        backupDir: tr?.backupDir ?? null,
        needsRestart: tr?.needsRestart ?? false,
        failMessage: tr?.failMessage ?? null,
      },
    })
  }, 'applyTransfer')
}

function syncNav(api: FcApi): void {
  safe(() => {
    // 传输/配对中禁用返回（对齐源 nav-back :disabled="busy"）
    api.updateRule('lanNav', { props: { backDisabled: snap?.busy ?? false } })
  }, 'syncNav')
}

function syncSubPage(api: FcApi): void {
  safe(() => {
    api.updateRule('lanConfigure', { style: { display: subPage === 'configure' ? '' : 'none' } })
    api.updateRule('lanRunning', { style: { display: subPage === 'running' ? '' : 'none' } })
  }, 'syncSubPage')
}

function syncPicks(api: FcApi): void {
  const cur = (api.getValue('configure') as Record<string, unknown> | undefined) ?? {}
  safe(() => {
    api.setValue({ configure: { ...cur, picks: { ...picks }, expanded: { ...expanded } } })
  }, 'syncPicks')
}

async function pull(api: FcApi): Promise<void> {
  try {
    snap = ((await klineBus.request('lan', 'snapshot')) ?? {}) as unknown as LANSSnapshot
  } catch (e) {
    console.error('lan.snapshot 失败', e)
    return
  }
  const curDevices = (api.getValue('devices') as Record<string, unknown> | undefined) ?? {}
  safe(() => {
    api.setValue({
      devices: {
        serverOnline: snap?.serverOnline ?? false,
        probing: snap?.probing ?? false,
        port: snap?.port ?? null,
        deviceName: snap?.deviceName ?? '',
        isExposed: snap?.isExposed ?? false,
        isBrowsing: snap?.isBrowsing ?? false,
        connecting: snap?.connecting ?? false,
        peers: snap?.peers ?? [],
        // 手动直连输入是 Web 本地态，快照回填不重置（对齐源 manualAddress ref）
        manualAddress: typeof curDevices.manualAddress === 'string' ? curDevices.manualAddress : '',
      },
    })
  }, 'pull:devices')
  applyTransfer(api)
  syncNav(api)
}

function act(action: string, payload?: Record<string, unknown>): Promise<void> {
  return klineBus.request('lan', action, payload).then(() => undefined).catch((e) => {
    console.error(`lan.${action} 失败`, e)
  })
}

function showAlert(api: FcApi, title: string, msg: string): void {
  safe(() => {
    api.updateRule('alertDlg', { props: { title, message: msg } })
    api.setValue({ alertShow: true })
  }, 'showAlert')
}

// ===== 勾选粒度（语义对齐原生 toggleCategoryPick / toggleChildPick / 源面板实现） =====

function pickOf(catKey: string): Pick {
  return picks[catKey] ?? 'none'
}

function toggleCategory(api: FcApi, catKey: string): void {
  picks[catKey] = pickOf(catKey) === 'all' ? 'none' : 'all'
  syncPicks(api)
}

function toggleChild(api: FcApi, catKey: string, childKey: string): void {
  const cat = snap?.configure?.categories.find((c) => c.key === catKey)
  const allKeys = cat?.children.map((c) => c.key) ?? []
  const p = pickOf(catKey)
  if (p === 'none') {
    picks[catKey] = [childKey]
  } else if (p === 'all') {
    const rest = allKeys.filter((k) => k !== childKey)
    picks[catKey] = rest.length ? rest : 'none'
  } else {
    const set = new Set(p as string[])
    if (set.has(childKey)) set.delete(childKey)
    else set.add(childKey)
    const arr = [...set]
    if (!arr.length) picks[catKey] = 'none'
    else if (arr.length === allKeys.length && allKeys.every((k) => set.has(k))) picks[catKey] = 'all'
    else picks[catKey] = arr
  }
  syncPicks(api)
}

function toggleExpand(api: FcApi, catKey: string): void {
  expanded[catKey] = !expanded[catKey]
  syncPicks(api)
}

function startSync(api: FcApi): void {
  const cats = snap?.configure?.categories ?? []
  const selections = cats.flatMap((cat) => {
    const p = pickOf(cat.key)
    if (p === 'none') return []
    if (p === 'all') return [{ category: cat.key, mode: 'all', childKeys: [] }]
    return [{ category: cat.key, mode: 'children', childKeys: p as string[] }]
  })
  if (!selections.length) return
  klineBus.request('lan', 'start', { selections })
    .then(() => {
      subPage = 'running'
      syncSubPage(api)
    })
    .catch((e) => console.error('lan.start 失败', e))
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    navBack: (inj, ctx) => {
      // devices 子页返回 = 关页；其余子页回 devices（对齐源 back()）
      if (subPage === 'devices') {
        ctx.close()
        return
      }
      subPage = 'devices'
      syncSubPage(inj.api)
    },

    probe: (inj) => {
      void act('probe').then(() => pull(inj.api))
    },

    setExposed: (inj) => {
      const on = inj.args[0] as boolean
      void act('setExposed', { on }).then(() => pull(inj.api))
    },

    scan: (inj) => {
      void act('scan').then(() => pull(inj.api))
    },

    connect: (inj) => {
      const peerId = inj.args[0] as string
      void act('connect', { peerId }).then(() => pull(inj.api))
    },

    connectManual: (inj) => {
      const text = inj.args[0] as string
      if (!text) return
      void act('connect', { address: text }).then(() => pull(inj.api))
    },

    toggleCategory: (inj) => {
      toggleCategory(inj.api, inj.args[0] as string)
    },

    toggleChild: (inj) => {
      toggleChild(inj.api, inj.args[0] as string, inj.args[1] as string)
    },

    toggleExpand: (inj) => {
      toggleExpand(inj.api, inj.args[0] as string)
    },

    startSync: (inj) => {
      startSync(inj.api)
    },

    transferDone: (inj) => {
      subPage = 'devices'
      syncSubPage(inj.api)
    },

    transferRetry: (inj) => {
      subPage = 'configure'
      syncSubPage(inj.api)
    },
  },

  subscribe: (api) => {
    // klineBus 无 off：面板卸载后 handler 内 safe() 静默跳过陈旧 api 调用
    klineBus.on('lan.changed', (ev: BridgeEvent) => {
      const p = ev.payload ?? {}
      const reason = String(p['reason'] ?? '')
      const message = p['message'] ? String(p['message']) : ''
      if (reason === 'connectFailed') {
        showAlert(api, '无法连接', message)
      } else if (reason === 'mainDBReplaced') {
        showAlert(api, '主库已替换', message)
      } else if (reason === 'connected') {
        subPage = 'configure'
        syncSubPage(api)
      }
      void pull(api)
    })
    return () => {}
  },
}

export default adapter
