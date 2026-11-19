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

    <!-- 指标面板（主图 / 副图两形态，对齐原生 mainSheetContent/subSheetContent） -->
    <div v-if="activeName === 'mainIndicators' || activeName === 'subIndicators'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">{{ indicatorsTitle }}</span>
          <button class="panel-reset" @click="resetBuiltinConfirm = true">重置内置指标</button>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body" v-if="indicators">
          <!-- 主图形态 -->
          <template v-if="activeName === 'mainIndicators'">
            <div class="sec-title">技术指标公式 · 主图</div>
            <div class="ind-grid">
              <button
                v-for="d in indicators.mainDefs"
                :key="d.id"
                class="ind-tile"
                :class="{ on: d.on }"
                role="button"
                :aria-label="`chart.indicator.main.${d.name}`"
                @click="toggleMain(d)"
              >
                <span class="ind-check">{{ d.on ? '☑' : '☐' }}</span>
                <span class="ind-name">{{ d.name }}</span>
              </button>
            </div>
            <button class="param-entry" @click="openSystemEditor(true, null)">⚙ 公式编辑 · 技术指标公式 ›</button>
            <div class="sec-title">自定义技术指标（主图）</div>
            <button class="param-entry" @click="openCustomEditor('main')">＋ 新增/管理 ›</button>
            <div v-if="indicators.mainCustoms.length === 0" class="block-empty">暂无主图自定义技术指标</div>
            <div v-else class="custom-rows">
              <div v-for="c in indicators.mainCustoms" :key="c.id" class="custom-row">
                <button class="custom-main" @click="activateMainCustom(c)">
                  <span class="custom-check">{{ c.active ? '◉' : '○' }}</span>
                  <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
                  <span class="custom-name">{{ c.name }}</span>
                </button>
                <button class="custom-edit" @click="openCustomEditor('main')">✎</button>
              </div>
            </div>
          </template>

          <!-- 副图形态 -->
          <template v-else-if="activeSlot">
            <div class="sec-title">选择副图指标 · {{ activeSlot.title }}</div>
            <template v-for="g in activeSlot.groups" :key="g.group">
              <div class="sec-title">{{ g.group }}</div>
              <div class="ind-grid">
                <button
                  v-for="k in g.kinds"
                  :key="k"
                  class="sub-tile"
                  :class="{ on: !activeSlot.customID && activeSlot.kind === k }"
                  @click="selectSubKind(k)"
                >{{ k }}</button>
              </div>
            </template>
            <button
              v-if="!activeSlot.customID && activeSlot.hasTemplate"
              class="param-entry"
              @click="openSystemEditor(false, activeSlot.kind)"
            >⚙ {{ activeSlot.kind }} 公式编辑 · 技术指标公式 ›</button>
            <div class="sec-title">自定义技术指标（副图）</div>
            <button class="param-entry" @click="openCustomEditor('sub')">＋ 新增/管理 ›</button>
            <div v-if="activeSlot.customs.length === 0" class="block-empty">暂无副图自定义技术指标</div>
            <div v-else class="custom-rows">
              <div v-for="c in activeSlot.customs" :key="c.id" class="custom-row">
                <button class="custom-main" @click="selectSubCustom(c)">
                  <span class="custom-check">{{ c.active ? '◉' : '○' }}</span>
                  <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
                  <span class="custom-name">{{ c.name }}</span>
                  <span v-if="c.active" class="custom-current">当前</span>
                </button>
                <button class="custom-edit" @click="openCustomEditor('sub')">✎</button>
              </div>
            </div>
          </template>
          <div style="height: 24px"></div>
        </div>
      </div>
    </div>

    <!-- 重置内置指标确认 -->
    <van-dialog
      v-model:show="resetBuiltinConfirm"
      title="重置内置指标"
      show-cancel-button
      confirm-button-text="重置"
      confirm-button-color="#ee0a24"
      @confirm="resetBuiltin"
    >
      <div class="dialog-note">将把所有内置指标恢复为编译时的内容，确定重置吗？</div>
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
import type {
  ChartOption,
  ChartSearchResult,
  ChartSettingsSnapshot,
  CustomIndicatorSnap,
  IndicatorDefSnap,
  IndicatorsSnapshot,
  SubSlotSnap,
} from '../types/protocol'

const activeName = ref<string | null>(null)
const settings = ref<ChartSettingsSnapshot | null>(null)
const indicators = ref<IndicatorsSnapshot | null>(null)
const activeSlotKey = ref<string | null>(null)

const keyword = ref('')
const results = ref<ChartSearchResult[]>([])

const pickerKind = ref<'period' | 'chartStyle' | 'viewCount' | null>(null)
const pickerOpen = computed({
  get: () => pickerKind.value !== null,
  set: (v: boolean) => { if (!v) pickerKind.value = null },
})
const resetConfirm = ref(false)
const resetBuiltinConfirm = ref(false)

const viewCountLabel = computed(() => {
  const n = settings.value?.linkedViewCount ?? 2
  return `${n} 个视图`
})

// ===== 指标面板（P2-5b） =====
const indicatorsTitle = computed(() =>
  activeName.value === 'mainIndicators' ? '主图指标'
    : `选择副图指标 · ${activeSlot.value?.title ?? ''}`)

const activeSlot = computed(() =>
  indicators.value?.subSlots.find((s) => s.slot === activeSlotKey.value) ?? null)

/** 当前激活主图自定义指标（互斥：激活自定义即隐藏系统指标判断由原生侧处理） */
function toggleMain(d: IndicatorDefSnap): void {
  if (!indicators.value) return
  void actIndicators('toggleMain', { id: d.id, on: !d.on })
}

function selectSubKind(kind: string): void {
  if (!activeSlot.value) return
  void actIndicators('selectSub', { slot: activeSlot.value.slot, kind })
}

function selectSubCustom(c: CustomIndicatorSnap): void {
  if (!activeSlot.value) return
  void actIndicators('selectSub', { slot: activeSlot.value.slot, customID: c.id })
}

function activateMainCustom(c: CustomIndicatorSnap): void {
  void actIndicators('activateMainCustom', { customID: c.active ? null : c.id })
}

function resetBuiltin(): void {
  void actIndicators('resetBuiltin', {})
}

function openSystemEditor(isMain: boolean, subId: string | null): void {
  void actIndicators('openSystemEditor', { isMain, subId })
  activeName.value = null   // 原生同款交互：先关面板再进编辑器（原生编辑器盖全屏）
}

function openCustomEditor(target: 'main' | 'sub'): void {
  void actIndicators('openCustomEditor', { target })
  activeName.value = null
}

/** 指标写回公共路径：动作成功即回读快照（写回模式 v2；重算由原生 recomputeHandler 执行） */
async function actIndicators(action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('chart', `indicators.${action}`, payload)
    await pullIndicators()
  } catch (e) {
    console.error(`indicators.${action} 失败`, e)
  }
}

async function pullIndicators(): Promise<void> {
  try {
    const s = ((await klineBus.request('chart', 'indicators.snapshot')) ?? {}) as Record<string, unknown>
    indicators.value = {
      period: String(s.period ?? ''),
      mainDefs: (s.mainDefs ?? []) as IndicatorDefSnap[],
      mainCustoms: (s.mainCustoms ?? []) as CustomIndicatorSnap[],
      subSlots: (s.subSlots ?? []) as SubSlotSnap[],
    }
    if (activeSlotKey.value === null && indicators.value.subSlots.length > 0) {
      activeSlotKey.value = indicators.value.subSlots[0].slot
    }
  } catch (e) {
    console.error('indicators.snapshot 失败', e)
  }
}

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
  if (name === 'mainIndicators' || name === 'subIndicators') {
    activeSlotKey.value = typeof payload?.slot === 'string' ? payload.slot : null
    await pullIndicators()
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

/* ===== 指标面板（P2-5b，对齐 ChartSheetKit 视觉令牌） ===== */
.panel-reset {
  border: none;
  background: none;
  color: #ee0a24;
  font-size: 13px;
  cursor: pointer;
  flex-shrink: 0;
}

.ind-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 0 0 6px;
}

.ind-tile,
.sub-tile {
  flex: 1 1 calc(25% - 8px);
  min-width: 80px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  border: 1px solid rgba(128, 128, 128, 0.25);
  border-radius: 8px;
  background: var(--k-bg-secondary);
  opacity: 0.45;
  color: var(--k-text);
  font-size: 13px;
  padding: 12px 4px;
  cursor: pointer;
}

.ind-tile.on,
.sub-tile.on {
  opacity: 1;
  border-color: #1989fa;
  background: var(--k-bg-secondary);
  font-weight: 600;
  color: #1989fa;
}

.ind-check {
  font-size: 14px;
}

.sub-tile {
  flex-direction: row;
  justify-content: center;
}

.param-entry {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border: none;
  border-radius: 8px;
  background: rgba(25, 137, 250, 0.08);
  color: #1989fa;
  font-size: 13px;
  padding: 12px 14px;
  margin: 8px 0;
  cursor: pointer;
}

.custom-rows {
  display: flex;
  flex-direction: column;
}

.custom-row {
  display: flex;
  align-items: center;
  min-height: 42px;
}

.custom-main {
  flex: 1;
  display: flex;
  align-items: center;
  gap: 10px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 14px;
  padding: 9px 0;
  cursor: pointer;
  text-align: left;
}

.custom-check {
  font-size: 15px;
  color: #1989fa;
}

.custom-check:not(.on) {
  color: var(--k-text-tertiary);
}

.custom-color {
  width: 14px;
  height: 5px;
  border-radius: 2px;
  flex-shrink: 0;
}

.custom-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.custom-current {
  font-size: 10px;
  color: #1989fa;
}

.custom-edit {
  width: 32px;
  height: 32px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 13px;
  cursor: pointer;
}
</style>

<style>
/* ===== 弹层浮层页专用全局覆盖（非 scoped，作用于本 WebView 实例的文档根） =====
 * SheetPage 的 WebView 以 isOpaque=false 加载（透明 WKWebView），
 * 但 theme.css 给 html/body 画了 var(--k-bg) 白底——全屏白块盖住下层 K 线图表
 * （2026-11-19 实测「面板打开后图表变白」根因）。此处将文档根透明化，
 * 面板外区域透出遮罩与图表。Tab 页 WebView 不受影响：各自根 div 有页面背景，
 * 且 WKWebView 层仍为 systemBackground 白底兜底。 */
html,
body {
  background: transparent !important;
}

#app {
  background: transparent;
  min-height: unset;
}
</style>
