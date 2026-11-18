<template>
  <div class="page">
    <div class="banner">行情 · Web 版（P2-2）</div>

    <div v-if="!bridgeOk" class="card-warn">桥接不可达：显示占位界面</div>

    <!-- 顶部：左设置 + 居中一级菜单 + 右公式/搜索（对齐原生 MarketHeaderBar） -->
    <div class="header">
      <button class="hbtn" aria-label="行情表设置" @click="openConfigPanel">
        <van-icon name="setting-o" />
      </button>
      <div class="menu">
        <div
          v-for="m in topMenus"
          :key="m.key"
          class="menu-item"
          :class="{ active: m.key === topMenu }"
          role="button"
          @click="tapTopMenu(m.key)"
        >
          {{ m.title }}
          <van-icon v-if="m.key === topMenu" :name="secondVisible ? 'arrow-up' : 'arrow-down'" class="menu-chev" />
        </div>
      </div>
      <div class="right-btns">
        <button v-if="topMenu === 'picker'" class="hbtn fx" aria-label="公式管理" @click="openFormulaCenter">ƒx</button>
        <button class="hbtn" aria-label="搜索标的" @click="openSearch">
          <van-icon name="search" />
        </button>
      </div>
    </div>

    <!-- 二级分类条（chips） -->
    <div class="seconds" v-if="secondVisible && seconds.length">
      <div
        v-for="s in seconds"
        :key="s.key"
        class="chip"
        :class="{ active: s.active }"
        role="button"
        @click="selectSecond(s.key)"
      >
        {{ s.title }}<span v-if="s.count !== null" class="chip-count">{{ s.count }}</span>
      </div>
    </div>

    <!-- 主体：加载态 / 空态 / 表格（下拉刷新 + 虚拟滚动 + 冻结列） -->
    <div v-if="!loaded" class="empty">主库加载中，稍后自动重试…</div>
    <div v-else-if="rows.length === 0" class="empty">暂无标的</div>
    <van-pull-refresh v-else v-model="refreshing" success-text="已刷新" @refresh="onRefresh">
      <div
        ref="scrollEl"
        class="table-scroll"
        @scroll.passive="onScroll"
      >
        <div class="table-inner" :style="{ width: totalW + 'px' }">
          <!-- 表头（吸顶） -->
          <div class="thead" :style="{ width: totalW + 'px' }">
            <div
              v-for="col in columns"
              :key="col.field + (col.isNameCode ? '_nc' : '')"
              class="th"
              :class="{ 'th-frozen': col.isNameCode, right: !col.isNameCode }"
              :style="col.isNameCode ? frozenStyle(col) : { width: col.width + 'px' }"
              role="button"
              @click="tapHeader(col)"
            >
              <span class="th-title">{{ col.title }}</span>
              <van-icon
                v-if="col.field === sortField"
                :name="sortAsc ? 'arrow-up' : 'arrow-down'"
                class="sort-icon"
              />
            </div>
          </div>
          <!-- 虚拟滚动：上占位 + 可见行切片 + 下占位 -->
          <div :style="{ height: startIdx * ROW_H + 'px' }"></div>
          <div
            v-for="row in visibleRows"
            :key="row.file"
            class="trow"
            :class="{ pinned: row.pinned }"
            :style="{ width: totalW + 'px', height: ROW_H + 'px' }"
            @click="openDetail(row)"
          >
            <div
              v-for="col in columns"
              :key="col.field + (col.isNameCode ? '_nc' : '')"
              class="td"
              :class="{ 'td-frozen': col.isNameCode, right: !col.isNameCode }"
              :style="col.isNameCode ? frozenStyle(col) : { width: col.width + 'px' }"
            >
              <template v-if="col.isNameCode">
                <div class="name-cell">
                  <div class="name-line">
                    <span class="row-name">{{ row.name }}</span>
                    <button class="row-add" :class="{ faved: row.fav }" aria-label="加自选" @click.stop="openAddSheet(row)">
                      {{ row.fav ? '✓' : '+' }}
                    </button>
                  </div>
                  <div class="row-code">{{ row.code }}</div>
                </div>
              </template>
              <template v-else>
                <span :class="tintClass(row, col.field)">{{ fmtCell(row, col.field) }}</span>
              </template>
            </div>
          </div>
          <div :style="{ height: (rows.length - endIdx) * ROW_H + 'px' }"></div>
          <div v-if="rows.length === 0" class="empty-inline">该分类暂无标的</div>
        </div>
      </div>
    </van-pull-refresh>

    <!-- 行情表设置面板（Vant 化 MarketColumnConfigPanel：草稿编辑 + 完成写回） -->
    <van-popup v-model:show="configOpen" position="bottom" :style="{ height: '88%' }" round>
      <div class="cfg-panel">
        <div class="cfg-header">
          <button class="cfg-btn muted" @click="configOpen = false">取消</button>
          <span class="cfg-title">行情表设置</span>
          <button class="cfg-btn warn" @click="resetConfig">重置</button>
          <button class="cfg-btn primary" @click="saveConfig">完成</button>
        </div>
        <div class="cfg-body">
          <div class="cfg-section-title">表格冻结</div>
          <div class="cfg-row" v-if="draftColumns.length >= 1">
            <span>第 1 列（{{ draftColumns[0].title }}）</span>
            <van-switch :model-value="true" size="20px" disabled />
          </div>
          <div class="cfg-row" v-if="draftColumns.length >= 2">
            <span>第 2 列（{{ draftColumns[1].title }}）</span>
            <van-switch :model-value="draftFrozen >= 2" size="20px" @update:model-value="(v: boolean) => (draftFrozen = v ? Math.max(draftFrozen, 2) : 1)" />
          </div>
          <div class="cfg-row" v-if="draftColumns.length >= 3">
            <span>第 3 列（{{ draftColumns[2].title }}）</span>
            <van-switch :model-value="draftFrozen >= 3" size="20px" @update:model-value="(v: boolean) => (draftFrozen = v ? 3 : 2)" />
          </div>

          <div class="cfg-section-title">表头设置</div>
          <div class="cfg-row fixed-row">
            <span>名称/代码</span>
            <span class="cfg-note">恒显示置顶</span>
          </div>
          <div class="cfg-row" v-for="(c, i) in movableDraft" :key="c.field">
            <span class="cfg-field">{{ c.title }}</span>
            <button
              v-if="c.filterOptions"
              class="filter-btn"
              :class="{ on: c.filterLabels.length > 0 }"
              @click="openFilter(i)"
            >
              {{ c.filterLabels.length > 0 ? `已选${c.filterLabels.length}项` : '筛选' }}
            </button>
            <div class="move-btns">
              <button class="mv" :disabled="i === 0" @click="moveDraft(i, -1)">↑</button>
              <button class="mv" :disabled="i === movableDraft.length - 1" @click="moveDraft(i, 1)">↓</button>
            </div>
            <van-switch v-model="c.visible" size="20px" />
          </div>
          <div class="cfg-foot-note">
            • 数值字段可设置范围筛选，多字段同时生效（取交集）<br />
            • 点击表头切换排序：降→升→取消（三击循环）
          </div>
        </div>
      </div>
    </van-popup>

    <!-- 字段筛选多选浮层（对齐原生 FilterOptionsPanel：点选项不收起） -->
    <van-popup v-model:show="filterOpen" position="center" :style="{ width: '72%' }" round>
      <div class="filter-panel">
        <div class="filter-title">{{ filterTarget ? filterTarget.title : '' }}筛选</div>
        <div class="filter-list">
          <div class="filter-row" @click="filterTarget!.filterLabels = []">
            <span>全部（不筛选）</span>
            <van-icon v-if="filterTarget && filterTarget.filterLabels.length === 0" name="success" class="check" />
          </div>
          <div
            v-for="opt in filterTarget?.filterOptions ?? []"
            :key="opt"
            class="filter-row"
            @click="toggleFilterLabel(opt)"
          >
            <span>{{ opt }}</span>
            <van-icon
              v-if="filterTarget && filterTarget.filterLabels.includes(opt)"
              name="success"
              class="check"
            />
          </div>
        </div>
        <button class="filter-done" @click="filterOpen = false">完成</button>
      </div>
    </van-popup>

    <!-- 加自选浮层（Vant 化 AddToGroupSheet：一键自选 + 新建分组 + 分组多选 toggle） -->
    <van-popup v-model:show="addOpen" position="bottom" round>
      <div class="add-panel">
        <div class="add-header">
          <button class="cfg-btn muted" @click="addOpen = false">取消</button>
          <span class="cfg-title">加入分组</span>
          <button class="cfg-btn primary" @click="addOpen = false">完成</button>
        </div>
        <div class="add-meta" v-if="addTarget">
          <div>
            <div class="add-name">{{ addTarget.name }}</div>
            <div class="row-code">{{ addTarget.code }}</div>
          </div>
          <button
            class="fav-toggle"
            :class="{ faved: addTarget.fav }"
            @click="toggleFavorite"
          >
            {{ addTarget.fav ? '★ 已自选' : '☆ 一键加自选' }}
          </button>
        </div>
        <button class="add-new-group" @click="newGroupOpen = true">
          <span class="plus">＋</span> 新建自定义分组
        </button>
        <div class="add-list">
          <div v-if="addGroups.length === 0" class="empty-inline">暂无自定义分组，点击上方「新建自定义分组」</div>
          <div v-for="g in addGroups" :key="g.id" class="add-row" role="button" @click="toggleGroup(g)">
            <div>
              <div class="add-group-name">{{ g.name }}</div>
              <div class="row-code">{{ g.count }} 只</div>
            </div>
            <van-icon :name="g.member ? 'checked' : 'circle'" class="member-icon" :class="{ on: g.member }" />
          </div>
        </div>
      </div>
    </van-popup>

    <!-- 新建分组对话框 -->
    <van-dialog
      v-model:show="newGroupOpen"
      title="新建自定义分组"
      show-cancel-button
      @confirm="createGroup"
    >
      <van-field v-model="newGroupName" placeholder="例如：科技龙头" maxlength="20" />
    </van-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { showToast } from 'vant'

// ===== 协议形状（web/src/types/protocol.ts 对拍） =====
interface MarketColumn {
  field: string
  isNameCode: boolean
  title: string
  width: number
}

interface MarketRowSnap {
  file: string
  code: string
  name: string
  fav: boolean
  pinned: boolean
  pct: number | null
  values: Record<string, number | null>
}

interface SecondItem {
  key: string
  title: string
  active: boolean
  count: number | null
}

interface CfgColumn {
  field: string
  title: string
  fixed: boolean
  visible: boolean
  widthOverride: number | null
  filterLabels: string[]
  filterOptions: string[] | null
}

interface GroupInfo {
  id: string
  name: string
  count: number
  member: boolean
}

// ===== 页面状态 =====
const ROW_H = 45
const BUFFER = 8

const bridgeOk = ref(false)
const loaded = ref(false)
const refreshing = ref(false)
const topMenu = ref('市场')
const secondVisible = ref(true)
const seconds = ref<SecondItem[]>([])
const columns = ref<MarketColumn[]>([])
const sortField = ref<string | null>(null)
const sortAsc = ref(false)
const rows = ref<MarketRowSnap[]>([])

const topMenus = [
  { key: '市场', title: '市场' },
  { key: '选股', title: '选股' },
  { key: '自选', title: '自选' },
]

// ===== 虚拟滚动（行高恒定，只渲染视口 ± buffer 切片） =====
const scrollEl = ref<HTMLElement | null>(null)
const startIdx = ref(0)
const endIdx = ref(0)

const visibleRows = computed(() => rows.value.slice(startIdx.value, endIdx.value))
const totalW = computed(() => columns.value.reduce((sum, c) => sum + c.width, 0))

function onScroll(): void {
  const el = scrollEl.value
  if (!el) return
  const first = Math.max(0, Math.floor(el.scrollTop / ROW_H) - BUFFER)
  const last = Math.min(rows.value.length, Math.ceil((el.scrollTop + el.clientHeight) / ROW_H) + BUFFER)
  startIdx.value = first
  endIdx.value = last
}

function resetScrollWindow(): void {
  const el = scrollEl.value
  const first = Math.max(0, Math.floor((el?.scrollTop ?? 0) / ROW_H) - BUFFER)
  const clientH = scrollEl.value?.clientHeight ?? 600
  const last = Math.min(rows.value.length, Math.ceil(((el?.scrollTop ?? 0) + clientH) / ROW_H) + BUFFER)
  startIdx.value = first
  endIdx.value = last
}

// ===== 冻结列样式（sticky left；宽度用快照列宽，含用户覆盖） =====
function frozenStyle(col: MarketColumn): Record<string, string> {
  const w = `${col.width}px`
  return { position: 'sticky', left: '0', width: w, minWidth: w, maxWidth: w }
}

// ===== 数值格式化（对齐原生 MarketRow.render） =====
function fmtNum(v: number): string {
  return v.toFixed(2)
}

function fmtSigned(v: number, suffix = ''): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}${suffix}`
}

function fmtVolume(v: number): string {
  if (v >= 100_000_000) return `${(v / 100_000_000).toFixed(2)}亿`
  if (v >= 10_000) return `${(v / 10_000).toFixed(2)}万`
  return v.toFixed(0)
}

const TINTED_FIELDS = new Set([
  'latestPrice', 'prevClose', 'change', 'changePct', 'open', 'high', 'low',
  'amplitude', 'volRatio', 'pct3d', 'pct5d', 'pct10d', 'pct20d', 'pct60d', 'pctYTD',
])

function fmtCell(row: MarketRowSnap, field: string): string {
  const v = row.values[field]
  if (v === null || v === undefined) return '—'
  switch (field) {
    case 'volume':
    case 'turnover':
      return fmtVolume(v)
    case 'change':
      return fmtSigned(v)
    case 'changePct':
    case 'amplitude':
    case 'turnoverRate':
    case 'pct3d':
    case 'pct5d':
    case 'pct10d':
    case 'pct20d':
    case 'pct60d':
    case 'pctYTD':
      return fmtSigned(v, '%')
    default:
      return fmtNum(v)
  }
}

/** 红涨绿跌（对齐原生 tintColor：changePct 正负定色） */
function tintClass(row: MarketRowSnap, field: string): string {
  if (!TINTED_FIELDS.has(field)) return ''
  const pct = row.pct ?? 0
  if (pct > 0) return 'up'
  if (pct < 0) return 'down'
  return ''
}

// ===== 快照回读 =====
async function pullSnapshot(): Promise<void> {
  try {
    const s = ((await klineBus.request('market', 'snapshot')) ?? {}) as Record<string, unknown>
    loaded.value = s.loaded === true
    topMenu.value = String(s.topMenu ?? '市场')
    seconds.value = (Array.isArray(s.seconds) ? (s.seconds as Record<string, unknown>[]) : []).map((x) => ({
      key: String(x.key ?? ''),
      title: String(x.title ?? ''),
      active: x.active === true,
      count: typeof x.count === 'number' ? x.count : null,
    }))
    columns.value = (Array.isArray(s.columns) ? (s.columns as Record<string, unknown>[]) : []).map((c) => ({
      field: String(c.field ?? ''),
      isNameCode: c.isNameCode === true,
      title: String(c.title ?? ''),
      width: typeof c.width === 'number' ? c.width : 108,
    }))
    sortField.value = typeof s.sortField === 'string' ? s.sortField : null
    sortAsc.value = s.sortAsc === true
    rows.value = (Array.isArray(s.rows) ? (s.rows as Record<string, unknown>[]) : []).map((r) => ({
      file: String(r.file ?? ''),
      code: String(r.code ?? ''),
      name: String(r.name ?? ''),
      fav: r.fav === true,
      pinned: r.pinned === true,
      pct: typeof r.pct === 'number' ? r.pct : null,
      values: (r.values ?? {}) as Record<string, number | null>,
    }))
    resetScrollWindow()
  } catch (e) {
    console.error('market.snapshot 失败', e)
  }
}

// ===== 分类切换（一级菜单展开/收起对齐原生 tapTopMenu 交互） =====
function tapTopMenu(key: string): void {
  if (secondVisible.value) {
    if (topMenu.value === key) {
      secondVisible.value = false
      return
    }
  } else {
    secondVisible.value = true
  }
  void actAndReload('select', { menu: key })
}

function selectSecond(key: string): void {
  void actAndReload('select', { menu: topMenu.value, second: key })
}

async function actAndReload(action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('market', action, payload)
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
    console.error(action, e)
  }
}

// ===== 刷新 / 进详情 / 原生浮层入口 =====
async function onRefresh(): Promise<void> {
  if (!bridgeOk.value) {
    refreshing.value = false
    return
  }
  try {
    await klineBus.request('market', 'refresh', {})
    setTimeout(() => void pullSnapshot(), 1200)
    setTimeout(async () => {
      await pullSnapshot()
      refreshing.value = false
    }, 2500)
  } catch {
    refreshing.value = false
  }
}

function openDetail(row: MarketRowSnap): void {
  klineBus.request('market', 'openDetail', { file: row.file }).catch((e) => console.error(e))
}

function openSearch(): void {
  klineBus.request('market', 'openSearch', {}).catch((e) => console.error(e))
}

function openFormulaCenter(): void {
  klineBus.request('market', 'openFormulaCenter', {}).catch((e) => console.error(e))
}

// ===== 表头排序（三击循环语义在原生 toggleSort） =====
function tapHeader(col: MarketColumn): void {
  if (col.isNameCode) return
  void actAndReload('sortToggle', { field: col.field })
}

// ===== 列配置面板（草稿编辑 + 完成写回） =====
interface DraftCol extends CfgColumn {
  visible: boolean
  filterLabels: string[]
}

const configOpen = ref(false)
const draftColumns = ref<DraftCol[]>([])
const draftFrozen = ref(3)
const draftSortRule = ref<{ field: string; order: string } | null>(null)

/** 非固定列子集（拖动排序 / 显隐只作用于此范围；v-for 引用同 draftColumns 内对象） */
const movableDraft = computed(() => draftColumns.value.filter((c) => !c.fixed))

async function openConfigPanel(): Promise<void> {
  configOpen.value = true
  await loadConfigDraft()
}

async function loadConfigDraft(): Promise<void> {
  try {
    const s = ((await klineBus.request('market', 'configSnapshot')) ?? {}) as Record<string, unknown>
    draftColumns.value = (Array.isArray(s.columns) ? (s.columns as Record<string, unknown>[]) : []).map((c) => ({
      field: String(c.field ?? ''),
      title: String(c.title ?? ''),
      fixed: c.fixed === true,
      visible: c.visible === true,
      widthOverride: typeof c.widthOverride === 'number' ? c.widthOverride : null,
      filterLabels: Array.isArray(c.filterLabels) ? (c.filterLabels as string[]) : [],
      filterOptions: Array.isArray(c.filterOptions) ? (c.filterOptions as string[]) : null,
    }))
    draftFrozen.value = typeof s.frozenCount === 'number' ? s.frozenCount : 3
    const rule = s.sortRule as Record<string, unknown> | null
    draftSortRule.value = rule && typeof rule.field === 'string'
      ? { field: String(rule.field), order: String(rule.order ?? 'descending') }
      : null
  } catch (e) {
    console.error('market.configSnapshot 失败', e)
  }
}

/** ↑↓ 移动非固定列顺序（对齐原生 onMove 语义：只重排非固定子集） */
function moveDraft(idxInMovable: number, dir: number): void {
  const movables = movableDraft.value
  const j = idxInMovable + dir
  if (j < 0 || j >= movables.length) return
  const a = movables[idxInMovable]
  const b = movables[j]
  const cols = draftColumns.value
  const ia = cols.indexOf(a)
  const ib = cols.indexOf(b)
  cols[ia] = b
  cols[ib] = a
}

async function saveConfig(): Promise<void> {
  const payloadCols = draftColumns.value
    .filter((c) => !c.fixed)
    .map((c) => ({ field: c.field, visible: c.visible, filterLabels: c.filterLabels }))
  await actAndReload('configSet', {
    columns: payloadCols,
    sortRule: draftSortRule.value,
    frozenCount: draftFrozen.value,
  })
  configOpen.value = false
}

/** 重置：立即生效（偏离原生「重置仅改草稿」——Web 版恢复默认直达，面板保持打开可继续调整） */
async function resetConfig(): Promise<void> {
  try {
    await klineBus.request('market', 'configReset')
    await loadConfigDraft()
    await pullSnapshot()
    showToast({ message: '已恢复默认', duration: 1200 })
  } catch (e) {
    console.error(e)
  }
}

// ===== 字段筛选多选（点选项不收起，点完成/外部收起） =====
const filterOpen = ref(false)
const filterTarget = ref<DraftCol | null>(null)

function openFilter(idxInMovable: number): void {
  filterTarget.value = movableDraft.value[idxInMovable] ?? null
  if (filterTarget.value) filterOpen.value = true
}

function toggleFilterLabel(opt: string): void {
  const t = filterTarget.value
  if (!t) return
  const i = t.filterLabels.indexOf(opt)
  if (i >= 0) t.filterLabels.splice(i, 1)
  else t.filterLabels.push(opt)
}

// ===== 加自选浮层（写回走目标态动作，成功即回读） =====
const addOpen = ref(false)
const addTarget = ref<MarketRowSnap | null>(null)
const addGroups = ref<GroupInfo[]>([])
const addFavState = ref(false)
const newGroupOpen = ref(false)
const newGroupName = ref('')

async function openAddSheet(row: MarketRowSnap): Promise<void> {
  addTarget.value = row
  addOpen.value = true
  await pullGroupInfo(row.file)
}

async function pullGroupInfo(file: string): Promise<void> {
  try {
    const s = ((await klineBus.request('market', 'groupInfo', { file })) ?? {}) as Record<string, unknown>
    addFavState.value = s.isFav === true
    if (addTarget.value) addTarget.value.fav = s.isFav === true
    addGroups.value = (Array.isArray(s.groups) ? (s.groups as Record<string, unknown>[]) : []).map((g) => ({
      id: String(g.id ?? ''),
      name: String(g.name ?? ''),
      count: typeof g.count === 'number' ? g.count : 0,
      member: g.member === true,
    }))
  } catch (e) {
    console.error('market.groupInfo 失败', e)
  }
}

async function toggleFavorite(): Promise<void> {
  const row = addTarget.value
  if (!row) return
  const target = !addFavState.value
  try {
    await klineBus.request('market', 'setFavorite', { file: row.file, fav: target })
    addFavState.value = target
    row.fav = target
    showToast({ message: target ? '已加自选' : '已取消自选', duration: 1200 })
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

async function toggleGroup(g: GroupInfo): Promise<void> {
  const row = addTarget.value
  if (!row) return
  const member = !g.member
  try {
    await klineBus.request('market', 'setInGroup', { file: row.file, groupID: g.id, member })
    g.member = member
    g.count += member ? 1 : -1
    await pullGroupInfo(row.file)
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

async function createGroup(): Promise<void> {
  const name = newGroupName.value.trim()
  if (!name || !addTarget.value) return
  try {
    await klineBus.request('market', 'createGroup', { name })
    newGroupName.value = ''
    await pullGroupInfo(addTarget.value.file)
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

// ===== 生命周期 =====
onMounted(async () => {
  const t = await klineBus.detect()
  bridgeOk.value = t !== 'none'
  if (!bridgeOk.value) return

  // native 模式：数据变化事件触发回读（pc 模式由刷新后的定时回读兜底）
  klineBus.on('market.changed', () => void pullSnapshot())

  await pullSnapshot()
  // 主库未就绪（冷启动竞态）：3s 后重试一次
  if (!loaded.value) {
    setTimeout(() => void pullSnapshot(), 3000)
  } else {
    await nextTick()
    resetScrollWindow()
  }
})
</script>

<style scoped>
.page {
  min-height: 100%;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
}

.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 6px 12px 8px;
  flex-shrink: 0;
}

.card-warn {
  margin: 0 12px 10px;
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px 16px;
  font-size: 13px;
  color: #b25000;
}

/* ===== 顶部 header（对齐 MarketHeaderBar 布局） ===== */
.header {
  display: flex;
  align-items: center;
  padding: 4px 12px;
  flex-shrink: 0;
}

.hbtn {
  width: 32px;
  height: 32px;
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 18px;
  padding: 0;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
}

.hbtn.fx {
  font-size: 14px;
  font-weight: 700;
}

.menu {
  flex: 1;
  display: flex;
  justify-content: center;
  gap: 22px;
}

.menu-item {
  display: flex;
  align-items: center;
  gap: 2px;
  font-size: 18px;
  color: var(--k-text);
  padding: 6px 0;
  cursor: pointer;
}

.menu-item.active {
  color: #ee0a24;
  font-weight: 700;
}

.menu-chev {
  font-size: 12px;
}

.right-btns {
  display: flex;
  gap: 4px;
}

/* ===== 二级分类 chips ===== */
.seconds {
  display: flex;
  gap: 8px;
  padding: 0 12px 10px;
  overflow-x: auto;
  white-space: nowrap;
  flex-shrink: 0;
}

.chip {
  flex-shrink: 0;
  padding: 6px 14px;
  border-radius: 15px;
  font-size: 13px;
  color: var(--k-text-secondary);
  background: var(--k-bg-secondary);
  cursor: pointer;
}

.chip.active {
  color: #ffffff;
  background: var(--k-accent);
}

.chip-count {
  margin-left: 4px;
  font-size: 11px;
  opacity: 0.85;
}

/* ===== 表格（虚拟滚动 + 冻结列） ===== */
.table-scroll {
  overflow: auto;
  -webkit-overflow-scrolling: touch;
}

.table-inner {
  position: relative;
}

.thead {
  position: sticky;
  top: 0;
  z-index: 5;
  display: flex;
  background: var(--k-bg);
  height: 38px;
}

.th {
  display: flex;
  align-items: center;
  gap: 2px;
  font-size: 15px;
  font-weight: 500;
  color: var(--k-text-secondary);
  padding: 0 6px;
  white-space: nowrap;
  overflow: hidden;
  cursor: pointer;
  flex-shrink: 0;
}

.th-title {
  overflow: hidden;
  text-overflow: ellipsis;
}

.sort-icon {
  font-size: 11px;
  color: var(--k-accent);
}

.th-frozen,
.td-frozen {
  position: sticky;
  left: 0;
  z-index: 2;
  background: var(--k-bg);
}

.th-frozen {
  z-index: 6;
}

.trow {
  display: flex;
  height: 45px;
  cursor: pointer;
}

.trow.pinned {
  background: var(--k-bg-secondary);
}

.trow.pinned .th-frozen,
.trow.pinned .td-frozen {
  background: var(--k-bg-secondary);
}

.td {
  display: flex;
  align-items: center;
  font-size: 15px;
  color: var(--k-text);
  padding: 0 6px;
  white-space: nowrap;
  overflow: hidden;
  flex-shrink: 0;
  font-variant-numeric: tabular-nums;
}

.right {
  justify-content: flex-end;
}

.name-cell {
  width: 100%;
  display: flex;
  flex-direction: column;
  gap: 1px;
}

.name-line {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.row-name {
  font-size: 15px;
  font-weight: 500;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.row-add {
  width: 22px;
  height: 22px;
  flex-shrink: 0;
  border: 1px solid var(--k-accent);
  border-radius: 11px;
  background: none;
  color: var(--k-accent);
  font-size: 14px;
  line-height: 20px;
  padding: 0;
  cursor: pointer;
}

.row-add.faved {
  color: #00b578;
  border-color: #00b578;
}

.row-code {
  font-size: 11px;
  color: var(--k-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.up {
  color: #ff4d4f;
}

.down {
  color: #00b578;
}

.empty {
  text-align: center;
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 40px 0;
}

.empty-inline {
  text-align: center;
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 24px 0;
}

/* ===== 列配置面板 ===== */
.cfg-panel {
  display: flex;
  flex-direction: column;
  height: 100%;
  background: var(--k-bg);
}

.cfg-header {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--k-border);
  flex-shrink: 0;
}

.cfg-title {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
}

.cfg-btn {
  border: none;
  background: none;
  font-size: 15px;
  padding: 4px 2px;
  cursor: pointer;
}

.cfg-btn.muted {
  color: var(--k-text-secondary);
}

.cfg-btn.warn {
  color: #ff976a;
}

.cfg-btn.primary {
  color: var(--k-accent);
  font-weight: 700;
}

.cfg-body {
  flex: 1;
  overflow-y: auto;
  padding: 4px 16px 24px;
}

.cfg-section-title {
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 16px 0 6px;
}

.cfg-row {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 40px;
  font-size: 15px;
  color: var(--k-text);
}

.cfg-row.fixed-row {
  color: var(--k-text-secondary);
}

.cfg-note {
  font-size: 12px;
  color: var(--k-text-secondary);
}

.cfg-field {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.filter-btn {
  flex-shrink: 0;
  border: none;
  background: none;
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 4px 6px;
  cursor: pointer;
}

.filter-btn.on {
  color: #1989fa;
}

.move-btns {
  display: flex;
  gap: 2px;
  flex-shrink: 0;
}

.mv {
  width: 26px;
  height: 26px;
  border: none;
  border-radius: 6px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 13px;
  padding: 0;
  cursor: pointer;
}

.mv:disabled {
  opacity: 0.3;
}

.cfg-foot-note {
  font-size: 12px;
  color: var(--k-text-secondary);
  line-height: 1.7;
  padding-top: 14px;
}

/* ===== 筛选多选浮层 ===== */
.filter-panel {
  padding: 14px 0 0;
}

.filter-title {
  text-align: center;
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
  padding-bottom: 6px;
}

.filter-list {
  max-height: 320px;
  overflow-y: auto;
}

.filter-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 11px 16px;
  font-size: 15px;
  color: var(--k-text);
  border-top: 1px solid var(--k-border);
  cursor: pointer;
}

.check {
  color: #1989fa;
}

.filter-done {
  width: 100%;
  border: none;
  border-top: 1px solid var(--k-border);
  background: none;
  color: var(--k-accent);
  font-size: 15px;
  font-weight: 600;
  padding: 12px 0;
  cursor: pointer;
}

/* ===== 加自选浮层 ===== */
.add-panel {
  padding: 12px 0 24px;
  background: var(--k-bg);
}

.add-header {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 4px 16px 10px;
  border-bottom: 1px solid var(--k-border);
}

.add-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 16px;
  border-bottom: 1px solid var(--k-border);
}

.add-name {
  font-size: 16px;
  font-weight: 500;
  color: var(--k-text);
}

.fav-toggle {
  border: none;
  border-radius: 8px;
  background: var(--k-bg-secondary);
  color: var(--k-text-secondary);
  font-size: 13px;
  font-weight: 500;
  padding: 7px 12px;
  cursor: pointer;
}

.fav-toggle.faved {
  color: #ffb300;
}

.add-new-group {
  width: calc(100% - 32px);
  margin: 10px 16px;
  border: none;
  border-radius: 10px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 13px;
  text-align: left;
  padding: 11px 12px;
  cursor: pointer;
}

.add-new-group .plus {
  color: #07c160;
  font-weight: 700;
  margin-right: 4px;
}

.add-list {
  max-height: 46vh;
  overflow-y: auto;
}

.add-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 16px;
  cursor: pointer;
}

.add-group-name {
  font-size: 15px;
  color: var(--k-text);
}

.member-icon {
  font-size: 20px;
  color: var(--k-text-tertiary);
}

.member-icon.on {
  color: #07c160;
}
</style>
