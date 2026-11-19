<template>
  <div class="sheet-page">
    <!-- K线设置面板（底部 75% 高，对齐原生 settingsOverlay） -->
    <div v-if="activeName === 'settings'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">K线设置</span>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body" v-if="settings">
          <div class="sec-title">通用</div>
          <div class="grouped">
            <button class="sel-row" @click="pickerKind = 'period'">
              <span>行情周期</span>
              <span class="sel-value">{{ settings.period }} ›</span>
            </button>
            <div class="g-divider"></div>
            <button class="sel-row" @click="pickerKind = 'viewCount'">
              <span>联动视图数量</span>
              <span class="sel-value">{{ viewCountLabel }} ›</span>
            </button>
          </div>

          <div class="sec-title danger">重置</div>
          <div class="grouped">
            <button class="sel-row destructive" @click="resetConfirm = true">重置当前标的联动视图配置</button>
          </div>

          <div class="sec-title">显示</div>
          <div class="grouped">
            <button class="sel-row" @click="pickerKind = 'chartStyle'">
              <span>K线类型</span>
              <span class="sel-value">{{ settings.chartStyle }} ›</span>
            </button>
            <div class="g-divider"></div>
            <label class="toggle-row">
              <div class="toggle-text">
                <div class="toggle-title">跳空缺口</div>
                <div class="toggle-sub">在 K 线之间标出跳空缺口区域</div>
              </div>
              <van-switch :model-value="settings.showGap" size="22px" @update:model-value="(v: boolean) => setSetting('showGap', v)" />
            </label>
            <div class="g-divider"></div>
            <label class="toggle-row">
              <div class="toggle-text">
                <div class="toggle-title">缺口回补后消失</div>
                <div class="toggle-sub">开启时缺口被回补后整体隐藏；关闭时仅截止，保留形成区</div>
              </div>
              <van-switch :model-value="settings.gapDisappearAfterFill" size="22px" @update:model-value="(v: boolean) => setSetting('gapDisappearAfterFill', v)" />
            </label>
            <div class="g-divider"></div>
            <label class="toggle-row">
              <div class="toggle-text">
                <div class="toggle-title">最新价线</div>
                <div class="toggle-sub">在最新收盘价位置绘制水平虚线</div>
              </div>
              <van-switch :model-value="settings.showLatestPriceLine" size="22px" @update:model-value="(v: boolean) => setSetting('showLatestPriceLine', v)" />
            </label>
            <div class="g-divider"></div>
            <label class="toggle-row">
              <div class="toggle-text">
                <div class="toggle-title">指标不挤压K线</div>
                <div class="toggle-sub">主图价格范围仅按 K 线计算；关闭后指标线会撑大范围</div>
              </div>
              <van-switch :model-value="settings.indicatorNotSqueezeKline" size="22px" @update:model-value="(v: boolean) => setSetting('indicatorNotSqueezeKline', v)" />
            </label>
            <div class="g-divider"></div>
            <label class="toggle-row">
              <div class="toggle-text">
                <div class="toggle-title">裸 K</div>
                <div class="toggle-sub">开启后只显示 K 线、隐藏全部主图指标</div>
              </div>
              <van-switch :model-value="settings.showBareK" size="22px" @update:model-value="(v: boolean) => setSetting('showBareK', v)" />
            </label>
          </div>
          <div style="height: 16px"></div>
        </div>
      </div>
    </div>

    <!-- 选项选择（周期 / K线类型 / 视图数量，底部弹出带 checkmark，对齐原生 confirmationDialog） -->
    <van-action-sheet
      v-model:show="pickerOpen"
      :actions="pickerActions"
      cancel-text="取消"
      close-on-click-action
      @select="onPickerSelect"
    />

    <!-- 重置确认 -->
    <van-dialog
      v-model:show="resetConfirm"
      title="重置当前标的的联动视图配置？"
      show-cancel-button
      confirm-button-text="重置"
      confirm-button-color="#ee0a24"
      @confirm="resetLinked"
    >
      <div class="dialog-note">将恢复为默认 2 个视图（左日线、右周线），且各视图标的/周期会被重置。</div>
    </van-dialog>

    <!-- 图表搜索面板（顶部锚定覆盖式，对齐原生 chartSearchBar） -->
    <template v-if="activeName === 'search'">
      <div class="panel-mask" @click="close">
        <div class="search-layer" @click.stop>
          <div class="search-row">
            <button class="search-x" @click="close">✕</button>
            <van-search
              v-model="keyword"
              class="search-field"
              placeholder="搜索代码/名称"
              shape="round"
              @update:model-value="onKeyword"
            />
            <button v-if="keyword" class="search-clear" @click="keyword = ''; results = []">⊗</button>
          </div>
          <div class="search-results">
            <div v-if="results.length === 0 && keyword" class="search-empty">没有匹配的标的</div>
            <div
              v-for="r in results"
              :key="r.file"
              class="search-row-item"
              @click="pick(r)"
            >
              <span class="sr-name">{{ r.name }}</span>
              <span class="sr-code">{{ r.code }}</span>
            </div>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import type { ChartOption, ChartSearchResult, ChartSettingsSnapshot } from '../types/protocol'

const activeName = ref<string | null>(null)
const settings = ref<ChartSettingsSnapshot | null>(null)

const keyword = ref('')
const results = ref<ChartSearchResult[]>([])

const pickerKind = ref<'period' | 'chartStyle' | 'viewCount' | null>(null)
const pickerOpen = computed({
  get: () => pickerKind.value !== null,
  set: (v: boolean) => { if (!v) pickerKind.value = null },
})
const resetConfirm = ref(false)

const viewCountLabel = computed(() => {
  const n = settings.value?.linkedViewCount ?? 2
  return `${n} 个视图`
})

/** 当前选择器的选项（value 统一字符串化传给 ActionSheet） */
const pickerActions = computed(() => {
  const s = settings.value
  if (!s || !pickerKind.value) return []
  const toActions = (opts: ChartOption[]) =>
    opts.map((o) => ({ name: o.label, value: String(o.value) }))
  if (pickerKind.value === 'period') return toActions(s.periodOptions)
  if (pickerKind.value === 'chartStyle') return toActions(s.styleOptions)
  return toActions(s.viewCountOptions)
})

function onPickerSelect(action: { name: string; value: string }): void {
  const s = settings.value
  if (!s) return
  switch (pickerKind.value) {
    case 'period':
      s.period = action.name
      void setSetting('period', action.name)
      break
    case 'chartStyle':
      s.chartStyle = action.name
      void setSetting('chartStyle', action.name)
      break
    case 'viewCount': {
      const n = Number(action.value)
      s.linkedViewCount = n
      void setSetting('linkedViewCount', n)
      break
    }
  }
}

// ===== 打开路由（sheet.open 事件） =====
async function handleSheetOpen(payload: Record<string, unknown> | undefined): Promise<void> {
  const name = typeof payload?.name === 'string' ? payload.name : null
  activeName.value = name
  if (name === 'settings') {
    try {
      const s = ((await klineBus.request('chart', 'settings.snapshot')) ?? {}) as Record<string, unknown>
      settings.value = {
        period: String(s.period ?? '日线'),
        periodOptions: (s.periodOptions ?? []) as ChartOption[],
        chartStyle: String(s.chartStyle ?? ''),
        styleOptions: (s.styleOptions ?? []) as ChartOption[],
        linkedViewCount: typeof s.linkedViewCount === 'number' ? s.linkedViewCount : 2,
        viewCountOptions: (s.viewCountOptions ?? []) as ChartOption[],
        showGap: s.showGap === true,
        gapDisappearAfterFill: s.gapDisappearAfterFill === true,
        showLatestPriceLine: s.showLatestPriceLine === true,
        indicatorNotSqueezeKline: s.indicatorNotSqueezeKline === true,
        showBareK: s.showBareK === true,
      }
    } catch (e) {
      console.error('settings.snapshot 失败', e)
    }
  }
  if (name === 'search') {
    keyword.value = ''
    results.value = []
  }
}

// ===== 动作 =====
function close(): void {
  klineBus.request('sheet', 'close', {}).catch((e) => console.error(e))
  activeName.value = null
}

/** 设置写回（幂等目标态；面板保持打开，图表即时生效——对齐原生交互） */
async function setSetting(key: string, value: string | number | boolean): Promise<void> {
  try {
    await klineBus.request('chart', 'settings.set', { [key]: value })
  } catch (e) {
    console.error('settings.set 失败', e)
  }
}

async function resetLinked(): Promise<void> {
  try {
    await klineBus.request('chart', 'settings.resetLinked', {})
  } catch (e) {
    console.error('resetLinked 失败', e)
  }
}

// ===== 搜索（原生同款 300ms 防抖） =====
let searchTimer: ReturnType<typeof setTimeout> | null = null

function onKeyword(): void {
  if (searchTimer) clearTimeout(searchTimer)
  searchTimer = setTimeout(() => void runSearch(), 300)
}

async function runSearch(): Promise<void> {
  const kw = keyword.value.trim()
  if (!kw) {
    results.value = []
    return
  }
  try {
    const s = ((await klineBus.request('chart', 'search.query', { keyword: kw })) ?? {}) as Record<string, unknown>
    results.value = (Array.isArray(s.results) ? (s.results as Record<string, unknown>[]) : []).map((r) => ({
      file: String(r.file ?? ''),
      code: String(r.code ?? ''),
      name: String(r.name ?? ''),
      type: String(r.type ?? ''),
    }))
  } catch (e) {
    console.error('search.query 失败', e)
  }
}

function pick(r: ChartSearchResult): void {
  // 原生侧 pick 成功后自动 close（浮层遮罩由 Swift 切走），Web 端同步清理本地态
  klineBus.request('chart', 'search.pick', { file: r.file }).catch((e) => console.error(e))
  keyword.value = ''
  results.value = []
  activeName.value = null
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('sheet.open', (ev) => void handleSheetOpen(ev.payload))
})
</script>

<style scoped>
.sheet-page {
  width: 100%;
  height: 100%;
  position: relative;
}

.panel-mask {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.35);
}

/* ===== K线设置面板（底部 75%，顶角圆角，对齐原生 TopRoundedCornerRect） ===== */
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

.sec-title {
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 8px 2px 6px;
}

.sec-title.danger {
  color: #ee0a24;
}

.grouped {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  overflow: hidden;
}

.g-divider {
  height: 0.5px;
  background: var(--k-border);
  margin-left: 14px;
}

.sel-row {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  min-height: 46px;
  padding: 0 14px;
  cursor: pointer;
  text-align: left;
}

.sel-row.destructive {
  color: #ee0a24;
  justify-content: center;
  font-weight: 500;
}

.sel-value {
  font-size: 14px;
  color: var(--k-text-secondary);
}

.toggle-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: 52px;
  padding: 8px 14px;
  cursor: pointer;
}

.toggle-title {
  font-size: 15px;
  color: var(--k-text);
}

.toggle-sub {
  font-size: 11.5px;
  color: var(--k-text-secondary);
  margin-top: 2px;
}

.dialog-note {
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 12px 16px 20px;
  text-align: center;
}

/* ===== 图表搜索面板（顶部锚定，对齐原生 chartSearchBar） ===== */
.search-layer {
  background: var(--k-bg);
  padding: 4px 0;
}

.search-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 6px;
}

.search-x {
  width: 24px;
  height: 24px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  flex-shrink: 0;
}

.search-field {
  flex: 1;
  padding: 0;
  background: none;
}

.search-clear {
  width: 24px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 14px;
  cursor: pointer;
}

.search-results {
  max-height: 320px;
  overflow-y: auto;
}

.search-empty {
  font-size: 13px;
  color: var(--k-text-tertiary);
  padding: 12px;
}

.search-row-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 9px 12px;
  cursor: pointer;
  border-bottom: 0.5px solid var(--k-border);
}

.sr-name {
  font-size: 14px;
  color: var(--k-text);
}

.sr-code {
  font-size: 12px;
  color: var(--k-text-secondary);
}
</style>
