<template>
  <div class="sheet-page">
    <!-- K线设置（底部 75%，对齐原生 settingsOverlay）：P2 规则化 — 内容区 FcPageHost -->
    <div v-if="activeName === 'settings'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">K线设置</span>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body">
          <FcPageHost name="sheet-settings" domain="sheet" @close="close" />
        </div>
      </div>
    </div>

    <!-- 指标面板（主图 / 副图两形态，底部 75%） -->
    <div v-if="activeName === 'mainIndicators' || activeName === 'subIndicators'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">指标</span>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body">
          <FcPageHost
            :name="activeName === 'mainIndicators' ? 'sheet-mainIndicators' : 'sheet-subIndicators'"
            domain="sheet"
            :payload="openPayload ?? undefined"
            @close="close"
          />
        </div>
      </div>
    </div>

    <!-- 图表搜索面板（顶部锚定覆盖式，对齐原生 chartSearchBar） -->
    <template v-if="activeName === 'search'">
      <div class="panel-mask" @click="close">
        <div class="search-layer" @click.stop>
          <FcPageHost name="sheet-search" domain="sheet" @close="close" />
        </div>
      </div>
    </template>

    <!-- 快捷面板（悬浮球，底部 67%）：列表态 / 详情态票面 / picked 票面三视图由 adapter 切换 -->
    <div v-if="activeName === 'quick'" class="panel-mask" @click="close">
      <div class="panel quick-panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">快捷面板</span>
          <button class="panel-done" @click="close">关闭</button>
        </div>
        <div class="panel-body">
          <FcPageHost name="sheet-quick" domain="sheet" @close="close" />
        </div>
      </div>
    </div>

    <!-- 公式中心（tech 段）：浏览/删除；编辑与新建直进 Web 编辑器全屏页 -->
    <div v-if="activeName === 'formulaCenter'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">公式管理 · 技术指标</span>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body">
          <FcPageHost name="sheet-formulaCenter" domain="sheet" @close="close" />
        </div>
      </div>
    </div>

    <!-- 指标组合编辑页：全屏卡片形态（返回即关整个弹层链） -->
    <div v-if="activeName === 'presetEditor'" class="editor-full">
      <FcPageHost name="sheet-presetEditor" domain="sheet" @close="close" />
    </div>

    <!-- 训练设置浮层（居中卡片形态，对齐原生 TrainingSetupSheet） -->
    <div v-if="activeName === 'training'" class="panel-mask" @click="close">
      <div class="train-card" @click.stop>
        <div class="train-header">
          <span class="panel-title">单人训练</span>
          <button class="train-x" @click="close">✕</button>
        </div>
        <div class="train-body">
          <FcPageHost name="sheet-training" domain="sheet" @close="close" />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// 弹层浮层壳（P2 规则化收尾）：8 个面板内容区全部由 FcPageHost 按规则 JSON 渲染；
// 本壳仅保留遮罩/定位/标题 chrome 与 sheet.open 路由 + 就绪拉取。
import { onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import FcPageHost from '../fc/FcPageHost.vue'

const activeName = ref<string | null>(null)
const openPayload = ref<Record<string, unknown> | null>(null)

function close(): void {
  klineBus.request('sheet', 'close', {}).catch((e) => console.error(e))
  activeName.value = null
}

async function handleSheetOpen(name: string, payload: Record<string, unknown> | undefined): Promise<void> {
  activeName.value = name
  openPayload.value = payload ?? null
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('sheet.open', (ev) => {
    const name = typeof ev.payload?.name === 'string' ? ev.payload.name : ''
    if (name) void handleSheetOpen(name, ev.payload)
  })
  // dev/PC 调试循环：非 native 通道时支持 #/sheet?open=name 直开弹层，便于规则页迭代验证
  if (klineBus.transport !== 'native') {
    const open = new URLSearchParams(window.location.hash.split('?')[1] ?? '').get('open')
    if (open) await handleSheetOpen(open, undefined)
  }
  // 浮层就绪拉取：sheet.open 事件可能早于本 WebView 创建/加载完成发出（首次打开时序）
  // → 事件丢失面板永不渲染；就绪后主动向宿主拉取当前待展示弹层
  try {
    await klineBus.request('sheet', 'ready', {})
  } catch (e) {
    console.error('sheet.ready 失败', e)
  }
})
</script>

<style scoped>
.sheet-page {
  width: 100vw;
  height: 100vh;
  position: relative;
  background: transparent;
}

.panel-mask {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.35);
}

/* ===== 底部面板（75% / 67%，顶角圆角，对齐原生 TopRoundedCornerRect） ===== */
.panel {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 75%;
  background: var(--k-bg);
  border-radius: 16px 16px 0 0;
  display: flex;
  flex-direction: column;
}

.quick-panel {
  height: 67%;
}

.panel-header {
  display: flex;
  align-items: center;
  padding: 12px 16px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.panel-title {
  flex: 1;
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text);
}

.panel-done {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.panel-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
}

/* ===== 图表搜索面板（顶部锚定） ===== */
.search-layer {
  background: var(--k-bg);
  padding: 4px 0;
}

/* ===== 指标组合编辑页：全屏不透明容器 ===== */
.editor-full {
  position: fixed;
  inset: 0;
  z-index: 10;
  background: var(--k-bg);
}

/* ===== 训练设置浮层（居中卡片） ===== */
.train-card {
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  width: min(520px, calc(100vw - 48px));
  height: min(62vh, 520px);
  min-height: 200px;
  background: var(--k-bg-secondary);
  border-radius: 20px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.train-header {
  display: flex;
  align-items: center;
  padding: 10px 4px 10px 16px;
  flex-shrink: 0;
}

.train-x {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.train-body {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px;
  border-top: 0.5px solid var(--k-divider, #c6c6c8);
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}
</style>

<style>
/* ===== 弹层浮层页专用全局覆盖（非 scoped，作用于本 WebView 实例的文档根） =====
 * SheetPage 的 WebView 以 isOpaque=false 加载（透明 WKWebView），
 * 但 theme.css 给 html/body 画了 var(--k-bg) 白底——全屏白块盖住下层 K 线图表。
 * 此处将文档根透明化，面板外区域透出遮罩与图表。 */
html,
body {
  background: transparent !important;
}

#app {
  background: transparent;
  min-height: unset;
}
</style>
