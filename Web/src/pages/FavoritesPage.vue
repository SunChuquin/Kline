<template>
  <div class="page">
    <div class="banner">自选 · Web 版（P2-1）</div>

    <div v-if="!bridgeOk" class="card-warn">桥接不可达：显示占位界面</div>

    <!-- 分组 Tab（横滚 chips，对齐原生自选页分组条） -->
    <div class="tabs">
      <div
        v-for="(g, i) in groups"
        :key="g.id"
        class="tab-chip"
        :class="{ active: i === activeIdx }"
        @click="activeIdx = i"
      >
        {{ g.name }}<span v-if="g.count > 0" class="tab-count">{{ g.count }}</span>
      </div>
    </div>

    <van-pull-refresh v-model="refreshing" success-text="已刷新" @refresh="onRefresh">
      <div class="rows">
        <van-swipe-cell v-for="row in currentRows" :key="row.file" :disabled="!canEdit">
          <div class="fav-row" @click="openDetail(row)">
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
            <button v-if="canEdit" class="row-more" @click.stop="openMenu(row)">⋯</button>
          </div>
          <template #right>
            <van-button class="swipe-btn pin" type="primary" size="small" @click="togglePin(row)">
              {{ row.pinned ? '取消固顶' : '固顶' }}
            </van-button>
            <van-button v-if="canEdit" class="swipe-btn remove" type="danger" size="small" @click="removeRow(row)">
              移除
            </van-button>
          </template>
        </van-swipe-cell>
        <div v-if="currentRows.length === 0" class="empty">
          {{ loaded ? '该分组暂无自选' : '主库加载中，稍后自动重试…' }}
        </div>
      </div>
    </van-pull-refresh>

    <!-- 长按菜单的等价交互：行内「⋯」按钮 → 动作面板（Vant） -->
    <van-action-sheet
      v-model:show="menuOpen"
      :actions="menuActions"
      cancel-text="取消"
      close-on-click-action
      @select="onMenuSelect"
    />

    <!-- 备注编辑（写回 setNote） -->
    <van-dialog
      v-model:show="noteOpen"
      :title="noteTarget ? `备注 · ${noteTarget.name}` : '备注'"
      show-cancel-button
      @confirm="saveNote"
    >
      <van-field v-model="noteDraft" type="textarea" rows="2" maxlength="100" placeholder="备注内容（空 = 删除）" />
    </van-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { KnownEvents } from '../types/protocol'
import { showToast } from 'vant'

interface FavRow {
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

interface FavGroup {
  id: string
  kind: 'manual' | 'formula'
  name: string
  rows: FavRow[]
}

const bridgeOk = ref(false)
const loaded = ref(false)
const refreshing = ref(false)
const activeIdx = ref(0)
const groups = ref<FavGroup[]>([])
/** 「全部」虚拟分组 id（原生 no-op 语义：固顶/移除/排序需在具体分组内） */
const allGroupId = ref('')

const currentRows = computed<FavRow[]>(() => groups.value[activeIdx.value]?.rows ?? [])
const currentGroupId = computed(() => groups.value[activeIdx.value]?.id ?? null)

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

async function pullSnapshot(): Promise<void> {
  try {
    const s = ((await klineBus.request('favorites', 'snapshot')) ?? {}) as Record<string, unknown>
    loaded.value = s.loaded === true
    allGroupId.value = String(s.allGroupId ?? '')
    const raw = Array.isArray(s.groups) ? (s.groups as Record<string, unknown>[]) : []
    groups.value = raw.map((g) => ({
      id: String(g.id ?? ''),
      kind: (g.kind === 'formula' ? 'formula' : 'manual') as FavGroup['kind'],
      name: String(g.name ?? ''),
      rows: (Array.isArray(g.rows) ? (g.rows as Record<string, unknown>[]) : []).map((r) => ({
        file: String(r.file ?? ''),
        code: String(r.code ?? ''),
        name: String(r.name ?? ''),
        latestPrice: typeof r.latestPrice === 'number' ? r.latestPrice : null,
        change: typeof r.change === 'number' ? r.change : null,
        changePct: typeof r.changePct === 'number' ? r.changePct : null,
        volume: typeof r.volume === 'number' ? r.volume : null,
        turnover: typeof r.turnover === 'number' ? r.turnover : null,
        lastDate: String(r.lastDate ?? ''),
        pinned: r.pinned === true,
        note: String(r.note ?? ''),
      })),
    }))
    // 选中分组失效时回首个 Tab
    if (activeIdx.value >= groups.value.length) activeIdx.value = 0
  } catch (e) {
    console.error('favorites.snapshot 失败', e)
  }
}

async function onRefresh(): Promise<void> {
  if (!bridgeOk.value) {
    refreshing.value = false
    return
  }
  try {
    await klineBus.request('favorites', 'refresh', { group: currentGroupId.value })
    // 刷新异步完成：定时回读两次兜底（数据落缓存时机不确定；native 模式另有 favorites.changed 事件）
    setTimeout(() => void pullSnapshot(), 1500)
    setTimeout(async () => {
      await pullSnapshot()
      refreshing.value = false
    }, 3500)
  } catch {
    refreshing.value = false
  }
}

function openDetail(row: FavRow): void {
  klineBus.request('favorites', 'openDetail', { file: row.file }).catch((e) => console.error(e))
}

// MARK: - 写回交互（P2-1b）：固顶/移除/排序/备注

const menuOpen = ref(false)
const noteOpen = ref(false)
const noteDraft = ref('')
const menuTarget = ref<FavRow | null>(null)
const noteTarget = ref<FavRow | null>(null)

/** 当前分组是否支持写回：manual 实体分组（「全部」虚拟分组与公式分组只读） */
const canEdit = computed(() => {
  const g = groups.value[activeIdx.value]
  return !!g && g.kind === 'manual' && g.id !== allGroupId.value
})

const menuActions = computed(() => {
  const row = menuTarget.value
  if (!row) return []
  const actions: { name: string; value: string; color?: string }[] = []
  if (canEdit.value) {
    actions.push({ name: row.pinned ? '取消固顶' : '固顶', value: 'togglePin' })
    actions.push({ name: '移到最前', value: 'first' })
    actions.push({ name: '移到最后', value: 'last' })
    actions.push({ name: '备注', value: 'note' })
    actions.push({ name: '从分组移除', value: 'remove', color: '#ee0a24' })
  } else {
    actions.push({ name: '备注', value: 'note' })
  }
  return actions
})

function openMenu(row: FavRow): void {
  menuTarget.value = row
  menuOpen.value = true
}

function onMenuSelect(action: { value: string }): void {
  const row = menuTarget.value
  if (!row) return
  switch (action.value) {
    case 'togglePin':
      void writeBack('setPinned', { file: row.file, pinned: !row.pinned, group: currentGroupId.value })
      break
    case 'first':
    case 'last':
      void writeBack('moveTo', { file: row.file, where: action.value, group: currentGroupId.value })
      break
    case 'note':
      noteTarget.value = row
      noteDraft.value = row.note
      noteOpen.value = true
      break
    case 'remove':
      void writeBack('removeFromGroup', { file: row.file, group: currentGroupId.value })
      break
  }
}

function togglePin(row: FavRow): void {
  void writeBack('setPinned', { file: row.file, pinned: !row.pinned, group: currentGroupId.value })
}

function removeRow(row: FavRow): void {
  void writeBack('removeFromGroup', { file: row.file, group: currentGroupId.value })
}

function saveNote(): void {
  const row = noteTarget.value
  if (!row) return
  void writeBack('setNote', { file: row.file, note: noteDraft.value })
}

/** 写回公共路径：动作成功即回读快照（写回模式 v2：状态以回读为准） */
async function writeBack(action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('favorites', action, payload)
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
    console.error(action, e)
  }
}

onMounted(async () => {
  const t = await klineBus.detect()
  bridgeOk.value = t !== 'none'
  if (!bridgeOk.value) return

  // native 模式：数据变化事件触发回读（pc 模式由刷新后的定时回读兜底）
  klineBus.on('favorites.changed', () => void pullSnapshot())

  await pullSnapshot()
  // 主库未就绪（冷启动竞态）：3s 后重试一次
  if (!loaded.value) {
    setTimeout(() => void pullSnapshot(), 3000)
  }
})
</script>

<style scoped>
.page {
  min-height: 100%;
  padding: 8px 0 16px;
  background: var(--k-bg);
}

.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 6px 12px 8px;
}

.card-warn {
  margin: 0 12px 10px;
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px 16px;
  font-size: 13px;
  color: #b25000;
}

/* 分组 Tab：横滚 chips */
.tabs {
  display: flex;
  gap: 8px;
  padding: 0 12px 10px;
  overflow-x: auto;
  white-space: nowrap;
}

.tab-chip {
  flex-shrink: 0;
  padding: 7px 14px;
  border-radius: 16px;
  font-size: 14px;
  color: var(--k-text-secondary);
  background: var(--k-bg-secondary);
}

.tab-chip.active {
  color: #ffffff;
  background: var(--k-accent);
}

.tab-count {
  margin-left: 4px;
  font-size: 11px;
  opacity: 0.85;
}

/* 行列表：高密度（44pt 触达 + 紧凑间距） */
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
