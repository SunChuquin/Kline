<template>
  <div class="web-page">
    <LanSyncPanel v-if="activeName === 'lanSync'" @close="closePage" />
    <LocalUpdatePanel v-else-if="activeName === 'localUpdate'" @close="closePage" />
    <EngineLabPanel v-else-if="activeName === 'pythonLab'" @close="closePage" />
    <BacktestPanel v-else-if="activeName === 'backtest'" @close="closePage" />
    <TrainingRecordsPanel v-else-if="activeName === 'trainingRecords'" @close="closePage" />
    <div v-else class="page-empty"></div>
  </div>
</template>

<script setup lang="ts">
// 全屏 Web 页壳（P2-6c-1/c-2）：page.open 事件路由到对应面板；mounted 时调 page.ready
// 就绪拉取（page.open 可能早于本 WebView 创建/加载完成发出——sheet.ready 同款时序坑）。
import { onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import LanSyncPanel from '../components/page/LanSyncPanel.vue'
import LocalUpdatePanel from '../components/page/LocalUpdatePanel.vue'
import EngineLabPanel from '../components/page/EngineLabPanel.vue'
import BacktestPanel from '../components/page/BacktestPanel.vue'
import TrainingRecordsPanel from '../components/page/TrainingRecordsPanel.vue'

const activeName = ref<string | null>(null)

function closePage(): void {
  // busy 时 Swift 侧 fail 拒绝（LAN 传输中），页面保持打开
  void klineBus.request('page', 'close').catch((e) => console.error('page.close 失败', e))
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('page.open', (ev) => {
    activeName.value = String(ev.payload?.['name'] ?? '')
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
