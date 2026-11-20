<template>
  <div class="cmp">
    <div class="nav-line">
      <button class="nav-link" aria-label="condManage.back" @click="emit('close')">‹ 返回</button>
      <span class="nav-center">条件单管理</span>
      <button class="nav-link accent" aria-label="condManage.new" @click="createNew">＋ 新建</button>
    </div>

    <div v-if="snap && !snap.engineReady" class="engine-banner">
      Python 引擎未就绪，条件单暂停结算；引擎就绪后自动恢复
    </div>

    <div class="seg-bar" v-if="snap">
      <button
        v-for="s in segments"
        :key="s.key"
        class="seg-item"
        :class="{ on: segment === s.key }"
        @click="segment = s.key"
      >{{ s.title }}</button>
    </div>

    <div class="cmp-body" v-if="snap">
      <div v-if="segmentOrders.length === 0" class="empty-block">
        <div class="empty-text">{{ emptyText }}</div>
        <button class="new-empty-btn" @click="createNew">新建条件单</button>
      </div>
      <div v-else class="cond-list">
        <div v-for="o in segmentOrders" :key="o.id" class="cond-card" @click="editOrder(o)">
          <div class="card-line1">
            <span class="c-name">{{ o.name }}</span>
            <span class="c-code">{{ o.code }}</span>
            <span v-if="o.isAlertOnly" class="alert-badge">提醒</span>
            <span class="status-tag" :class="o.status">{{ o.statusTitle }}</span>
            <button class="row-btn" :aria-label="`cond.edit.${o.name}`" @click.stop="editOrder(o)">编辑</button>
            <button
              v-if="o.status === 'monitoring'"
              class="row-btn cancel"
              @click.stop="cancelOrder(o)"
            >撤销</button>
          </div>
          <div class="card-line2">
            <span class="kind-chip">{{ o.kindTitle }}</span>
            <span class="c-summary">{{ o.conditionSummary }}</span>
          </div>
          <div class="card-line3">{{ o.directiveLine }}</div>
          <div v-if="o.repeatable && o.hasProgressTotal" class="progress-line">
            <div class="p-bar"><div class="p-fill" :style="{ width: progressPct(o) + '%' }"></div></div>
            <span class="p-text">{{ o.progressDone }} / {{ o.progressTotal }}</span>
          </div>
          <div v-if="o.lastMessage && o.status !== 'monitoring'" class="last-msg">{{ o.lastMessage }}</div>
        </div>
      </div>
      <div style="height: 16px"></div>
    </div>

    <div v-else class="cmp-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2-9a：条件单管理页 Web 版（condManage）。行文案为原生投影缓存直读（占位→就绪
// 经 cond.changed(texts) 重推）；编辑/新建切 condEditor 编辑器页（同一 WebView）。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { CondListSnapshot, CondOrderSnap } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<CondListSnapshot | null>(null)
const segment = ref('monitoring')

const segments = [
  { key: 'monitoring', title: '监控中' },
  { key: 'triggered', title: '已触发' },
  { key: 'invalid', title: '已失效' },
]

const segmentOrders = computed(() =>
  (snap.value?.orders ?? []).filter((o) => {
    const seg = o.status === 'monitoring' ? 'monitoring'
      : (o.status === 'triggered' || o.status === 'completed') ? 'triggered' : 'invalid'
    return seg === segment.value
  }))

const emptyText = computed(() => {
  switch (segment.value) {
    case 'monitoring': return '暂无监控中的条件单'
    case 'triggered': return '暂无已触发的条件单'
    default: return '暂无已失效的条件单'
  }
})

function progressPct(o: CondOrderSnap): number {
  if (!o.hasProgressTotal || o.progressTotal <= 0) return 0
  return Math.min(100, Math.round((o.progressDone / o.progressTotal) * 100))
}

async function pullList(): Promise<void> {
  try {
    snap.value = ((await klineBus.request('cond', 'list')) ?? {}) as unknown as CondListSnapshot
  } catch (e) {
    console.error('cond.list 失败', e)
  }
}

function editOrder(o: CondOrderSnap): void {
  void klineBus.request('cond', 'edit', { id: o.id }).catch((e) => console.error(e))
  // 原生切 activePage=condEditor（page.open 推送驱动本 WebView 切面板）
}

function createNew(): void {
  void klineBus.request('cond', 'new', {}).catch((e) => console.error(e))
}

function cancelOrder(o: CondOrderSnap): void {
  void klineBus.request('cond', 'cancel', { id: o.id })
    .then(() => pullList())
    .catch((e) => console.error(e))
}

function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'list' || reason === 'texts' || reason === 'saveResult') {
    void pullList()
  }
}

onMounted(async () => {
  klineBus.on('cond.changed', (ev) => handleChanged(ev.payload))
  await pullList()
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
  min-width: 44px;
  min-height: 44px;
}

.nav-link.accent {
  color: #1989fa;
  font-weight: 600;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
}

.cmp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.engine-banner {
  font-size: 12px;
  color: #ff9500;
  background: rgba(255, 149, 0, 0.1);
  padding: 8px 16px;
}

.seg-bar {
  display: flex;
  gap: 4px;
  padding: 10px 16px 0;
}

.seg-item {
  flex: 1;
  border: none;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 13px;
  height: 36px;
  border-radius: 8px;
  cursor: pointer;
}

.seg-item.on {
  background: var(--k-accent, #1989fa);
  color: #ffffff;
  font-weight: 600;
}

.cmp-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
}

.empty-block {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 12px;
  padding: 40px 0;
}

.empty-text {
  font-size: 13px;
  color: var(--k-text-secondary);
}

.new-empty-btn {
  border: 1px solid #1989fa;
  background: none;
  color: #1989fa;
  font-size: 13px;
  font-weight: 600;
  padding: 8px 14px;
  border-radius: 6px;
  cursor: pointer;
  min-height: 44px;
}

.cond-list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.cond-card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 12px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  cursor: pointer;
}

.card-line1 {
  display: flex;
  align-items: center;
  gap: 6px;
}

.c-name {
  font-size: 14px;
  font-weight: 700;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.c-code {
  font-size: 11px;
  color: var(--k-text-secondary);
}

.alert-badge {
  font-size: 10px;
  color: #ff9500;
  border: 1px solid #ff9500;
  border-radius: 4px;
  padding: 0 4px;
  flex-shrink: 0;
}

.status-tag {
  font-size: 10px;
  border-radius: 4px;
  padding: 1px 5px;
  background: var(--k-bg);
  color: var(--k-text-secondary);
  flex-shrink: 0;
}

.status-tag.monitoring { color: #1989fa; }
.status-tag.triggered, .status-tag.completed { color: #00b578; }
.status-tag.expired, .status-tag.cancelled, .status-tag.rejected { color: var(--k-text-tertiary); }

.row-btn {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: #1989fa;
  font-size: 12px;
  cursor: pointer;
  flex-shrink: 0;
}

.row-btn.cancel { color: var(--k-text-tertiary); }

.card-line2 {
  display: flex;
  align-items: flex-start;
  gap: 6px;
}

.kind-chip {
  font-size: 11px;
  color: #1989fa;
  background: rgba(25, 137, 250, 0.08);
  border-radius: 4px;
  padding: 1px 6px;
  flex-shrink: 0;
}

.c-summary {
  font-size: 13px;
  color: var(--k-text);
  line-height: 1.5;
  word-break: break-all;
}

.card-line3 {
  font-size: 12px;
  color: var(--k-text-secondary);
  line-height: 1.5;
  word-break: break-all;
}

.progress-line {
  display: flex;
  align-items: center;
  gap: 8px;
}

.p-bar {
  flex: 1;
  height: 6px;
  border-radius: 3px;
  background: var(--k-bg);
  overflow: hidden;
}

.p-fill {
  height: 100%;
  background: var(--k-accent, #1989fa);
  border-radius: 3px;
}

.p-text {
  font-size: 11px;
  color: var(--k-text-secondary);
  font-variant-numeric: tabular-nums;
  flex-shrink: 0;
}

.last-msg {
  font-size: 11px;
  color: var(--k-text-secondary);
  line-height: 1.5;
}

.cmp-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>
