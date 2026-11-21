// fc/adapters/tab-favorites.ts：自选页（tab-favorites）逻辑适配器。
// 迁移自 Web/src/pages/FavoritesPage.vue：分组快照（favorites.snapshot）、
// 行级写回（setPinned/moveTo/removeFromGroup/setNote）、下拉刷新（refresh + 定时回读兜底）、
// favorites.changed 事件回读（native 模式）。选中分组失效时回首个 Tab。
import { klineBus } from '../../bridge/klineBus'
import { showToast } from 'vant'
import type { BridgeEvent } from '../../types/protocol'
import type { FcApi, FcPageAdapter } from '../types'

interface FavRow {
  file: string
  code: string
  name: string
  latestPrice: number | null
  change: number | null
  changePct: number | null
  volume: number | null
  turnover: number | null
  lastDate: string
  pinned: boolean
  note: string
}

interface FavGroup {
  id: string
  kind: 'manual' | 'formula'
  name: string
  count: number
  rows: FavRow[]
}

interface ViewValue {
  rows: FavRow[]
  canEdit: boolean
  loaded: boolean
  refreshing: boolean
}

let bridgeOk = false
let loaded = false
let groups: FavGroup[] = []
/** 当前选中分组 id */
let curGroupId = ''
/** 「全部」虚拟分组 id（原生 no-op 语义：固顶/移除/排序需在具体分组内） */
let allGroupId = ''
let menuTarget: FavRow | null = null
let noteTarget: FavRow | null = null
let retryTimer: number | undefined
let refreshTimers: number[] = []

function clearTimers(): void {
  if (retryTimer !== undefined) {
    window.clearTimeout(retryTimer)
    retryTimer = undefined
  }
  for (const t of refreshTimers) window.clearTimeout(t)
  refreshTimers = []
}

function currentGroup(): FavGroup | null {
  return groups.find((g) => g.id === curGroupId) ?? null
}

/** 当前分组是否支持写回：manual 实体分组（「全部」虚拟分组与公式分组只读） */
function canEdit(): boolean {
  const g = currentGroup()
  return !!g && g.kind === 'manual' && g.id !== allGroupId
}

/** 回填视图（保留下拉刷新态）；页面已卸载时忽略陈旧 api 调用 */
function applyView(api: FcApi): void {
  try {
    const cur = (api.getValue('favoritesView') as ViewValue | undefined) ?? {
      rows: [], canEdit: false, loaded: false, refreshing: false,
    }
    api.setValue({
      favoritesView: {
        rows: currentGroup()?.rows ?? [],
        canEdit: canEdit(),
        loaded,
        refreshing: cur.refreshing === true,
      },
    })
  } catch (e) {
    console.warn('[fc] tab-favorites applyView 跳过（页面可能已卸载）', e)
  }
}

function syncMenu(api: FcApi, row: FavRow | null): void {
  const actions: { name: string; value: string; color?: string }[] = []
  if (row) {
    if (canEdit()) {
      actions.push({ name: row.pinned ? '取消固顶' : '固顶', value: 'togglePin' })
      actions.push({ name: '移到最前', value: 'first' })
      actions.push({ name: '移到最后', value: 'last' })
      actions.push({ name: '备注', value: 'note' })
      actions.push({ name: '从分组移除', value: 'remove', color: '#ee0a24' })
    } else {
      actions.push({ name: '备注', value: 'note' })
    }
  }
  api.updateRule('menuSheet', { props: { actions } })
}

/** 下拉刷新结束：复位 refreshing 态（成功文本「已刷新」随 true→false 过渡出现） */
function endRefreshing(api: FcApi): void {
  try {
    const cur = api.getValue('favoritesView') as ViewValue | undefined
    if (cur && cur.refreshing === true) {
      api.setValue({ favoritesView: { ...cur, refreshing: false } })
    }
  } catch (e) {
    console.warn('[fc] tab-favorites endRefreshing 跳过（页面可能已卸载）', e)
  }
}

async function pullSnapshot(api: FcApi): Promise<void> {
  try {
    const s = ((await klineBus.request('favorites', 'snapshot')) ?? {}) as Record<string, unknown>
    loaded = s.loaded === true
    allGroupId = String(s.allGroupId ?? '')
    const raw = Array.isArray(s.groups) ? (s.groups as Record<string, unknown>[]) : []
    groups = raw.map((g) => ({
      id: String(g.id ?? ''),
      kind: (g.kind === 'formula' ? 'formula' : 'manual') as FavGroup['kind'],
      name: String(g.name ?? ''),
      count: Array.isArray(g.rows) ? (g.rows as unknown[]).length : 0,
      rows: (Array.isArray(g.rows) ? (g.rows as Record<string, unknown>[]) : []).map((r) => ({
        file: String(r.file ?? ''),
        code: String(r.code ?? ''),
        name: String(r.name ?? ''),
        latestPrice: typeof r.latestPrice === 'number' ? r.latestPrice : null,
        change: typeof r.change === 'number' ? r.change : null,
        changePct: typeof r.changePct === 'number' ? r.changePct : null,
        volume: typeof r.volume === 'number' ? r.volume : null,
        turnover: typeof r.turnover === 'number' ? r.turnover : null,
        lastDate: String(r.lastDate ?? ''),
        pinned: r.pinned === true,
        note: String(r.note ?? ''),
      })),
    }))
    // 选中分组失效时回首个 Tab
    if (!groups.some((g) => g.id === curGroupId)) {
      curGroupId = groups[0]?.id ?? ''
      try {
        api.setValue({ activeGroup: curGroupId })
      } catch (e) {
        console.warn('[fc] tab-favorites 回填跳过（页面可能已卸载）', e)
        return
      }
    }
    applyView(api)
  } catch (e) {
    console.error('favorites.snapshot 失败', e)
  }
}

/** 写回公共路径：动作成功即回读快照（写回模式 v2：状态以回读为准） */
async function writeBack(api: FcApi, action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('favorites', action, payload)
    await pullSnapshot(api)
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
    console.error(action, e)
  }
}

async function pull(api: FcApi): Promise<void> {
  const t = await klineBus.detect()
  bridgeOk = t !== 'none'
  api.updateRule('bridgeWarn', { style: { display: bridgeOk ? 'none' : '' } })
  api.updateRule('menuSheet', { props: { actions: [] } })
  if (!bridgeOk) {
    api.setValue({
      activeGroup: '',
      favoritesView: { rows: [], canEdit: false, loaded: false, refreshing: false },
    })
    return
  }

  curGroupId = ''
  await pullSnapshot(api)
  // 分组 chips（横滚 tab 对齐原生自选页分组条；label = 名称 + 行数）
  api.updateRule('groupChips', {
    props: {
      options: groups.map((g) => ({
        label: g.count > 0 ? `${g.name} ${g.count}` : g.name,
        value: g.id,
      })),
    },
  })
  applyView(api)
  // 主库未就绪（冷启动竞态）：3s 后重试一次
  if (!loaded) {
    retryTimer = window.setTimeout(() => void pullSnapshot(api), 3000)
  }
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    openRow: (inj) => {
      const row = inj.args[0] as FavRow | undefined
      if (!row) return
      klineBus.request('favorites', 'openDetail', { file: row.file }).catch((e) => console.error(e))
    },

    openMenu: (inj) => {
      const row = inj.args[0] as FavRow | undefined
      if (!row) return
      menuTarget = row
      syncMenu(inj.api, row)
      inj.api.setValue({ menuOpen: true })
    },

    menuSelect: (inj) => {
      const action = inj.args[0] as { value: string } | undefined
      const row = menuTarget
      if (!action || !row) return
      const group = currentGroup()?.id ?? null
      switch (action.value) {
        case 'togglePin':
          void writeBack(inj.api, 'setPinned', { file: row.file, pinned: !row.pinned, group })
          break
        case 'first':
        case 'last':
          void writeBack(inj.api, 'moveTo', { file: row.file, where: action.value, group })
          break
        case 'note':
          noteTarget = row
          inj.api.setValue({ noteDraft: row.note, noteOpen: true })
          inj.api.updateRule('noteDialog', { props: { title: `备注 · ${row.name}` } })
          break
        case 'remove':
          void writeBack(inj.api, 'removeFromGroup', { file: row.file, group })
          break
      }
    },

    togglePin: (inj) => {
      const row = inj.args[0] as FavRow | undefined
      if (!row) return
      void writeBack(inj.api, 'setPinned', { file: row.file, pinned: !row.pinned, group: currentGroup()?.id ?? null })
    },

    removeRow: (inj) => {
      const row = inj.args[0] as FavRow | undefined
      if (!row) return
      void writeBack(inj.api, 'removeFromGroup', { file: row.file, group: currentGroup()?.id ?? null })
    },

    saveNote: (inj) => {
      const row = noteTarget
      if (!row) return
      const note = String(inj.api.getValue('noteDraft') ?? '')
      void writeBack(inj.api, 'setNote', { file: row.file, note })
    },

    onRefresh: (inj) => {
      const api = inj.api
      if (!bridgeOk) {
        endRefreshing(api)
        return
      }
      void klineBus
        .request('favorites', 'refresh', { group: currentGroup()?.id ?? null })
        .then(() => {
          // 刷新异步完成：定时回读两次兜底（数据落缓存时机不确定；native 模式另有 favorites.changed 事件）
          refreshTimers.push(window.setTimeout(() => void pullSnapshot(api), 1500))
          refreshTimers.push(window.setTimeout(() => {
            void pullSnapshot(api)
            endRefreshing(api)
          }, 3500))
        })
        .catch(() => endRefreshing(api))
    },
  },

  onChange: (field, value, api) => {
    if (field === 'activeGroup' && typeof value === 'string') {
      curGroupId = value
      applyView(api)
    }
  },

  subscribe: (api) => {
    if (!bridgeOk) return () => clearTimers()
    // native 模式：数据变化事件触发回读（pc 模式由刷新后的定时回读兜底）
    const handler = (_ev: BridgeEvent): void => void pullSnapshot(api)
    klineBus.on('favorites.changed', handler)
    return () => clearTimers()
  },
}

export default adapter
