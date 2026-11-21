<template>
  <van-pull-refresh
    :model-value="!!modelValue.refreshing"
    success-text="已刷新"
    @update:model-value="onRefreshing"
  >
    <div class="rows">
      <van-swipe-cell v-for="row in modelValue.rows" :key="row.file" :disabled="!modelValue.canEdit">
        <div class="fav-row" @click="emit('open', row)">
          <div class="row-left">
            <div class="row-name">
              {{ row.name }}
              <span v-if="row.pinned" class="pin-tag">顶</span>
            </div>
            <div class="row-code">{{ row.code }}</div>
          </div>
          <div class="row-right">
            <div class="row-price" :class="tintClass(row)">{{ fmtPrice(row) }}</div>
            <div class="row-pct" :class="tintClass(row)">{{ fmtPct(row) }}</div>
          </div>
          <button v-if="modelValue.canEdit" class="row-more" @click.stop="emit('menu', row)">⋯</button>
        </div>
        <template #right>
          <van-button class="swipe-btn pin" type="primary" size="small" @click="emit('pin', row)">
            {{ row.pinned ? '取消固顶' : '固顶' }}
          </van-button>
          <van-button v-if="modelValue.canEdit" class="swipe-btn remove" type="danger" size="small" @click="emit('remove', row)">
            移除
          </van-button>
        </template>
      </van-swipe-cell>
      <div v-if="modelValue.rows.length === 0" class="empty">
        {{ modelValue.loaded ? '该分组暂无自选' : '主库加载中，稍后自动重试…' }}
      </div>
    </div>
  </van-pull-refresh>
</template>

<script setup lang="ts">
// k-favorites-view：自选页数据密集区（下拉刷新 + 左滑固顶/移除 + 行卡片 + 空态）。
// 迁移自 FavoritesPage.vue 行列表区；行数据/编辑权限由 adapter 注入，
// 行级动作 open/menu/pin/remove 与 refresh 抛给 adapter。
export interface FavRow {
  file: string
  code: string
  name: string
  latestPrice: number | null
  change: number | null
  changePct: number | null
  volume: number | null
  turnover: number | null
  lastDate: string
  pinned: boolean
  note: string
}

export interface FavoritesViewValue {
  rows?: FavRow[]
  canEdit?: boolean
  loaded?: boolean
  refreshing?: boolean
}

const props = withDefaults(defineProps<{
  modelValue?: FavoritesViewValue
}>(), {
  modelValue: () => ({ rows: [], canEdit: false, loaded: false, refreshing: false }),
})

const emit = defineEmits<{
  (e: 'update:modelValue', v: FavoritesViewValue): void
  (e: 'open', row: FavRow): void
  (e: 'menu', row: FavRow): void
  (e: 'pin', row: FavRow): void
  (e: 'remove', row: FavRow): void
  (e: 'refresh'): void
}>()

function onRefreshing(v: boolean): void {
  emit('update:modelValue', { ...props.modelValue, refreshing: v })
  if (v) emit('refresh')
}

function fmtPrice(row: FavRow): string {
  return row.latestPrice === null ? '—' : row.latestPrice.toFixed(2)
}

function fmtPct(row: FavRow): string {
  if (row.changePct === null) return '—'
  const sign = row.changePct > 0 ? '+' : ''
  return `${sign}${row.changePct.toFixed(2)}%`
}

/** 红涨绿跌（对齐原生 tintColor：systemRed 涨 / systemGreen 跌） */
function tintClass(row: FavRow): string {
  const pct = row.changePct ?? 0
  if (pct > 0) return 'up'
  if (pct < 0) return 'down'
  return ''
}
</script>

<style scoped>
.rows {
  padding: 0 12px;
}

.fav-row {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 52px;
  padding: 6px 34px 6px 12px;
  margin-bottom: 8px;
  background: var(--k-bg-secondary);
  border-radius: 10px;
  cursor: pointer;
}

.fav-row:active {
  opacity: 0.6;
}

.row-more {
  position: absolute;
  right: 8px;
  top: 50%;
  transform: translateY(-50%);
  width: 26px;
  height: 26px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 18px;
  font-weight: 700;
  padding: 0;
  cursor: pointer;
}

.swipe-btn {
  height: 100%;
  border-radius: 0;
}

.swipe-btn.pin {
  width: 72px;
}

.swipe-btn.remove {
  width: 60px;
}

.row-left {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.row-name {
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
}

.pin-tag {
  display: inline-block;
  font-size: 10px;
  font-weight: 600;
  color: var(--k-accent);
  border: 1px solid var(--k-accent);
  border-radius: 4px;
  padding: 0 3px;
  margin-left: 4px;
  vertical-align: middle;
}

.row-code {
  font-size: 12px;
  color: var(--k-text-secondary);
}

.row-right {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 2px;
  font-variant-numeric: tabular-nums;
}

.row-price {
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
}

.row-pct {
  font-size: 12px;
}

.row-price.up,
.row-pct.up {
  color: #ff4d4f;
}

.row-price.down,
.row-pct.down {
  color: #00b578;
}

.empty {
  text-align: center;
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 32px 0;
}
</style>
