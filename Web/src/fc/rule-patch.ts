// fc/adapters/rule-patch.ts：updateRule 防御式补丁工具。
// form-create 的 api.updateRule(ctx.rule, rule) 为 Object.assign 浅赋值——传入
// {props} / {style} 会整体替换该键。为兼容"部分键更新"（基线 props/style 必须保留），
// 首次 patch 前用 api.getRule(name) 缓存规则 JSON 初值，回填完整集合。
// 若运行时实际为合并语义，重传同值亦无害（两种行为下结果一致）。
import type { FcApi } from '../types'

type Dict = Record<string, unknown>

interface RuleBase {
  props?: Dict
  style?: Dict
}

/** 按 fapi 实例隔离（WeakMap：面板关闭后随 api 回收） */
const baseCache = new WeakMap<FcApi, Map<string, RuleBase>>()

function basesOf(api: FcApi): Map<string, RuleBase> {
  let m = baseCache.get(api)
  if (!m) {
    m = new Map()
    baseCache.set(api, m)
  }
  return m
}

function ensureBase(api: FcApi, name: string): RuleBase {
  const m = basesOf(api)
  let b = m.get(name)
  if (!b) {
    const rule = (api as { getRule?: (id: string) => { props?: Dict; style?: Dict } | undefined }).getRule?.(name)
    b = {
      props: rule?.props ? { ...rule.props } : undefined,
      style: rule?.style ? { ...rule.style } : undefined,
    }
    m.set(name, b)
  }
  return b
}

/** 部分更新规则 props/style（自动并入 JSON 初值基线） */
export function patchRule(api: FcApi, name: string, patch: { props?: Dict; style?: Dict }): void {
  const b = ensureBase(api, name)
  const out: { props?: Dict; style?: Dict } = {}
  if (patch.props) out.props = { ...(b.props ?? {}), ...patch.props }
  if (patch.style) out.style = { ...(b.style ?? {}), ...patch.style }
  if (out.props || out.style) api.updateRule(name, out)
}
