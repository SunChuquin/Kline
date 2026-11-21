<template>
  <div class="snap-card">
    <template v-for="(r, i) in modelValue.rows" :key="i">
      <div v-if="i > 0 && r.kind !== 'note'" class="divider"></div>
      <button
        v-if="r.button"
        class="row"
        :disabled="r.disabled"
        :aria-label="r.aria"
        @click="emit('act', r.act ?? '')"
      >
        <span class="row-title" :class="{ dim: r.dim, danger: r.danger }">{{ r.title }}</span>
        <span v-if="r.value" class="row-value" :class="[r.tone, { wrap: r.wrap }]" :aria-label="r.valueAria">{{ r.value }}</span>
        <span v-if="r.glyph" class="st-icon" :class="r.iconTone">{{ r.glyph }}</span>
      </button>
      <div v-else-if="r.kind === 'note'" class="note-block">{{ r.value }}</div>
      <div v-else-if="r.kind === 'detail'" class="detail-line" :aria-label="r.aria">{{ r.value }}</div>
      <div v-else class="row" :aria-label="r.aria">
        <span class="row-title" :class="{ dim: r.dim, danger: r.danger }">{{ r.title }}</span>
        <span v-if="r.value" class="row-value" :class="[r.tone, { wrap: r.wrap }]" :aria-label="r.valueAria">{{ r.value }}</span>
        <span v-if="r.glyph" class="st-icon" :class="r.iconTone">{{ r.glyph }}</span>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
// k-snap-card：快照行卡（title + 可选值/状态圆圈图标，行可点/可禁用/可着色）。
// 哑组件：rows 由 adapter 从模块快照组装注入；button 行点击抛 act 字符串。
// 行形态对齐 LocalUpdatePanel / EngineLabPanel 的 .row（48px + divider + st-icon）。
export interface SnapRow {
  kind?: 'row' | 'note' | 'detail'
  button?: boolean
  title?: string
  value?: string
  /** 值文字着色：tone-gray/yellow/green/red/orange */
  tone?: string
  /** 状态圆圈图标字符（⟳ ✓ ✕ ◌ ⤓ ▣ ▶ ①…） */
  glyph?: string
  /** 图标底色：state-gray/yellow/green/red/blue */
  iconTone?: string
  dim?: boolean
  danger?: boolean
  disabled?: boolean
  /** 值允许换行（长状态文案/路径） */
  wrap?: boolean
  /** button 行点击动作名 */
  act?: string
  /** 行容器 aria-label */
  aria?: string
  /** 值 span 上的复合 aria-label（如 gapBackfill.status|尚未运行，UITest 前缀匹配读值） */
  valueAria?: string
}

export interface SnapCardState {
  rows: SnapRow[]
}

withDefaults(defineProps<{
  modelValue?: SnapCardState
}>(), {
  modelValue: () => ({ rows: [] }),
})

const emit = defineEmits<{
  (e: 'act', act: string): void
}>()
</script>

<style scoped>
.snap-card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  overflow: hidden;
  margin-bottom: 6px;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 16px;
}

.row {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 48px;
  padding: 0 16px;
  border: none;
  background: none;
  cursor: pointer;
  text-align: left;
  color: var(--k-text, #000);
}

.row:disabled { cursor: default; }

.row-title {
  font-size: 16px;
  color: var(--k-text, #000);
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.row-title.dim { color: var(--k-text-tertiary, #c7c7cb); }

.row-title.danger { color: #ff3b30; }

.row-value {
  font-size: 15px;
  color: var(--k-text-secondary, #6c6c70);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 62%;
  text-align: right;
}

.row-value.wrap {
  white-space: normal;
  word-break: break-all;
  line-height: 1.35;
}

.st-icon {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 600;
  flex-shrink: 0;
}

.state-gray { background: rgba(128, 128, 128, 0.22); color: #8e8e93; }
.state-yellow { background: rgba(255, 204, 0, 0.25); color: #cc9900; }
.state-green { background: rgba(52, 199, 89, 0.2); color: var(--k-ok, #34c759); }
.state-red { background: rgba(255, 59, 48, 0.2); color: #ff3b30; }
.state-blue { background: rgba(0, 122, 255, 0.15); color: var(--k-accent, #007aff); font-size: 16px; }

.tone-gray { color: var(--k-text-secondary, #6c6c70); }
.tone-yellow { color: #cc9900; }
.tone-green { color: var(--k-ok, #34c759); }
.tone-red { color: #ff3b30; }
.tone-orange { color: #ff9500; }

.note-block {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 10px 16px;
  line-height: 1.5;
}

.detail-line {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 8px 16px;
  line-height: 1.5;
  word-break: break-all;
}
</style>
