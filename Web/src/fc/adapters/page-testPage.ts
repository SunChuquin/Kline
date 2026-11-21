// fc/adapters/page-testPage.ts：测试页（page-testPage）逻辑适配器。
// 原生 ProfileView 为纯 mock 演示页（假数据 + 占位详情页，无任何业务依赖），
// Web 端静态复刻、零桥协议动作（打开走 page.open("testPage")，关闭走 page.close）；
// 点任意 mock 项进页内详情态（DetailPage 复刻），返回优先回列表。mock 数据静态内嵌
// 规则 JSON value（原生 MockData.swift 同款），adapter 只管列表/详情两态切换。
import type { FcApi, FcPageAdapter, HostContext } from '../types'

let ctxRef: HostContext | null = null
let detailTitle = ''

async function pull(api: FcApi, ctx: HostContext): Promise<void> {
  ctxRef = ctx
  detailTitle = ''
  api.setValue({
    listVisible: true,
    detailVisible: false,
    detailState: { icon: 'ⓘ', title: '', sub: '', size: 'lg' },
  })
}

const adapter: FcPageAdapter = {
  pull,

  actions: {
    openDetail: (inj) => {
      const title = String(inj.args[0] ?? '')
      if (!title) return
      detailTitle = title
      inj.api.setValue({
        listVisible: false,
        detailVisible: true,
        detailState: {
          icon: 'ⓘ',
          title,
          sub: `这是「${title}」的详情页面。你可以在这里展示更多相关内容。`,
          size: 'lg',
        },
      })
      inj.api.updateRule('nav', { props: { title } })
    },

    navBack: (inj, ctx) => {
      // 详情态回列表，列表态关页回模拟 Tab
      if (detailTitle) {
        detailTitle = ''
        inj.api.setValue({ listVisible: true, detailVisible: false })
        inj.api.updateRule('nav', { props: { title: '测试页面' } })
        return
      }
      ctx.close()
    },
  },

  subscribe: () => () => {
    ctxRef = null
  },
}

export default adapter
