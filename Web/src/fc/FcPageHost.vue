<template>
  <div class="fc-page" :class="`fc-${domain}`">
    <FormCreateMobile
      v-if="rule.length > 0"
      :key="hostKey"
      :rule="rule"
      :option="option"
      v-model:api="fapi"
      v-model="formData"
    />
    <div v-else class="fc-host-empty">{{ missText }}</div>
  </div>
</template>

<script setup lang="ts">
// fc/FcPageHost.vue：规则页统一宿主。
// 职责：按 name 查 registry → form-create 渲染规则 → adapter 接线：
//   1) 动作：规则 emit（emitPrefix='act'）→ fapi.on 转发 → adapter.actions[data-act]
//   2) 字段编辑：watch(formData) diff → adapter.onChange(field, value)（pull 期间抑制）
//   3) changed 订阅：adapter.subscribe 返回清理函数，卸载时调用
// 关闭动作（data-act=close）host 兜底处理，adapter 未实现也能关页。
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { getFcPage } from './registry'
import type { FcApi, FcInject, HostContext } from './types'

const props = withDefaults(defineProps<{
  name: string
  domain: 'page' | 'sheet' | 'tab'
  /** 打开时的 payload（透传 adapter，如 subIndicators 的 slot 定向） */
  payload?: Record<string, unknown> | null
}>(), {
  domain: 'page',
  payload: null,
})

const emit = defineEmits<{ (e: 'close'): void }>()

const entry = computed(() => getFcPage(props.name))
const rule = computed(() => entry.value?.rule ?? [])
const option = computed(() => ({
  submitBtn: false,
  resetBtn: false,
  injectEvent: true,
  ...(entry.value?.config ?? {}),
}))
const missText = computed(() => `页面未定义：${props.name}`)

// pageSeq 驱动重挂载（WebPage/SheetPage :key 已含 pageSeq，此处保底）
const hostKey = computed(() => `${props.name}`)

const formData = reactive<Record<string, unknown>>({})
const fapi = ref<FcApi | null>(null)

let suppressWatch = false
let lastSnapshot: Record<string, unknown> = {}
let disposeSub: (() => void) | null = null

const ctx: HostContext = {
  domain: props.domain,
  pageName: props.name,
  openPayload: props.payload ?? undefined,
  close: () => emit('close'),
}

function sameValue(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

watch(formData, () => {
  if (suppressWatch || !fapi.value) return
  const adapter = entry.value?.adapter
  if (!adapter?.onChange) {
    lastSnapshot = { ...formData }
    return
  }
  for (const k of Object.keys(formData)) {
    if (!sameValue(lastSnapshot[k], formData[k])) {
      void adapter.onChange(k, formData[k], fapi.value, ctx)
    }
  }
  lastSnapshot = { ...formData }
})

/** 规则树收集 act 事件名（emitPrefix='act' 的 emit 转发事件，kebab 化） */
function collectActEvents(rules: unknown[], acc: Set<string> = new Set()): Set<string> {
  for (const r of rules) {
    if (!r || typeof r !== 'object') continue
    const o = r as Record<string, unknown>
    const prefix = typeof o.emitPrefix === 'string' ? o.emitPrefix : null
    if (prefix && Array.isArray(o.emit)) {
      for (const e of o.emit) {
        const name = typeof e === 'string'
          ? e
          : e && typeof e === 'object' && typeof (e as { name?: unknown }).name === 'string'
            ? (e as { name: string }).name
            : null
        if (name) acc.add(`${prefix}-${kebab(name)}`)
      }
    }
    if (Array.isArray(o.children)) {
      for (const c of o.children) {
        if (c && typeof c === 'object') collectActEvents([c], acc)
      }
    }
  }
  return acc
}

function kebab(s: string): string {
  return s.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`)
}

function handleAct(...args: unknown[]): void {
  const inj = args[0] as FcInject | undefined
  const props0 = inj?.self?.props
  const act = props0 && typeof props0['data-act'] === 'string'
    ? props0['data-act'] as string
    : typeof inj?.inject === 'string' ? inj.inject : undefined
  if (!act) return
  if (act === 'close') {
    ctx.close()
    return
  }
  const fn = entry.value?.adapter?.actions?.[act]
  if (fn && inj) void fn(inj, ctx)
  else console.warn(`[fc] 未注册动作: ${props.name}.${act}`)
}

onMounted(async () => {
  await klineBus.detect()
  await nextTick()
  const adapter = entry.value?.adapter
  if (!fapi.value || !adapter) return

  for (const ev of collectActEvents(entry.value?.rule ?? [])) {
    fapi.value.on(ev, handleAct)
  }

  suppressWatch = true
  try {
    await adapter.pull(fapi.value, ctx)
  } catch (e) {
    console.error(`[fc] ${props.name} pull 失败`, e)
  }
  await nextTick()
  lastSnapshot = JSON.parse(JSON.stringify(formData)) as Record<string, unknown>
  suppressWatch = false

  try {
    disposeSub = adapter.subscribe?.(fapi.value, ctx) ?? null
  } catch (e) {
    console.error(`[fc] ${props.name} subscribe 失败`, e)
  }
})

onBeforeUnmount(() => {
  disposeSub?.()
  disposeSub = null
})
</script>

<style>
/* 非 scoped：form-create 动态渲染的节点拿不到 scoped 属性 */
.fc-page.page {
  height: 100vh;
  padding: 0 16px 24px;
  background: var(--k-bg);
  color: var(--k-text);
  overflow-y: auto;
}

.fc-note {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-top: 8px;
  line-height: 1.5;
}

.fc-unit {
  color: var(--k-text-tertiary, #c7c7cb);
  font-size: 12px;
  padding-left: 6px;
}

.dialog-note {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 12px 16px 20px;
  text-align: center;
}

.fc-host-empty {
  height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary, #c7c7cb);
}
</style>
