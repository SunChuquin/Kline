// fc/adapters/tab-market.ts：行情榜单 Tab（tab-market）逻辑适配器。
// 表格区手势/虚拟滚动/冻结列/筛选/排序/加自选等逻辑全部内聚 KMarketView（源页
// MarketPage 1:1 平移，「逻辑不动」优先）；adapter 仅负责页面骨架中的桥接探测
// 与桥接告警（marketWarn）显隐。规则 JSON 无 emit 动作节点。
import { klineBus } from '../../bridge/klineBus'
import type { FcApi, FcPageAdapter, HostContext } from '../types'

const adapter: FcPageAdapter = {
  pull: async (api: FcApi, _ctx: HostContext): Promise<void> => {
    const t = await klineBus.detect()
    const ok = t !== 'none'
    try {
      api.updateRule('marketWarn', { style: { display: ok ? 'none' : '' } })
    } catch (e) {
      // 面板已卸载（Tab 页重挂载），忽略陈旧 api 调用
      console.warn('[fc] tab-market marketWarn 显隐更新跳过', e)
    }
    // 快照回读/changed 订阅由 KMarketView 自挂载逻辑承接（与源页一致）
  },
}

export default adapter
