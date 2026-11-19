<template>
  <div class="page">
    <div class="banner">模拟交易 · Web 版（P2-4）</div>

    <div v-if="!bridgeOk" class="card-warn">桥接不可达：显示占位界面</div>

    <!-- 账户横滑 chips（对齐账户侧栏：「全部账户汇总」 + activeAccounts） -->
    <div class="accounts">
      <button
        class="account-chip"
        :class="{ active: selectedID === null }"
        @click="selectAccount(null)"
      >
        <span class="acc-badge" style="--badge: #8e8e93">全</span>
        <span class="acc-name">全部账户汇总</span>
      </button>
      <button
        v-for="a in accounts"
        :key="a.id"
        class="account-chip"
        :class="{ active: a.id === selectedID }"
        @click="selectAccount(a.id)"
      >
        <span class="acc-badge" :style="{ '--badge': a.colorHex }">{{ a.badge }}</span>
        <span class="acc-name">{{ a.name }}</span>
      </button>
      <button class="acc-add" @click="openCreateAccount">＋ 新建账户</button>
    </div>

    <!-- 工具栏：条件单 / 策略公式 / 训练记录 / 资金管理 / 交易规则 / 刷新 -->
    <div class="toolbar">
      <button class="tool-btn" @click="act('openCondManage')">条件单</button>
      <button class="tool-btn" @click="act('openStrategyFormulas')">策略公式</button>
      <button class="tool-btn" @click="act('openTrainingRecords')">训练记录</button>
      <button class="tool-btn" @click="walletOpen = true">资金管理</button>
      <button class="tool-btn" @click="rulesOpen = true">交易规则</button>
      <button class="tool-btn" @click="act('refreshQuotes')">刷新行情</button>
    </div>

    <!-- 资产摘要带（对齐 SimSummaryBand：六指标 + 近30日净值） -->
    <div class="summary">
      <div class="sum-row big">
        <span class="sum-label">总资产</span>
        <span class="sum-value big">{{ fmtAmount(summary.totalAssets) }}</span>
      </div>
      <div class="sum-grid">
        <div class="sum-row"><span class="sum-label">可用资金</span><span class="sum-value">{{ fmtAmount(summary.cash) }}</span></div>
        <div class="sum-row"><span class="sum-label">持仓市值</span><span class="sum-value">{{ fmtAmount(summary.marketValue) }}</span></div>
        <div class="sum-row"><span class="sum-label">持仓占比</span><span class="sum-value">{{ fmtPctRaw(summary.positionPct * 100) }}</span></div>
        <div class="sum-row"><span class="sum-label">当日盈亏</span><span class="sum-value" :class="profitClass(summary.dayProfit)">{{ fmtSigned0(summary.dayProfit) }}</span></div>
        <div class="sum-row"><span class="sum-label">累计盈亏</span><span class="sum-value" :class="profitClass(summary.totalProfit)">{{ fmtSigned0(summary.totalProfit) }}</span></div>
        <div class="sum-row net"><span class="sum-label">近 30 日净值</span>
          <svg v-if="netValue.length > 1" class="netspark" viewBox="0 0 172 30" preserveAspectRatio="none">
            <polyline :points="netPoints(netValue)" stroke="#ff4d4f" fill="none" stroke-width="1.5" />
          </svg>
        </div>
      </div>
    </div>

    <!-- 模块分段 + 搜索 + 导出 -->
    <div class="module-bar">
      <div class="module-tabs">
        <button
          v-for="m in modules"
          :key="m.key"
          class="module-tab"
          :class="{ active: module === m.key }"
          @click="selectModule(m.key)"
        >{{ m.title }}</button>
      </div>
      <div class="module-tools">
        <van-search
          v-model="keyword"
          class="kw-search"
          placeholder="搜索"
          shape="round"
          @update:model-value="() => {}"
        />
        <button v-if="module === 'log'" class="tool-btn" @click="exportLogs">导出 CSV</button>
      </div>
    </div>
    <div v-if="module === 'log'" class="log-filter">
      <button
        v-for="opt in logFilterOptions"
        :key="opt.key"
        class="log-chip"
        :class="{ active: logModule === opt.key }"
        @click="logModule = opt.key"
      >{{ opt.title }}</button>
    </div>

    <!-- 业务表（横向滚动 + 吸顶表头） -->
    <div class="table-scroll">
      <div class="table-inner" :style="{ minWidth: tableMinWidth + 'px' }">
        <div class="thead">
          <div
            v-for="col in columns"
            :key="col.title"
            class="th"
            :class="{ right: col.align === 'right' }"
            :style="{ width: col.width + 'px' }"
          >{{ col.title }}</div>
        </div>
        <div v-if="rows.length === 0" class="empty">{{ emptyText }}</div>
        <div v-for="(row, i) in rows" :key="String(row.id ?? i)" class="trow">
          <template v-if="module === 'position'">
            <div class="td name"><div class="q-name">{{ row.name }}</div><div class="q-code">{{ row.code }}</div></div>
            <div class="td right">{{ fmtShares(row.qty) }}</div>
            <div class="td right" :class="{ muted: row.availableQty <= 0 }">{{ fmtShares(row.availableQty) }}</div>
            <div class="td right">{{ fmtPrice(row.costPrice) }}</div>
            <div class="td right">{{ fmtPrice(row.lastPrice) }}</div>
            <div class="td right">{{ fmtAmount(row.marketValue) }}</div>
            <div class="td right profit" :class="profitClass(row.profit)">{{ fmtSigned0(row.profit) }}</div>
            <div class="td right profit" :class="profitClass(row.profit)">{{ fmtPctRaw(row.profitPct * 100) }}</div>
            <div class="td right actions">
              <button class="inline-btn buy" @click="openTicket('buy', row.id)">买</button>
              <button class="inline-btn sell" @click="openTicket('sell', row.id)">卖</button>
              <button class="inline-btn cond" @click="openCondEditor(row.id)">条件单</button>
            </div>
          </template>
          <template v-else-if="module === 'order'">
            <div class="td muted">{{ row.time }}</div>
            <div class="td name"><div class="q-name">{{ row.name }}</div><div class="q-code">{{ row.code }}</div></div>
            <div class="td"><span class="dir-tag" :class="row.direction === 'buy' ? 'tag-buy' : 'tag-sell'">{{ row.direction === 'buy' ? '买入' : '卖出' }}</span></div>
            <div class="td">{{ row.priceType === 'limit' ? '限价' : '市价' }}</div>
            <div class="td right">{{ row.price === null ? '市价' : fmtPrice(row.price) }}</div>
            <div class="td right">{{ fmtShares(row.qty) }}</div>
            <div class="td right">{{ fmtShares(row.filledQty) }}</div>
            <div class="td"><span class="status-tag" :class="statusClass(row.status)">{{ statusText(row.status) }}</span></div>
            <div class="td right actions">
              <button v-if="row.active && row.priceType === 'limit'" class="inline-btn cond" @click="openAmend(row as OrderRow)">改价</button>
              <button v-if="row.active" class="inline-btn cancel" @click="cancelOrder(row as OrderRow)">撤单</button>
              <span v-if="!(row.active && row.priceType === 'limit') && !row.active" class="muted">—</span>
            </div>
          </template>
          <template v-else-if="module === 'fill'">
            <div class="td muted">{{ row.time }}</div>
            <div class="td name"><div class="q-name">{{ row.name }}</div><div class="q-code">{{ row.code }}</div></div>
            <div class="td"><span class="dir-tag" :class="row.direction === 'buy' ? 'tag-buy' : 'tag-sell'">{{ row.direction === 'buy' ? '买入' : '卖出' }}</span></div>
            <div class="td right">{{ fmtPrice(row.price) }}</div>
            <div class="td right">{{ fmtShares(row.qty) }}</div>
            <div class="td right">{{ fmtAmount(row.amount) }}</div>
            <div class="td right">{{ fmtPrice(row.fee) }}</div>
            <div class="td muted">{{ row.contract }}</div>
          </template>
          <template v-else-if="module === 'cash'">
            <div class="td muted">{{ row.time }}</div>
            <div class="td">{{ row.kind }}</div>
            <div class="td">{{ row.note }}</div>
            <div class="td right profit" :class="profitClass(row.amount)">{{ fmtSigned0(row.amount) }}</div>
            <div class="td right">{{ fmtAmount(row.balance) }}</div>
            <div class="td muted">{{ row.accountName }}</div>
          </template>
          <template v-else>
            <div class="td muted">{{ row.time }}</div>
            <div class="td muted">{{ row.accountName }}</div>
            <div class="td">{{ row.module }}</div>
            <div class="td">{{ row.content }}</div>
            <div class="td" :class="resultClass(row.result)">{{ row.result }}</div>
          </template>
        </div>
      </div>
    </div>

    <!-- 底部买卖条（对齐 SimBottomActionBar） -->
    <div class="bottom-bar">
      <button class="trade-btn buy" @click="openTicket('buy', null)">买 入</button>
      <button class="tool-btn" @click="act('refreshQuotes')">刷新</button>
      <button class="trade-btn sell" @click="openTicket('sell', null)">卖 出</button>
    </div>

    <!-- 新建账户对话框 -->
    <van-dialog
      v-model:show="createOpen"
      title="新建账户"
      show-cancel-button
      @confirm="confirmCreateAccount"
    >
      <div class="dialog-body">
        <van-field v-model="newAccountName" label="账户名称" placeholder="如：主策略账户" maxlength="20" />
        <van-field v-model="newAccountCapital" label="初始资金" type="number" placeholder="100000" />
        <div class="dialog-note">初始资金默认 100000 元，创建后自动选中该账户。</div>
      </div>
    </van-dialog>

    <!-- 改价对话框 -->
    <van-dialog
      v-model:show="amendOpen"
      :title="amendTarget ? `修改委托价 · ${amendTarget.name}` : '修改委托价'"
      show-cancel-button
      @confirm="confirmAmend"
    >
      <div class="dialog-body">
        <van-field v-model="amendPriceText" label="委托价" type="number" placeholder="委托价" />
        <div class="dialog-note" v-if="amendTarget">
          {{ amendTarget.name }} {{ amendTarget.code }} · 当前 {{ amendTarget.price === null ? '市价' : fmtPrice(amendTarget.price) }}
        </div>
      </div>
    </van-dialog>

    <!-- 资金管理弹窗（对齐原生 walletMessage 文案） -->
    <van-dialog v-model:show="walletOpen" title="资金管理" :show-cancel-button="false">
      <div class="wallet-body">
        {{ accountName }}<br />
        总资产 {{ fmtAmount(summary.totalAssets) }} 元<br />
        可用资金 {{ fmtAmount(summary.cash) }} 元<br />
        持仓市值 {{ fmtAmount(summary.marketValue) }} 元<br />
        持仓占比 {{ fmtPctRaw(summary.positionPct * 100) }}<br />
        当日盈亏 {{ fmtSigned0(summary.dayProfit) }} 元<br />
        累计盈亏 {{ fmtSigned0(summary.totalProfit) }} 元
      </div>
    </van-dialog>

    <!-- 交易规则弹窗（对齐原生 rulesText 逐字） -->
    <van-dialog v-model:show="rulesOpen" title="交易规则" :show-cancel-button="false">
      <div class="wallet-body">T+1：当日买入次日可卖<br />佣金万 2.5，最低 5 元<br />卖出印花税千一<br />涨跌停 ±10%<br />盘后委托转为待报</div>
    </van-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { showFailToast, showToast } from 'vant'

// ===== 协议形状（web/src/types/protocol.ts 对拍） =====
interface AccountSnap {
  id: string
  name: string
  badge: string
  colorHex: string
}

interface SummarySnap {
  totalAssets: number
  cash: number
  marketValue: number
  positionPct: number
  dayProfit: number
  dayProfitPct: number
  totalProfit: number
  totalProfitPct: number
}

interface PositionRow {
  id: string
  code: string
  name: string
  qty: number
  availableQty: number
  costPrice: number
  lastPrice: number
  marketValue: number
  profit: number
  profitPct: number
}

interface OrderRow {
  id: string
  time: string
  code: string
  name: string
  direction: 'buy' | 'sell'
  priceType: 'limit' | 'market'
  price: number | null
  qty: number
  filledQty: number
  status: 'pending' | 'reported' | 'partial' | 'filled' | 'cancelled'
  active: boolean
}

interface FillRow {
  id: string
  time: string
  code: string
  name: string
  direction: 'buy' | 'sell'
  price: number
  qty: number
  amount: number
  fee: number
  contract: string
}

interface LedgerRow {
  id: string
  time: string
  kind: string
  note: string
  amount: number
  balance: number
  accountName: string
}

interface LogRow {
  id: string
  time: string
  accountName: string
  module: string
  content: string
  result: string
}

/** 业务表行（五模块字段各异，模板按 module 分支访问；宽松类型避免联合类型收窄噪音） */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyRow = Record<string, any>

// ===== 页面状态 =====
const bridgeOk = ref(false)
const selectedID = ref<string | null>(null)
const accountName = ref('全部账户汇总')
const accounts = ref<AccountSnap[]>([])
const summary = ref<SummarySnap>({
  totalAssets: 0, cash: 0, marketValue: 0, positionPct: 0,
  dayProfit: 0, dayProfitPct: 0, totalProfit: 0, totalProfitPct: 0,
})
const netValue = ref<number[]>([])
const module = ref('position')
const positions = ref<PositionRow[]>([])
const orders = ref<OrderRow[]>([])
const fills = ref<FillRow[]>([])
const ledger = ref<LedgerRow[]>([])
const logs = ref<LogRow[]>([])

/** 本地 UI 过滤（不进协议）：关键词 + 日志模块筛选 */
const keyword = ref('')
const logModule = ref<string | null>(null)

const modules = [
  { key: 'position', title: '持仓' },
  { key: 'order', title: '当日委托' },
  { key: 'fill', title: '当日成交' },
  { key: 'cash', title: '资金流水' },
  { key: 'log', title: '操作日志' },
]

const logFilterOptions = [
  { key: '', title: '全部' },
  { key: 'order', title: '委托' },
  { key: 'fill', title: '成交' },
  { key: 'cancel', title: '撤单' },
  { key: 'amend', title: '改价' },
  { key: 'cash', title: '资金' },
  { key: 'account', title: '账户' },
  { key: 'alert', title: '提醒' },
  { key: 'condition', title: '条件单' },
]

// ===== 列定义（对齐原生 SimModuleTable 列头；minWidth 取紧凑口径） =====
interface Column {
  title: string
  width: number
  align?: string
}

const columnSets: Record<string, Column[]> = {
  position: [
    { title: '名称/代码', width: 110 }, { title: '持仓', width: 62, align: 'right' },
    { title: '可用', width: 62, align: 'right' }, { title: '成本价', width: 74, align: 'right' },
    { title: '现价', width: 74, align: 'right' }, { title: '持仓市值', width: 82, align: 'right' },
    { title: '盈亏', width: 74, align: 'right' }, { title: '盈亏%', width: 68, align: 'right' },
    { title: '操作', width: 128, align: 'right' },
  ],
  order: [
    { title: '时间', width: 60 }, { title: '名称', width: 100 },
    { title: '方向', width: 46 }, { title: '类型', width: 46 },
    { title: '委托价', width: 74, align: 'right' }, { title: '委托量', width: 62, align: 'right' },
    { title: '已成', width: 62, align: 'right' }, { title: '状态', width: 60 },
    { title: '操作', width: 100, align: 'right' },
  ],
  fill: [
    { title: '成交时间', width: 60 }, { title: '名称', width: 100 },
    { title: '方向', width: 46 }, { title: '成交价', width: 74, align: 'right' },
    { title: '成交量', width: 62, align: 'right' }, { title: '成交额', width: 82, align: 'right' },
    { title: '费用', width: 62, align: 'right' }, { title: '合同编号', width: 96 },
  ],
  cash: [
    { title: '时间', width: 88 }, { title: '类型', width: 62 },
    { title: '说明', width: 130 }, { title: '发生额', width: 82, align: 'right' },
    { title: '账户余额', width: 88, align: 'right' }, { title: '账户', width: 90 },
  ],
  log: [
    { title: '时间', width: 88 }, { title: '账户', width: 90 },
    { title: '模块', width: 56 }, { title: '操作内容', width: 200 },
    { title: '结果', width: 72 },
  ],
}

const columns = computed(() => columnSets[module.value] ?? [])

const tableMinWidth = computed(() =>
  (columnSets[module.value] ?? []).reduce((sum, c) => sum + c.width, 0) + 24,
)

// ===== 行过滤（本地，对齐原生 keyword 口径：标的按 code/name，日志按内容） =====
const filtered = computed<AnyRow[]>(() => {
  const key = keyword.value.trim().toLowerCase()
  const match = (text: string): boolean => !key || text.toLowerCase().includes(key)
  switch (module.value) {
    case 'position':
      return positions.value.filter((p) => match(p.code) || match(p.name)) as unknown as AnyRow[]
    case 'order':
      return orders.value.filter((o) => match(o.code) || match(o.name)) as unknown as AnyRow[]
    case 'fill':
      return fills.value.filter((f) => match(f.code) || match(f.name)) as unknown as AnyRow[]
    case 'cash':
      return ledger.value.filter((e) => match(e.note)) as unknown as AnyRow[]
    case 'log':
      return logs.value
        .filter((l) => !logModule.value || l.module === logFilterOptions.find((o) => o.key === logModule.value)?.title)
        .filter((l) => match(l.content)) as unknown as AnyRow[]
    default:
      return []
  }
})

const rows = computed<AnyRow[]>(() => filtered.value)

// ===== 弹窗（资金管理 / 交易规则，文案逐字对齐原生） =====
const walletOpen = ref(false)
const rulesOpen = ref(false)

const emptyText = computed(() => {
  if (keyword.value.trim() || logModule.value) return '无匹配结果'
  switch (module.value) {
    case 'position': return '暂无持仓'
    case 'order': return '今日暂无委托'
    case 'fill': return '今日暂无成交'
    case 'cash': return '暂无资金流水'
    case 'log': return '暂无操作日志'
    default: return '暂无数据'
  }
})

// ===== 格式化（对齐 SimFormat：千分位整数 / 两位小数千分位价格） =====
function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function fmtPrice(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtShares(v: number): string {
  return v.toLocaleString('en-US')
}

function fmtSigned0(v: number): string {
  return `${v > 0 ? '+' : ''}${Math.round(v).toLocaleString('en-US')}`
}

function fmtPctRaw(v: number): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}%`
}

function profitClass(v: number): string {
  return v < 0 ? 'down' : 'up'
}

/** 结果配色（对齐原生 simResultColor：成功绿 / 在途橙 / 其余灰） */
function resultClass(text: string): string {
  if (['成功', '已成交', '全部成交'].some((k) => text.includes(k))) return 'result-ok'
  if (['部成', '已报', '待报'].some((k) => text.includes(k))) return 'result-pending'
  return 'result-muted'
}

function statusText(status: OrderRow['status']): string {
  const map: Record<string, string> = {
    pending: '待报', reported: '已报', partial: '部成', filled: '已成交', cancelled: '已撤',
  }
  return map[status] ?? status
}

function statusClass(status: OrderRow['status']): string {
  switch (status) {
    case 'reported': return 'st-reported'
    case 'partial': return 'st-partial'
    default: return 'st-muted'
  }
}

/** 净值折线点集（172×30 viewBox，对齐 SimSparkline 尺寸） */
function netPoints(values: number[]): string {
  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1
  const step = 172 / (values.length - 1)
  return values
    .map((v, i) => `${(i * step).toFixed(1)},${(28 - ((v - min) / range) * 24).toFixed(1)}`)
    .join(' ')
}

// ===== 快照回读 =====
async function pullSnapshot(): Promise<void> {
  try {
    const s = ((await klineBus.request('sim', 'snapshot')) ?? {}) as Record<string, unknown>
    selectedID.value = typeof s.selectedID === 'string' ? s.selectedID : null
    accountName.value = String(s.accountName ?? '全部账户汇总')
    accounts.value = (Array.isArray(s.accounts) ? (s.accounts as Record<string, unknown>[]) : []).map((a) => ({
      id: String(a.id ?? ''),
      name: String(a.name ?? ''),
      badge: String(a.badge ?? '?'),
      colorHex: String(a.colorHex ?? '#1E5FA8'),
    }))
    const raw = s.summary as Record<string, unknown> | undefined
    if (raw) {
      summary.value = {
        totalAssets: typeof raw.totalAssets === 'number' ? raw.totalAssets : 0,
        cash: typeof raw.cash === 'number' ? raw.cash : 0,
        marketValue: typeof raw.marketValue === 'number' ? raw.marketValue : 0,
        positionPct: typeof raw.positionPct === 'number' ? raw.positionPct : 0,
        dayProfit: typeof raw.dayProfit === 'number' ? raw.dayProfit : 0,
        dayProfitPct: typeof raw.dayProfitPct === 'number' ? raw.dayProfitPct : 0,
        totalProfit: typeof raw.totalProfit === 'number' ? raw.totalProfit : 0,
        totalProfitPct: typeof raw.totalProfitPct === 'number' ? raw.totalProfitPct : 0,
      }
    }
    netValue.value = Array.isArray(s.netValue) ? (s.netValue as number[]) : []
    module.value = typeof s.module === 'string' ? s.module : 'position'
    const num = (v: unknown): number => (typeof v === 'number' ? v : 0)
    positions.value = (Array.isArray(s.positions) ? (s.positions as Record<string, unknown>[]) : []).map((p) => ({
      id: String(p.id ?? ''), code: String(p.code ?? ''), name: String(p.name ?? ''),
      qty: num(p.qty), availableQty: num(p.availableQty), costPrice: num(p.costPrice),
      lastPrice: num(p.lastPrice), marketValue: num(p.marketValue),
      profit: num(p.profit), profitPct: num(p.profitPct),
    }))
    orders.value = (Array.isArray(s.orders) ? (s.orders as Record<string, unknown>[]) : []).map((o) => ({
      id: String(o.id ?? ''), time: String(o.time ?? ''), code: String(o.code ?? ''), name: String(o.name ?? ''),
      direction: o.direction === 'sell' ? 'sell' : 'buy',
      priceType: o.priceType === 'market' ? 'market' : 'limit',
      price: typeof o.price === 'number' ? o.price : null,
      qty: num(o.qty), filledQty: num(o.filledQty),
      status: (['pending', 'reported', 'partial', 'filled', 'cancelled'].includes(String(o.status))
        ? String(o.status) : 'pending') as OrderRow['status'],
      active: o.active === true,
    }))
    fills.value = (Array.isArray(s.fills) ? (s.fills as Record<string, unknown>[]) : []).map((f) => ({
      id: String(f.id ?? ''), time: String(f.time ?? ''), code: String(f.code ?? ''), name: String(f.name ?? ''),
      direction: f.direction === 'sell' ? 'sell' : 'buy',
      price: num(f.price), qty: num(f.qty), amount: num(f.amount), fee: num(f.fee),
      contract: String(f.contract ?? ''),
    }))
    ledger.value = (Array.isArray(s.ledger) ? (s.ledger as Record<string, unknown>[]) : []).map((e) => ({
      id: String(e.id ?? ''), time: String(e.time ?? ''), kind: String(e.kind ?? ''), note: String(e.note ?? ''),
      amount: num(e.amount), balance: num(e.balance), accountName: String(e.accountName ?? ''),
    }))
    logs.value = (Array.isArray(s.logs) ? (s.logs as Record<string, unknown>[]) : []).map((l) => ({
      id: String(l.id ?? ''), time: String(l.time ?? ''), accountName: String(l.accountName ?? ''),
      module: String(l.module ?? ''), content: String(l.content ?? ''), result: String(l.result ?? ''),
    }))
  } catch (e) {
    console.error('sim.snapshot 失败', e)
  }
}

// ===== 动作 =====
async function selectAccount(id: string | null): Promise<void> {
  try {
    await klineBus.request('sim', 'selectAccount', { accountID: id })
    await pullSnapshot()
  } catch (e) {
    console.error(e)
  }
}

async function selectModule(key: string): Promise<void> {
  module.value = key
  try {
    await klineBus.request('sim', 'selectModule', { module: key })
  } catch (e) {
    console.error(e)
  }
}

async function act(action: string): Promise<void> {
  try {
    const data = await klineBus.request('sim', action, {})
    const toast = typeof data?.toast === 'string' ? data.toast : null
    if (toast) showToast({ message: toast, duration: 2000 })
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

async function openTicket(direction: 'buy' | 'sell', positionID: string | null): Promise<void> {
  try {
    const payload: Record<string, unknown> = { direction }
    if (positionID) payload.positionID = positionID
    await klineBus.request('sim', 'openTicket', payload)
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

async function openCondEditor(positionID: string): Promise<void> {
  try {
    await klineBus.request('sim', 'openCondEditor', { positionID })
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

async function cancelOrder(order: OrderRow): Promise<void> {
  try {
    await klineBus.request('sim', 'cancelOrder', { orderID: order.id })
    showToast({ message: '撤单请求已提交', duration: 1600 })
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

// ===== 新建账户（Vant Dialog） =====
const createOpen = ref(false)
const newAccountName = ref('')
const newAccountCapital = ref('100000')

function openCreateAccount(): void {
  newAccountName.value = ''
  newAccountCapital.value = '100000'
  createOpen.value = true
}

async function confirmCreateAccount(): Promise<void> {
  const capital = Number(newAccountCapital.value) || 100000
  try {
    const data = await klineBus.request('sim', 'createAccount',
      { name: newAccountName.value.trim(), capital })
    showToast({ message: typeof data?.toast === 'string' ? data.toast : '已创建账户', duration: 2000 })
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

// ===== 改价（Vant Dialog） =====
const amendOpen = ref(false)
const amendTarget = ref<OrderRow | null>(null)
const amendPriceText = ref('')

function openAmend(order: OrderRow): void {
  amendTarget.value = order
  amendPriceText.value = order.price === null ? '' : String(order.price)
  amendOpen.value = true
}

async function confirmAmend(): Promise<void> {
  const order = amendTarget.value
  if (!order) return
  const price = Number(amendPriceText.value)
  if (!(price > 0)) {
    showFailToast({ message: '请输入有效的委托价', duration: 1600 })
    return
  }
  try {
    const data = await klineBus.request('sim', 'amendPrice', { orderID: order.id, price })
    showToast({ message: typeof data?.toast === 'string' ? data.toast : '已改价', duration: 2000 })
    amendTarget.value = null
    await pullSnapshot()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

// ===== 日志导出 =====
async function exportLogs(): Promise<void> {
  try {
    const data = await klineBus.request('sim', 'exportLogs', {
      keyword: keyword.value.trim(),
      logModule: logModule.value || undefined,
    })
    showToast({ message: typeof data?.toast === 'string' ? data.toast : '已导出', duration: 2400 })
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

onMounted(async () => {
  const t = await klineBus.detect()
  bridgeOk.value = t !== 'none'
  if (!bridgeOk.value) return

  // native 模式：数据变化事件触发回读（下单/成交/改价/行情快照均经 sim.changed 推送）
  klineBus.on('sim.changed', () => void pullSnapshot())

  await pullSnapshot()
})
</script>

<style scoped>
.page {
  min-height: 100%;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  padding-bottom: 8px;
}

.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 6px 12px 0;
}

.card-warn {
  margin: 8px 12px 0;
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px 16px;
  font-size: 13px;
  color: #b25000;
}

/* ===== 账户 chips ===== */
.accounts {
  display: flex;
  gap: 8px;
  padding: 8px 12px;
  overflow-x: auto;
  white-space: nowrap;
  scrollbar-width: none;
  flex-shrink: 0;
}

.accounts::-webkit-scrollbar {
  display: none;
}

.account-chip {
  flex-shrink: 0;
  display: flex;
  align-items: center;
  gap: 6px;
  border: 1px solid var(--k-border);
  border-radius: 16px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 13px;
  padding: 6px 12px;
  cursor: pointer;
}

.account-chip.active {
  border-color: var(--k-accent);
  color: var(--k-accent);
  font-weight: 600;
}

.acc-badge {
  width: 20px;
  height: 20px;
  border-radius: 6px;
  background: var(--badge, #1e5fa8);
  color: #ffffff;
  font-size: 11px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}

.acc-name {
  max-width: 120px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.acc-add {
  flex-shrink: 0;
  border: 1px dashed var(--k-border);
  border-radius: 16px;
  background: none;
  color: var(--k-accent);
  font-size: 13px;
  padding: 6px 12px;
  cursor: pointer;
}

/* ===== 工具栏 ===== */
.toolbar {
  display: flex;
  gap: 8px;
  padding: 0 12px 8px;
  overflow-x: auto;
  flex-shrink: 0;
}

.tool-btn {
  flex-shrink: 0;
  border: none;
  border-radius: 8px;
  background: var(--k-bg-secondary);
  color: var(--k-accent);
  font-size: 12.5px;
  font-weight: 500;
  padding: 7px 12px;
  cursor: pointer;
}

/* ===== 资产摘要带 ===== */
.summary {
  padding: 6px 12px 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.sum-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-height: 26px;
  padding: 0 4px;
}

.sum-row.big {
  min-height: 30px;
}

.sum-label {
  font-size: 11px;
  color: var(--k-text-secondary);
}

.sum-value {
  font-size: 14px;
  font-weight: 700;
  color: var(--k-text);
  font-variant-numeric: tabular-nums;
}

.sum-value.big {
  font-size: 16px;
}

.sum-grid {
  display: grid;
  grid-template-columns: 1fr;
  gap: 0;
}

@media (min-width: 600px) {
  .sum-grid {
    grid-template-columns: repeat(3, 1fr);
  }
}

.sum-row.net svg {
  flex-shrink: 0;
}

.netspark {
  width: 172px;
  height: 30px;
}

/* ===== 模块分段 ===== */
.module-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px 4px;
  flex-shrink: 0;
}

.module-tabs {
  display: flex;
  gap: 2px;
  background: var(--k-bg-secondary);
  border-radius: 8px;
  padding: 2px;
  overflow-x: auto;
}

.module-tab {
  flex-shrink: 0;
  border: none;
  border-radius: 6px;
  background: none;
  color: var(--k-text-secondary);
  font-size: 12.5px;
  padding: 6px 10px;
  cursor: pointer;
}

.module-tab.active {
  background: var(--k-accent);
  color: #ffffff;
  font-weight: 600;
}

.module-tools {
  display: flex;
  align-items: center;
  gap: 8px;
  flex: 1;
  justify-content: flex-end;
}

.kw-search {
  flex: 1;
  max-width: 200px;
  padding: 0;
  background: none;
}

.log-filter {
  display: flex;
  gap: 6px;
  padding: 0 12px 6px;
  overflow-x: auto;
  flex-shrink: 0;
}

.log-chip {
  flex-shrink: 0;
  border: none;
  border-radius: 12px;
  background: var(--k-bg-secondary);
  color: var(--k-text-secondary);
  font-size: 12px;
  padding: 4px 10px;
  cursor: pointer;
}

.log-chip.active {
  color: #ffffff;
  background: var(--k-accent);
}

/* ===== 业务表 ===== */
.table-scroll {
  flex: 1;
  overflow: auto;
  min-height: 200px;
}

.table-inner {
  position: relative;
}

.thead {
  position: sticky;
  top: 0;
  z-index: 3;
  display: flex;
  background: var(--k-bg-secondary);
  height: 30px;
}

.th {
  display: flex;
  align-items: center;
  font-size: 12px;
  font-weight: 500;
  color: var(--k-text-secondary);
  padding: 0 6px;
  white-space: nowrap;
  flex-shrink: 0;
  overflow: hidden;
}

.trow {
  display: flex;
  min-height: 42px;
  border-bottom: 0.5px solid var(--k-border);
}

.td {
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 1px;
  font-size: 12.5px;
  color: var(--k-text);
  padding: 4px 6px;
  white-space: nowrap;
  overflow: hidden;
  flex-shrink: 0;
  font-variant-numeric: tabular-nums;
}

.td.right {
  align-items: flex-end;
}

.td.muted,
.muted {
  color: var(--k-text-secondary);
}

.td.name {
  gap: 2px;
}

.td.profit {
  align-items: flex-end;
}

.q-name {
  font-size: 12.5px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.q-code {
  font-size: 10.5px;
  color: var(--k-text-secondary);
}

.up {
  color: #ff4d4f;
}

.down {
  color: #00b578;
}

.result-ok {
  color: #00b578;
}

.result-pending {
  color: #ff976a;
}

.result-muted {
  color: var(--k-text-secondary);
}

.dir-tag {
  font-size: 10.5px;
  font-weight: 700;
  padding: 1px 6px;
  border-radius: 4px;
}

.tag-buy {
  color: #ff4d4f;
  background: rgba(255, 77, 79, 0.12);
}

.tag-sell {
  color: #00b578;
  background: rgba(0, 181, 120, 0.12);
}

.status-tag {
  font-size: 11px;
  padding: 1px 5px;
  border-radius: 4px;
}

.st-reported {
  color: #ff4d4f;
}

.st-partial {
  color: #ff976a;
}

.st-muted {
  color: var(--k-text-secondary);
}

.actions {
  flex-direction: row !important;
  align-items: center !important;
  justify-content: flex-end;
  gap: 5px;
}

.inline-btn {
  border: none;
  border-radius: 5px;
  font-size: 11px;
  font-weight: 600;
  padding: 3px 8px;
  cursor: pointer;
  color: #ffffff;
}

.inline-btn.buy {
  background: #ff4d4f;
}

.inline-btn.sell {
  background: #00b578;
}

.inline-btn.cond {
  background: #1989fa;
}

.inline-btn.cancel {
  background: #969799;
}

.empty {
  text-align: center;
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 32px 0;
}

/* ===== 底部买卖条 ===== */
.bottom-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 12px;
  border-top: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.trade-btn {
  flex: 1;
  border: none;
  border-radius: 10px;
  color: #ffffff;
  font-size: 15px;
  font-weight: 700;
  padding: 11px 0;
  cursor: pointer;
}

.trade-btn.buy {
  background: #ff4d4f;
}

.trade-btn.sell {
  background: #00b578;
}

.bottom-bar .tool-btn {
  flex-shrink: 0;
}

/* ===== 对话框 ===== */
.dialog-body {
  padding: 12px 0 4px;
}

.dialog-note {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 8px 16px 12px;
}

.wallet-body {
  font-size: 13px;
  line-height: 1.9;
  color: var(--k-text);
  padding: 12px 16px 20px;
  text-align: center;
}
</style>
