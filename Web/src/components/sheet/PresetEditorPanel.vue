<template>
  <div class="pep2">
    <!-- 页头：返回（dirty 确认）｜ 组合编辑 ｜ 保存 -->
    <div class="nav-line">
      <button class="nav-link" aria-label="presetEditor.back" @click="onBack">‹ 返回</button>
      <span class="nav-center">组合编辑</span>
      <button
        class="nav-link save"
        aria-label="presetEditor.save"
        :disabled="!snap || saving"
        @click="save"
      >{{ saving ? '保存中…' : '保存' }}</button>
    </div>

    <template v-if="snap">
      <!-- 组合 tab（5 槽）+ 名称编辑 -->
      <div class="tab-row" aria-label="presetEditor.presetTabs">
        <button
          v-for="p in draft"
          :key="p.id"
          class="tab-chip"
          :class="{ on: activePresetID === p.id, active: snap.mode === p.id }"
          @click="activePresetID = p.id"
        >{{ p.name }}{{ snap.mode === p.id ? ' ✓' : '' }}</button>
      </div>
      <div class="name-row">
        <span class="name-cap">名称</span>
        <input v-model="activePreset.name" class="name-input" :aria-label="`presetEditor.name.${activePresetID}`" />
      </div>

      <!-- 周期 tab -->
      <div class="tab-row" aria-label="presetEditor.periodTabs">
        <button
          v-for="cat in snap.catalog.periods"
          :key="cat.period"
          class="tab-chip small"
          :class="{ on: activePeriod === cat.period }"
          @click="activePeriod = cat.period"
        >{{ cat.period }}</button>
      </div>

      <!-- 主图编辑（多选） -->
      <div class="sec">
        <div class="sec-title">主图指标（可多选）</div>
        <div class="chip-wrap">
          <button
            v-for="d in activeCatalog.mainDefs"
            :key="d.id"
            class="opt-chip"
            :class="{ on: mainSet.has(d.id) }"
            :aria-label="`presetEditor.main.${d.id}`"
            @click="toggleMain(d.id)"
          >{{ d.name }}</button>
        </div>
        <div class="sec-title" style="margin-top: 10px">主图自定义（单选）</div>
        <div class="chip-wrap">
          <button
            class="opt-chip"
            :class="{ on: activeCustomID === '' }"
            aria-label="presetEditor.mainCustom.none"
            @click="setActiveCustom('')"
          >无</button>
          <button
            v-for="c in mainCustoms"
            :key="c.id"
            class="opt-chip"
            :class="{ on: activeCustomID === c.id }"
            :aria-label="`presetEditor.mainCustom.${c.name}`"
            @click="setActiveCustom(c.id)"
          >
            <span class="dot" :style="{ background: '#' + c.colorHex }"></span>{{ c.name }}
          </button>
        </div>
      </div>

      <!-- 副图编辑（三槽位单选） -->
      <div v-for="(slot, idx) in subSlots" :key="slot.key" class="sec">
        <div class="sec-title">{{ slot.title }}</div>
        <!-- 当前选择 -->
        <div class="slot-current">
          当前：{{ slotCurrentLabel(slot) }}
          <button class="link" @click="expandedSlot = expandedSlot === slot.key ? null : slot.key">
            {{ expandedSlot === slot.key ? '收起 ▲' : '修改 ▼' }}
          </button>
        </div>
        <!-- 展开的选项列表（分组系统指标 + 自定义） -->
        <template v-if="expandedSlot === slot.key">
          <div v-for="g in activeCatalog.subGroups" :key="g.group" class="chip-wrap">
            <div class="group-cap">{{ g.group }}</div>
            <button
              v-for="k in g.kinds"
              :key="k"
              class="opt-chip"
              :class="{ on: slotSelection(slot).kind === k }"
              :aria-label="`presetEditor.sub.${idx}.${k}`"
              @click="setSubKind(slot, k)"
            >{{ k }}</button>
          </div>
          <div v-if="subCustoms.length > 0" class="chip-wrap">
            <div class="group-cap">自定义</div>
            <button
              v-for="c in subCustoms"
              :key="c.id"
              class="opt-chip"
              :class="{ on: slotSelection(slot).customID === c.id }"
              :aria-label="`presetEditor.sub.${idx}.custom.${c.name}`"
              @click="setSubCustom(slot, c.id)"
            >
              <span class="dot" :style="{ background: '#' + c.colorHex }"></span>{{ c.name }}
            </button>
          </div>
        </template>
      </div>

      <div style="height: 24px"></div>
    </template>

    <div v-else class="loading">加载中…</div>

    <!-- 取消确认（有未保存修改时） -->
    <van-dialog
      v-model:show="confirmOpen"
      title="存在修改未保存，是否取消修改？"
      show-cancel-button
      cancel-button-text="继续编辑"
      confirm-button-text="取消修改"
      confirm-button-color="#ee0a24"
      @confirm="reallyClose"
    />
  </div>
</template>

<script setup lang="ts">
// P2 指标组合期2：组合编辑页（sheet 域 presetEditor）。preset.snapshot 一次下发五套组合
// 完整按周期配置 + 全周期指标目录（catalog）；本地深拷贝编辑（组合 tab × 周期 tab ×
// 主图多选 / 主图自定义单选 / 三副图单选），保存一次性 preset.editCommit 整包提交
// （生效中组合被改 → 原生 configModeRevision bump → 图表即时重算）。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { ChartPresetSnap, PresetCatalogPeriod, PresetSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<PresetSnapshot | null>(null)
/** 本地编辑副本（保存前不写回） */
const draft = ref<ChartPresetSnap[]>([])
const activePresetID = ref('p1')
const activePeriod = ref('日线')
const expandedSlot = ref<string | null>(null)
const confirmOpen = ref(false)
const saving = ref(false)

interface SubSlotView { key: string; title: string }

const subSlots: SubSlotView[] = [
  { key: 'top', title: '副图一' },
  { key: 'bottom', title: '副图二' },
  { key: 'third', title: '副图三' },
]

const activePreset = computed(() =>
  draft.value.find((p) => p.id === activePresetID.value) ?? draft.value[0])
const activeCatalog = computed<PresetCatalogPeriod>(() =>
  snap.value?.catalog.periods.find((c) => c.period === activePeriod.value)
    ?? snap.value?.catalog.periods[0] ?? ({ period: '', mainDefs: [], subGroups: [], customs: [] }))
const mainCustoms = computed(() => activeCatalog.value.customs.filter((c) => c.scope === 'main'))
const subCustoms = computed(() => activeCatalog.value.customs.filter((c) => c.scope === 'sub'))

/** 当前组合当前周期的主图启用集合（缺 key 以默认 MA+CMK 初始化——显式化回退值） */
const mainSet = computed(() => new Set(activePreset.value.mainIndicatorsByPeriod[activePeriod.value]
  ?? activeCatalog.value.mainDefs.filter((d) => ['MA', 'CMK'].includes(d.id)).map((d) => d.id)))

const activeCustomID = computed(() => activePreset.value.activeCustomByPeriod[activePeriod.value] ?? '')

/** 槽位当前选择（缺 key 以默认 CDJ/COL/MACD 初始化口径展示） */
function slotSelection(slot: SubSlotView): { kind: string; customID: string } {
  const sels = activePreset.value.subSelectionsByPeriod[activePeriod.value]
  const defaults = { top: 'CDJ', bottom: 'COL', third: 'MACD' } as Record<string, string>
  if (sels && sels.length === 3) {
    const s = sels[subSlots.indexOf(slot)]
    return { kind: s.customID ? '' : s.kind, customID: s.customID ?? '' }
  }
  return { kind: defaults[slot.key] ?? '', customID: '' }
}

function slotCurrentLabel(slot: SubSlotView): string {
  const sel = slotSelection(slot)
  if (sel.customID) {
    const c = snap.value?.catalog.periods
      .flatMap((p) => p.customs).find((x) => x.id === sel.customID)
    return `自定义「${c?.name ?? sel.customID.slice(0, 8)}」`
  }
  return sel.kind || '未选择'
}

// ===== 编辑动作（只改本地副本） =====
function ensureMainKey(): Record<string, string[]> {
  const p = activePreset.value
  if (!p.mainIndicatorsByPeriod[activePeriod.value]) {
    p.mainIndicatorsByPeriod[activePeriod.value] = [...mainSet.value].sort()
  }
  return p.mainIndicatorsByPeriod
}

function toggleMain(id: string): void {
  const dict = ensureMainKey()
  const arr = dict[activePeriod.value]
  const idx = arr.indexOf(id)
  if (idx >= 0) arr.splice(idx, 1)
  else arr.push(id)
  dict[activePeriod.value] = [...arr].sort()
}

function setActiveCustom(id: string): void {
  const p = activePreset.value
  if (id === '') delete p.activeCustomByPeriod[activePeriod.value]
  else p.activeCustomByPeriod[activePeriod.value] = id
}

function setSubKind(slot: SubSlotView, kind: string): void {
  writeSub(slot, { kind, customID: '' })
}

function setSubCustom(slot: SubSlotView, customID: string): void {
  writeSub(slot, { kind: '', customID })
}

function writeSub(slot: SubSlotView, sel: { kind: string; customID: string }): void {
  const p = activePreset.value
  const sels = p.subSelectionsByPeriod[activePeriod.value]
    ?? [{ kind: 'CDJ', customID: '' }, { kind: 'COL', customID: '' }, { kind: 'MACD', customID: '' }]
  const idx = subSlots.indexOf(slot)
  sels[idx] = sel
  p.subSelectionsByPeriod[activePeriod.value] = sels
}

// ===== 快照与保存 =====
async function pullSnapshot(): Promise<void> {
  try {
    snap.value = ((await klineBus.request('preset', 'snapshot')) ?? {}) as PresetSnapshot
    draft.value = JSON.parse(JSON.stringify(snap.value.presets)) as ChartPresetSnap[]
    // 生效中的组合优先为首个编辑目标
    if (snap.value.mode !== 'local' && draft.value.some((p) => p.id === snap.value?.mode)) {
      activePresetID.value = snap.value.mode
    }
  } catch (e) {
    console.error('preset.snapshot 失败', e)
  }
}

async function save(): Promise<void> {
  if (!snap.value || saving.value) return
  saving.value = true
  try {
    await klineBus.request('preset', 'editCommit', { presets: draft.value })
    // 成功后本弹层关闭（对齐原生编辑链路；设置面板重开即见最新名称）
    emit('close')
  } catch (e) {
    console.error('preset.editCommit 失败', e)
  } finally {
    saving.value = false
  }
}

/** 相对快照是否有修改（名称/启用集合/自定义/副图全字典对比） */
const hasChanges = computed(() => {
  if (!snap.value) return false
  return JSON.stringify(draft.value) !== JSON.stringify(snap.value.presets)
})

function onBack(): void {
  if (hasChanges.value) confirmOpen.value = true
  else reallyClose()
}

function reallyClose(): void {
  emit('close')
}

onMounted(async () => {
  await pullSnapshot()
})
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 10px;
}

.nav-link.save {
  color: #1989fa;
  font-weight: 600;
}

.nav-link.save:disabled {
  color: var(--k-text-tertiary);
  cursor: default;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
}

.pep2 {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
  overflow: hidden;
}

.tab-row {
  display: flex;
  gap: 8px;
  padding: 10px 14px 0;
  overflow-x: auto;
  flex-shrink: 0;
}

.tab-chip {
  border: none;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 13px;
  height: 34px;
  padding: 0 14px;
  border-radius: 8px;
  cursor: pointer;
  flex-shrink: 0;
}

.tab-chip.small {
  height: 30px;
  font-size: 12px;
}

.tab-chip.on {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.tab-chip.active {
  box-shadow: inset 0 0 0 1.5px #1989fa;
}

.name-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 14px;
  flex-shrink: 0;
}

.name-cap {
  font-size: 13px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.name-input {
  flex: 1;
  height: 34px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
  box-sizing: border-box;
}

.pep2 > .sec {
  padding: 8px 14px;
  overflow-y: auto;
}

.sec-title {
  font-size: 13px;
  font-weight: 600;
  margin: 6px 0 8px;
}

.chip-wrap {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin-bottom: 6px;
}

.group-cap {
  font-size: 11px;
  color: var(--k-text-tertiary);
  width: 100%;
}

.opt-chip {
  border: none;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 12px;
  height: 30px;
  padding: 0 12px;
  border-radius: 8px;
  cursor: pointer;
  display: inline-flex;
  align-items: center;
  gap: 5px;
}

.opt-chip.on {
  background: #1989fa;
  color: #ffffff;
  font-weight: 600;
}

.dot {
  width: 12px;
  height: 4px;
  border-radius: 2px;
  display: inline-block;
}

.slot-current {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 13px;
  color: var(--k-text-tertiary);
  padding: 4px 0 8px;
}

.link {
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12.5px;
  cursor: pointer;
  padding: 4px 8px;
}

.loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>
