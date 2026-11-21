// fc/types.ts：规则页运行时契约。
//
// 页面 = 规则 JSON（UI 结构，form-create 格式）+ Adapter（业务逻辑）。
// Adapter 通过 FcApi（form-create 实例 API）回填/读取字段，通过 HostContext
// 关闭页面；动作经规则 emit（emitPrefix='act'）转发 → host 按 data-act 分发。

import type { klineBus } from '../bridge/klineBus'

/** form-create 实例 API（@form-create/vant 类型较松，运行时按需使用） */
export type FcApi = {
  setValue(data: Record<string, unknown>): void
  getValue(field: string): unknown
  getValues(): Record<string, unknown>
  on(event: string, fn: (...args: unknown[]) => void): void
  off(event: string, fn?: (...args: unknown[]) => void): void
  updateRule(name: string, rule: unknown): void
  [key: string]: unknown
}

/** emit 事件注入参数（form-create InjectArg 子集） */
export interface FcInject {
  api: FcApi
  rule: unknown[]
  self: { props?: Record<string, unknown>; field?: string; [key: string]: unknown }
  option: Record<string, unknown>
  inject: unknown
  args: unknown[]
}

export interface HostContext {
  /** 页面域：page=全屏页 / sheet=弹层浮层 / tab=底部菜单页 */
  domain: 'page' | 'sheet' | 'tab'
  /** 注册名（如 sheet-settings / page-cacheManage） */
  pageName: string
  /** 关闭页面（parent 按域发 page.close / sheet.close 并清 activeName） */
  close(): void
}

export interface FcPageAdapter {
  /** 打开/重挂载时拉快照并回填表单（程序化 setValue，host 已抑制 watch 环路） */
  pull(api: FcApi, ctx: HostContext): Promise<void>
  /** 动作表：props['data-act'] → 处理器（emit 转发事件统一由 host 分发） */
  actions?: Record<string, (inj: FcInject, ctx: HostContext) => void | Promise<void>>
  /** 用户编辑字段（watch formData 捕获）→ 写回桥 */
  onChange?(field: string, value: unknown, api: FcApi, ctx: HostContext): void | Promise<void>
  /** 订阅 changed 事件；返回清理函数（host 卸载时调用） */
  subscribe?(api: FcApi, ctx: HostContext): () => void
}

/** 弹层壳形态（SheetPage 按 registry.shell 包装 FcPageHost） */
export interface ShellSpec {
  /** bottom=底部圆角面板 / center=居中卡片 / top=顶部锚定覆盖 / full=全屏 */
  kind: 'bottom' | 'center' | 'top' | 'full'
  /** bottom/center 高度（% or vh 字符串，如 '75%' / 'min(62vh, 520px)'） */
  height?: string
  /** 宽度（center 卡片用） */
  width?: string
}

export interface FcPageEntry {
  name: string
  /** 规则 JSON 的 rule 数组（designer 兼容格式） */
  rule: unknown[]
  /** 规则 JSON 的 config（合并进 form-create option） */
  config: Record<string, unknown>
  adapter: FcPageAdapter | null
  shell: ShellSpec
  /** 标题（index.json 元数据，宿主/文件列表用） */
  title: string
}

export type KlineBusLike = typeof klineBus
