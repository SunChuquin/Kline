<template>
  <div class="trp">
    <!-- ① 会话列表页 -->
    <template v-if="!detail">
      <div class="nav-line">
        <button class="nav-link" aria-label="trainingRecord.back" @click="emit('close')">‹ 返回</button>
        <span class="nav-center">训练记录</span>
        <button
          class="nav-link danger"
          aria-label="trainingRecord.clearAll"
          :disabled="sessions.length === 0"
          @click="clearOpen = true"
        >清空</button>
      </div>

      <div v-if="sessions.length === 0" class="empty-state">
        <div class="empty-icon">📈</div>
        <div class="empty-main">暂无训练记录</div>
        <div class="empty-sub">在 K 线图页发起「单人训练」，创建会话后训练记录会显示在这里</div>
      </div>

      <div v-else class="session-list">
        <template v-for="(s, i) in sessions" :key="s.id">
          <div class="session-row">
            <div class="session-text">
              <div class="session-line1">
                <span class="session-name">{{ s.name }}</span>
                <span class="session-code">{{ s.code }}</span>
              </div>
              <div class="session-sub">
                起始 {{ ymd(s.startDate) }} ~ {{ s.endDate ? ymd(s.endDate) : '进行中' }}
                · 交易 {{ s.tradeCount }} 笔 · {{ s.status === 'running' ? '进行中' : '已完成' }}
              </div>
              <div class="session-time">{{ s.createdAtText }}</div>
            </div>
            <button class="row-btn" :aria-label="`trainingRecord.detail.${i}`" @click="openDetail(s)">›</button>
            <button class="row-btn" :aria-label="`trainingRecord.delete.${i}`" @click="deleteTarget = s">🗑</button>
          </div>
          <div class="divider"></div>
        </template>
        <div style="height: 12px"></div>
      </div>
    </template>

    <!-- ② 交易明细页（会话摘要 + 三分段） -->
    <template v-else>
      <div class="nav-line">
        <button class="nav-link" aria-label="trainingRecord.detailBack" @click="detail = null">‹ 返回</button>
        <span class="nav-center">交易明细</span>
        <span class="nav-side">{{ detail.session.name }}</span>
      </div>
      <div class="summary-line">
        {{ detail.session.name }} {{ detail.session.code }} · 起始 {{ ymd(detail.session.startDate) }} ~
        {{ detail.session.endDate ? ymd(detail.session.endDate) : '—' }} · 共 {{ detail.session.tradeCount }} 笔
      </div>
      <div class="seg-bar">
        <button
          v-for="t in tabs"
          :key="t.value"
          class="seg-item"
          :class="{ on: tab === t.value }"
          @click="tab = t.value"
        >{{ t.title }} {{ tabCount(t.value) }}</button>
      </div>

      <!-- 成交表（横向滚动，对齐原生列宽） -->
      <div v-if="tab === 'trades'" class="tab-content">
        <div v-if="detail.trades.length === 0" class="list-empty">暂无交易明细</div>
        <div v-else class="trades-scroll">
          <div class="t-row t-head">
            <span class="tc" :style="tc(colSeq)">序号</span>
            <span class="tc tc-c" :style="tc(colDir)">方向</span>
            <span class="tc tc-c" :style="tc(colMark)">标记</span>
            <span class="tc" :style="tc(colDate)">成交日期</span>
            <span class="tc tc-r" :style="tc(colPrice)">成交价</span>
            <span class="tc tc-r" :style="tc(colQty)">数量</span>
            <span class="tc tc-r" :style="tc(colAmount)">成交额</span>
            <span class="tc tc-r" :style="tc(colFee)">手续费</span>
            <span class="tc tc-r" :style="tc(colPnl)">盈亏</span>
            <span class="tc" :style="tc(colTrigger)">触发来源</span>
            <span class="tc" :style="tc(colNote)">备注</span>
          </div>
          <div class="t-divider"></div>
          <template v-for="t in detail.trades" :key="t.seq">
            <div class="t-row">
              <span class="tc mono t-sec" :style="tc(colSeq)">{{ t.seq }}</span>
              <span class="tc tc-c" :class="t.direction === 'buy' ? 'tone-red' : 'tone-green'" :style="tc(colDir)">
                {{ t.direction === 'buy' ? '买入' : '卖出' }}
              </span>
              <span class="tc tc-c" :class="markClass(t.mark)" :style="tc(colMark)">{{ t.mark }}</span>
              <span class="tc mono t-sec" :style="tc(colDate)">{{ ymd(t.tradeDate) }}</span>
              <span class="tc mono tc-r" :style="tc(colPrice)">{{ t.price.toFixed(2) }}</span>
              <span class="tc mono tc-r" :style="tc(colQty)">{{ t.qty }}</span>
              <span class="tc mono tc-r" :style="tc(colAmount)">{{ t.amount.toFixed(2) }}</span>
              <span class="tc mono tc-r t-sec" :style="tc(colFee)">{{ t.fee.toFixed(2) }}</span>
              <span class="tc mono tc-r" :class="pnlClass(t.pnl)" :style="tc(colPnl)">
                {{ t.pnl === null ? '—' : (t.pnl >= 0 ? '+' : '') + t.pnl.toFixed(2) }}
              </span>
              <span class="tc" :class="t.triggerText.startsWith('条件单') ? 'tone-blue' : 't-sec'" :style="tc(colTrigger)">
                {{ t.triggerText }}
              </span>
              <span class="tc t-sec" :style="tc(colNote)">{{ t.note || '—' }}</span>
            </div>
            <div class="t-divider"></div>
          </template>
        </div>
      </div>

      <!-- 条件单卡片 -->
      <div v-else-if="tab === 'conditions'" class="tab-content">
        <div v-if="detail.conds.length === 0" class="list-empty">本会话暂无条件单</div>
        <div v-else class="card-list">
          <div v-for="(c, i) in detail.conds" :key="i" class="cond-card">
            <div class="cond-line1">
              <span class="kind-chip">{{ c.kindTitle }}</span>
              <span class="cond-summary">{{ c.summary }}</span>
              <span v-if="c.alertOnly" class="alert-badge">仅提醒</span>
              <span class="status-tag">{{ c.statusTitle }}</span>
            </div>
            <div class="cond-sub">创建训练日 {{ ymd(c.createdDate) }} · {{ c.validity }}</div>
            <div v-if="c.lastMessage" class="cond-msg">{{ c.lastMessage }}</div>
          </div>
        </div>
      </div>

      <!-- 预警记录卡片 -->
      <div v-else class="tab-content">
        <div v-if="detail.alerts.length === 0" class="list-empty">本会话暂无预警记录</div>
        <div v-else class="card-list">
          <div v-for="(a, i) in detail.alerts" :key="i" class="cond-card">
            <div class="cond-line1">
              <span class="alert-bell">🔔</span>
              <span class="alert-date">训练日 {{ ymd(a.tradeDate) }}</span>
              <span class="alert-price">{{ a.price.toFixed(2) }}</span>
            </div>
            <div class="alert-msg">{{ a.message }}</div>
          </div>
        </div>
      </div>
    </template>

    <!-- 删除单条二次确认 -->
    <van-dialog
      v-model:show="deleteOpen"
      title="删除这条训练记录？"
      show-cancel-button
      confirm-button-text="删除"
      confirm-button-color="#ee0a24"
      @confirm="confirmDelete"
    />
    <!-- 清空全部二次确认 -->
    <van-dialog
      v-model:show="clearOpen"
      title="清空全部训练记录？"
      show-cancel-button
      confirm-button-text="清空全部"
      confirm-button-color="#ee0a24"
      @confirm="confirmClear"
    />
  </div>
</template>

<script setup lang="ts">
// 训练记录管理 Web 面板（P2-6c-3，对齐原生 TrainingRecordListView / TrainingTradeDetailView）：
// 会话列表（进入/删除）+ 明细三分段（成交表/条件单/预警）；条件单文案经引擎投影，
// 未就绪显示「…」，projection 就绪推送后自动重拉。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { TrainingRecordDetail, TrainingRecordsSnapshot, TrainingSessionSnap } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const sessions = ref<TrainingSessionSnap[]>([])
const detail = ref<TrainingRecordDetail | null>(null)
const tab = ref<'trades' | 'conditions' | 'alerts'>('trades')
const deleteTarget = ref<TrainingSessionSnap | null>(null)
const deleteOpen = computed({
  get: () => deleteTarget.value !== null,
  set: (v: boolean) => { if (!v) deleteTarget.value = null },
})
const clearOpen = ref(false)

const tabs = [
  { value: 'trades' as const, title: '成交' },
  { value: 'conditions' as const, title: '条件单' },
  { value: 'alerts' as const, title: '预警' },
]

async function pullRecords(): Promise<void> {
  try {
    const s = (await klineBus.request('training', 'records.snapshot')) as unknown as TrainingRecordsSnapshot
    sessions.value = s.sessions ?? []
  } catch (e) {
    console.error('training.records.snapshot 失败', e)
  }
}

async function openDetail(s: TrainingSessionSnap): Promise<void> {
  try {
    const d = (await klineBus.request('training', 'recordDetail', { id: s.id })) as unknown as TrainingRecordDetail
    detail.value = d
    tab.value = 'trades'
  } catch (e) {
    console.error('training.recordDetail 失败', e)
  }
}

function confirmDelete(): void {
  const id = deleteTarget.value?.id
  if (!id) return
  void klineBus.request('training', 'deleteRecord', { id })
    .then(() => {
      if (detail.value?.session.id === id) detail.value = null
      return pullRecords()
    })
    .catch((e) => console.error('training.deleteRecord 失败', e))
}

function confirmClear(): void {
  void klineBus.request('training', 'clearRecords')
    .then(() => {
      detail.value = null
      return pullRecords()
    })
    .catch((e) => console.error('training.clearRecords 失败', e))
}

function tabCount(value: 'trades' | 'conditions' | 'alerts'): number {
  const d = detail.value
  if (!d) return 0
  return value === 'trades' ? d.trades.length : value === 'conditions' ? d.conds.length : d.alerts.length
}

function ymd(v: number | null): string {
  if (v === null || v <= 0) return '—'
  const s = String(v)
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s
}

function markClass(mark: 'B' | 'S' | 'T'): string {
  return mark === 'B' ? 'tone-red' : mark === 'S' ? 'tone-green' : 'tone-blue'
}

function pnlClass(pnl: number | null): string {
  if (pnl === null) return 't-sec'
  return pnl > 0 ? 'tone-red' : pnl < 0 ? 'tone-green' : 't-sec'
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('training.changed', (ev) => {
    const reason = String(ev.payload?.['reason'] ?? '')
    // 条件单文案投影就绪 → 重拉当前明细；其余变化刷新列表
    if (reason === 'projection' && detail.value) {
      void openDetail(detail.value.session)
    } else {
      void pullRecords()
    }
  })
  await pullRecords()
})

// 明细列宽（对齐原生 Col）
const colSeq = 44, colDir = 52, colMark = 44, colDate = 92, colPrice = 84,
      colQty = 64, colAmount = 96, colFee = 72, colPnl = 88, colTrigger = 132, colNote = 140
function tc(width: number): Record<string, string> {
  return { width: `${width}px`, flex: 'none' }
}
</script>

<style scoped>
.trp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.nav-line {
  display: flex;
  align-items: center;
  height: 44px;
  flex-shrink: 0;
  padding: 0 16px;
  position: relative;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 15px;
  min-width: 44px;
  min-height: 44px;
  cursor: pointer;
  text-align: left;
  padding: 0;
}

.nav-link.danger { color: #ee0a24; margin-left: auto; text-align: right; }
.nav-link.danger:disabled { opacity: 0.4; cursor: default; }

.nav-center {
  position: absolute;
  left: 50%;
  transform: translateX(-50%);
  font-size: 15px;
  font-weight: 600;
  color: var(--k-text);
}

.nav-side {
  margin-left: auto;
  font-size: 13px;
  color: var(--k-text-secondary);
  max-width: 140px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.session-list {
  flex: 1;
  overflow-y: auto;
}

.session-row {
  display: flex;
  align-items: center;
  gap: 4px;
  min-height: 78px;
  padding-left: 12px;
}

.session-text { flex: 1; min-width: 0; }

.session-line1 {
  display: flex;
  align-items: baseline;
  gap: 5px;
}

.session-name {
  font-size: 15px;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.session-code {
  font-size: 12px;
  color: var(--k-text-secondary);
}

.session-sub {
  font-size: 12px;
  color: var(--k-text-secondary);
  margin-top: 3px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.session-time {
  font-size: 11px;
  color: var(--k-text-tertiary);
  margin-top: 2px;
}

.row-btn {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 15px;
  cursor: pointer;
}

.empty-state {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 10px;
  padding: 0 32px;
  text-align: center;
}

.empty-icon { font-size: 34px; }

.empty-main {
  font-size: 13px;
  color: var(--k-text-secondary);
}

.empty-sub {
  font-size: 12px;
  color: var(--k-text-secondary);
  line-height: 1.5;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 12px;
}

/* 明细页 */
.summary-line {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 0 16px;
  height: 34px;
  display: flex;
  align-items: center;
  white-space: nowrap;
  overflow: hidden;
}

.seg-bar {
  display: flex;
  gap: 6px;
  padding: 6px 12px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.seg-item {
  flex: 1;
  border: none;
  background: var(--k-bg-secondary);
  color: var(--k-text-secondary);
  font-size: 13px;
  height: 30px;
  border-radius: 8px;
  cursor: pointer;
}

.seg-item.on {
  background: var(--k-accent);
  color: #ffffff;
  font-weight: 600;
}

.tab-content {
  flex: 1;
  overflow: auto;
}

.list-empty {
  display: flex;
  align-items: center;
  justify-content: center;
  min-height: 200px;
  font-size: 13px;
  color: var(--k-text-secondary);
}

/* 成交表 */
.trades-scroll {
  min-width: 100%;
  width: max-content;
}

.t-row {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 0 8px;
  height: 44px;
}

.t-head {
  height: 34px;
  background: var(--k-bg-secondary);
}

.tc {
  font-size: 12.5px;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.t-head .tc {
  font-size: 11.5px;
  font-weight: 600;
  color: var(--k-text-secondary);
}

.tc-c { text-align: center; }
.tc-r { text-align: right; }
.mono { font-variant-numeric: tabular-nums; }
.t-sec { color: var(--k-text-secondary); }

.t-divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 8px;
}

/* 条件单 / 预警卡片 */
.card-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px;
}

.cond-card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 5px;
}

.cond-line1 {
  display: flex;
  align-items: center;
  gap: 6px;
}

.kind-chip {
  font-size: 11px;
  font-weight: 600;
  color: var(--k-accent);
  background: rgba(0, 122, 255, 0.12);
  border-radius: 4px;
  padding: 2px 6px;
  flex-shrink: 0;
}

.cond-summary {
  flex: 1;
  font-size: 12.5px;
  color: var(--k-text);
  line-height: 1.4;
}

.alert-badge {
  font-size: 11px;
  color: #ff9500;
  border: 1px solid #ff9500;
  border-radius: 4px;
  padding: 1px 5px;
  flex-shrink: 0;
}

.status-tag {
  font-size: 11px;
  color: var(--k-text-secondary);
  background: var(--k-bg);
  border-radius: 4px;
  padding: 2px 6px;
  flex-shrink: 0;
}

.cond-sub {
  font-size: 11px;
  color: var(--k-text-secondary);
}

.cond-msg {
  font-size: 11px;
  color: var(--k-text-secondary);
  line-height: 1.4;
}

.alert-bell { font-size: 12px; }

.alert-date {
  font-size: 12px;
  font-weight: 600;
  color: var(--k-text);
  flex: 1;
}

.alert-price {
  font-size: 12px;
  font-weight: 600;
  color: var(--k-text);
}

.alert-msg {
  font-size: 12.5px;
  color: var(--k-text-secondary);
  line-height: 1.4;
}

/* A 股语义色 */
.tone-red { color: #ff3b30; font-weight: 600; }
.tone-green { color: var(--k-ok); font-weight: 600; }
.tone-blue { color: var(--k-accent); }
</style>
