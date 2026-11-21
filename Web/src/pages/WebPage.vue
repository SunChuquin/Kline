<template>
  <div class="web-page">
    <FcPageHost
      v-if="ruleName"
      :name="ruleName"
      domain="page"
      :key="`${ruleName}-${pageSeq}`"
      :payload="openPayload ?? undefined"
      @close="closePage"
    />
    <div v-else class="page-empty"></div>
  </div>
</template>

<script setup lang="ts">
// 全屏 Web 页壳（规则化终态）：page.open 路由到 page-<name> 规则页（FcPageHost 按
// JSON 渲染 + adapter 接线）；WebView 常驻复用，pageSeq 驱动重挂载拉最新快照。
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { klineBus } from '../bridge/klineBus'
import FcPageHost from '../fc/FcPageHost.vue'

const route = useRoute()
const activeName = ref<string | null>(null)
const pageSeq = ref(0)
const openPayload = ref<Record<string, unknown> | null>(null)

const ruleName = computed(() => (activeName.value ? `page-${activeName.value}` : null))

function closePage(): void {
  // busy 时 Swift 侧 fail 拒绝（LAN 传输中），页面保持打开
  void klineBus.request('page', 'close').catch((e) => console.error('page.close 失败', e))
}

// dev/PC 调试循环：非 native 通道时支持 #/page?open=name 直开面板（watch query
// 以支持 SPA 内 hash 直变；native 通道由 page.open 事件驱动，忽略 query）
watch(() => route.query.open, (open) => {
  if (klineBus.transport === 'native') return
  const name = typeof open === 'string' ? open : ''
  if (name && name !== activeName.value) {
    activeName.value = name
    pageSeq.value += 1
  }
}, { immediate: true })

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('page.open', (ev) => {
    activeName.value = String(ev.payload?.['name'] ?? '')
    pageSeq.value += 1
    openPayload.value = (ev.payload ?? null) as Record<string, unknown> | null
  })
  try {
    await klineBus.request('page', 'ready')
  } catch (e) {
    console.error('page.ready 失败', e)
  }
})
</script>

<style scoped>
.web-page {
  height: 100vh;
  background: var(--k-bg);
  color: var(--k-text);
}

.page-empty {
  height: 100%;
}
</style>
