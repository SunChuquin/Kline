<template>
  <div class="web-page">
    <!-- :key = pageSeq：WebView 常驻复用后，同名页面重开（如连续两次公式编辑器）时
         组件不再天然重挂载，强制重建以重新执行 mounted 快照拉取 -->
    <LanSyncPanel v-if="activeName === 'lanSync'" :key="`lan-${pageSeq}`" @close="closePage" />
    <LocalUpdatePanel v-else-if="activeName === 'localUpdate'" :key="`upd-${pageSeq}`" @close="closePage" />
    <EngineLabPanel v-else-if="activeName === 'pythonLab'" :key="`lab-${pageSeq}`" @close="closePage" />
    <BacktestPanel v-else-if="activeName === 'backtest'" :key="`bt-${pageSeq}`" @close="closePage" />
    <TrainingRecordsPanel v-else-if="activeName === 'trainingRecords'" :key="`tr-${pageSeq}`" @close="closePage" />
    <FormulaEditorPanel v-else-if="activeName === 'formulaEditor'" :key="`fe-${pageSeq}`" @close="closePage" />
    <div v-else class="page-empty"></div>
  </div>
</template>

<script setup lang="ts">
// 全屏 Web 页壳（P2-6c-1/c-2）：page.open 事件路由到对应面板；mounted 时调 page.ready
// 就绪拉取（page.open 可能早于本 WebView 创建/加载完成发出——sheet.ready 同款时序坑）。
// P2-9：宿主 WebView 常驻复用（关闭仅隐藏），pageSeq 驱动面板重挂载拉最新快照。
import { onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import LanSyncPanel from '../components/page/LanSyncPanel.vue'
import LocalUpdatePanel from '../components/page/LocalUpdatePanel.vue'
import EngineLabPanel from '../components/page/EngineLabPanel.vue'
import BacktestPanel from '../components/page/BacktestPanel.vue'
import TrainingRecordsPanel from '../components/page/TrainingRecordsPanel.vue'
import FormulaEditorPanel from '../components/page/FormulaEditorPanel.vue'

const activeName = ref<string | null>(null)
const pageSeq = ref(0)

function closePage(): void {
  // busy 时 Swift 侧 fail 拒绝（LAN 传输中），页面保持打开
  void klineBus.request('page', 'close').catch((e) => console.error('page.close 失败', e))
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('page.open', (ev) => {
    activeName.value = String(ev.payload?.['name'] ?? '')
    pageSeq.value += 1
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
