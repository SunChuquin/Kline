// fc/registry.ts：规则页注册表。
// JSON：Web/form-create/pages/*.json（designer 兼容 {rule, config}），build-time 打包；
// Adapter：Web/src/fc/adapters/<页面名>.ts（文件名 = 页面名，如 sheet-settings.ts）。
// 元数据：Web/form-create/index.json（title/分组，文件列表与宿主共用）。
import type { FcPageAdapter, FcPageEntry, ShellSpec } from './types'

interface PageJson {
  rule?: unknown[]
  config?: Record<string, unknown>
}

const ruleModules = import.meta.glob('../../form-create/pages/*.json', {
  eager: true,
  import: 'default',
}) as Record<string, PageJson>

const adapterModules = import.meta.glob<FcPageAdapter>('./adapters/*.ts', {
  eager: true,
  import: 'default',
})

interface PageMeta {
  file: string
  title: string
  group: 'tab' | 'sheet' | 'page'
  shell?: ShellSpec
}

import pageIndexJson from '../../form-create/index.json'
const pageIndex = pageIndexJson as { pages?: PageMeta[] }

function fileToName(path: string): string {
  const m = /([^/]+)\.json$/.exec(path)
  return m ? m[1] : path
}

function adapterFileName(pageName: string): string {
  const m = Object.keys(adapterModules).find((p) => p.endsWith(`/${pageName}.ts`))
  return m ?? ''
}

/** 默认弹层壳（bottom 75%）——index.json 未标注时兜底 */
const defaultShell: ShellSpec = { kind: 'bottom', height: '75%' }

function shellOf(meta: PageMeta | undefined): ShellSpec {
  const s = meta && (meta as PageMeta & { shell?: ShellSpec }).shell
  return s ? { ...defaultShell, ...s } : defaultShell
}

const entries = new Map<string, FcPageEntry>()

for (const [path, json] of Object.entries(ruleModules)) {
  const name = fileToName(path)
  const meta = pageIndex.pages?.find((p) => p.file === name)
  entries.set(name, {
    name,
    rule: json.rule ?? [],
    config: json.config ?? {},
    adapter: adapterModules[adapterFileName(name)] ?? null,
    shell: meta?.group === 'page' || meta?.group === 'tab'
      ? { kind: 'full' }
      : shellOf(meta),
    title: meta?.title ?? name,
  })
}

export function getFcPage(name: string): FcPageEntry | null {
  return entries.get(name) ?? null
}

export function listFcPages(): FcPageEntry[] {
  return [...entries.values()]
}
