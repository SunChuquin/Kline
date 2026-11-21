// fc/adapters/page-condManage.ts：条件单管理页（page-condManage）逻辑适配器。
// 快照：cond.list；动作：cond.new / cond.edit / cond.cancel；
// 行文案为原生投影缓存直读（占位→就绪经 cond.changed(texts) 重推）。
import { klineBus } from '../../bridge/klineBus'
import type { BridgeEvent } from '../../types/protocol'
import type { CondListSnapshot, CondOrderSnap } from '../../types/protocol'
import type { FcApi, FcPageAdapter, HostContext } from '../types'
import { patchRule } from '../rule-patch'

const SEGMENTS = ['monitoring', 'triggered', 'invalid'] as const
type Segment = (typeof SEGMENTS)[number]

const EMPTY_TEXT: Record<Segment, string> = {
  monitoring: '暂无监控中的条件单',
  triggered: '暂无已触发的条件单',
  invalid: '暂无已失效的条件单',
}

function segmentOf(o: CondOrderSnap): Segment {
  return o.status === 'monitoring' ? 'monitoring'
    : (o.status === 'triggered' || o.status === 'completed') ? 'triggered' : 'invalid'
}

let snap: CondListSnapshot | null = null

function setRowHidden(api: FcApi, name: string, hidden: boolean): void {
  patchRule(api, name, { style: { display: hidden ? 'none' : '' } })
}

/** 按当前分段过滤渲染列表 / 空态 */
function renderSegment(api: FcApi, segment: Segment): void {
  const orders = snap?.orders ?? []
  const rows = orders
    .filter((o) => segmentOf(o) === segment)
    .map((o) => ({ ...o, showCancel: o.status === 'monitoring' }))
  api.setValue({ condList: { rows } })
  const empty = rows.length === 0
  setRowHidden(api, 'condList', empty)
  setRowHidden(api, 'emptyNote', !empty)
  setRowHidden(api, 'emptyNewBtn', !empty)
  patchRule(api, 'emptyNote', { props: { text: EMPTY_TEXT[segment] } })
}

async function pull(api: FcApi, _ctx: HostContext): Promise<void> {
  try {
    snap = ((await klineBus.request('cond', 'list')) ?? {}) as unknown as CondListSnapshot
  } catch (e) {
    console.error('cond.list 失败', e)
    return
  }
  patchRule(api, 'engineBanner', { style: { display: snap.engineReady ? 'none' : '' } })
  renderSegment(api, ((api.getValue('segment') as string) ?? 'monitoring') as Segment)
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    createNew: () => {
      // 原生切 activePage=condEditor（page.open 推送驱动本 WebView 切面板）
      void klineBus.request('cond', 'new', {}).catch((e) => console.error(e))
    },

    editOrder: (inj) => {
      const row = inj.args[0] as { id: string } | undefined
      if (!row?.id) return
      void klineBus.request('cond', 'edit', { id: row.id }).catch((e) => console.error(e))
    },

    cancelOrder: (inj, ctx) => {
      const row = inj.args[0] as { id: string } | undefined
      if (!row?.id) return
      void klineBus.request('cond', 'cancel', { id: row.id })
        .then(() => pull(inj.api, ctx))
        .catch((e) => console.error(e))
    },
  },

  onChange: (field, value, api, ctx) => {
    if (field === 'segment') {
      renderSegment(api, ((value as string) ?? 'monitoring') as Segment)
    }
    void ctx
  },

  subscribe: (api, ctx) => {
    // changed 推送：列表/文案投影更新或保存结果 → 重拉
    const handler = (ev: BridgeEvent): void => {
      const reason = String(ev.payload?.['reason'] ?? '')
      if (reason === 'list' || reason === 'texts' || reason === 'saveResult') {
        try {
          void pull(api, ctx)
        } catch (e) {
          // 面板已卸载，忽略陈旧 api 调用
          console.warn('[fc] condManage changed 跳过（面板可能已关闭）', e)
        }
      }
    }
    klineBus.on('cond.changed', handler)
    return () => {}
  },
}

export default adapter
