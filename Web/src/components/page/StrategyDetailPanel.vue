<template>
  <div class="sdp">
    <!-- 页头：返回 ｜ 策略详情 ｜ 编辑（对齐原生 StrategyDetailView 头部动作） -->
    <div class="nav-line">
      <button class="nav-link" aria-label="strategyDetail.back" @click="emit('close')">‹ 返回</button>
      <span class="nav-center">策略详情</span>
      <button class="nav-link save" aria-label="strategyDetail.edit" @click="edit">编辑</button>
    </div>

    <template v-if="snap">
      <!-- 页内浅蓝提示条（生成成功 toast，3 秒自动消失，对齐原生 showToast） -->
      <div v-if="toastText" class="toast-bar">{{ toastText }}</div>
      <div class="sdp-body">
        <!-- 选股条件卡 -->
        <div class="card" aria-label="strategyDetail.pickCard">
          <div class="card-title">选股条件</div>
          <div class="card-text">{{ pickSummaryText }}</div>
        </div>

        <!-- 交易指令与绑定账户卡 -->
        <div class="card" aria-label="strategyDetail.tradeCard">
          <div class="card-title">交易指令与绑定账户</div>
          <template v-if="snap.tradeConfigured">
            <div class="card-text">{{ tradeSummaryText }}</div>
            <div v-if="snap.boundAccounts.length > 0" class="card-sub">
              绑定账户：{{ snap.boundAccounts.join('、') }}
            </div>
            <div v-if="snap.missingCount > 0" class="card-warn">
              {{ snap.missingCount }} 个账户已失效
            </div>
          </template>
          <div v-else class="card-warn">尚未配置交易指令与绑定账户，请点右上角编辑</div>
        </div>

        <!-- 交易规则卡 -->
        <div class="card" aria-label="strategyDetail.rulesCard">
          <div class="card-title">交易规则</div>
          <template v-if="values">
            <div
              v-if="!values.unavailable && values.rules.length === 0 && values.parseErrors.length === 0"
              class="card-sub"
            >还没有交易规则</div>
            <div v-for="(r, i) in values.rules" :key="i" class="rule-row">
              <span class="rule-idx">{{ i + 1 }}.</span>
              <span class="rule-text">{{ r.trigger }}</span>
            </div>
            <div v-for="(e, i) in values.parseErrors" :key="`e${i}`" class="rule-err">✗ {{ e }}</div>
            <div v-if="values.unavailable" class="card-sub">—</div>
          </template>
          <div v-else class="card-sub">…</div>
        </div>

        <!-- 执行区 -->
        <div class="card" aria-label="strategyDetail.actions">
          <div class="card-title">执行</div>
          <div class="action-row">
            <button class="action-btn" aria-label="strategyDetail.runPick" @click="openPickRun">跑选股</button>
            <button
              class="action-btn"
              aria-label="strategyDetail.generate"
              :disabled="!snap.canGenerate"
              @click="openPickRun"
            >生成条件单</button>
            <button class="action-btn" aria-label="strategyDetail.backtest" @click="runBacktest">回测</button>
          </div>
          <div v-if="!snap.canGenerate" class="card-warn">请先在编辑里配置交易指令与绑定账户</div>
        </div>

        <div style="height: 24px"></div>
      </div>
    </template>

    <div v-else class="sdp-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2-9c：策略详情 Web 页（strategyDetail）。基础信息由 strategyDetail.snapshot 同步直出，
// 引擎取值（选股摘要/交易摘要/规则触发文案）经 strategyDetail.changed(values) 推送
// （占位→就绪两段式，对齐原生 StrategyDetailView 的 E 组口径）。
// 编辑 → strategyDetail.edit（Web 页内切 strategyEditor）；回测 → strategyDetail.backtest；
// 跑选股 / 生成条件单 → Web 页内切 pickRun（P2-9c-3，勾选与确认在 pickRun 内完成）。
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { StrategyDetailSnapshot, StrategyDetailValues } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<StrategyDetailSnapshot | null>(null)
const values = ref<StrategyDetailValues | null>(null)
const toastText = ref('')
let toastTimer: ReturnType<typeof setTimeout> | null = null

/** 未就绪占位：「…」= 取数中，「—」= 引擎不可用（原生 placeholder 口径） */
const pickSummaryText = computed(() => {
  if (values.value?.unavailable) return '—'
  return values.value?.pickSummary ?? '…'
})

const tradeSummaryText = computed(() => {
  if (values.value?.unavailable) return '—'
  return values.value?.tradeSummary ?? '…'
})

async function pullSnapshot(): Promise<void> {
  try {
    const d = ((await klineBus.request('strategyDetail', 'snapshot')) ?? {}) as Record<string, unknown>
    snap.value = {
      id: String(d.id ?? ''),
      name: String(d.name ?? ''),
      tradeConfigured: d.tradeConfigured === true,
      canGenerate: d.canGenerate === true,
      boundAccounts: (d.boundAccounts ?? []) as string[],
      missingCount: Number(d.missingCount ?? 0),
      valuesQueued: d.valuesQueued === true,
      toast: String(d.toast ?? ''),
    }
    values.value = null
    // 生成成功 toast（原生一次性带出）：3 秒自动消失
    if (snap.value.toast) showToast(snap.value.toast)
  } catch (e) {
    console.error('strategyDetail.snapshot 失败', e)
  }
}

function showToast(text: string): void {
  toastText.value = text
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toastText.value = '' }, 3000)
}

/** 跑选股 / 生成条件单入口：Web 页内切 pickRun（勾选与确认在 pickRun 内完成） */
function openPickRun(): void {
  void klineBus.request('page', 'open', { name: 'pickRun' })
    .catch((e) => console.error('page.open pickRun 失败', e))
}

function edit(): void {
  void klineBus.request('strategyDetail', 'edit', {}).catch((e) => console.error('strategyDetail.edit 失败', e))
}

function runBacktest(): void {
  void klineBus.request('strategyDetail', 'backtest', {}).catch((e) => console.error('strategyDetail.backtest 失败', e))
}

function handleChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason !== 'values') return
  values.value = {
    reason: 'values',
    pickSummary: String(payload?.['pickSummary'] ?? ''),
    tradeSummary: String(payload?.['tradeSummary'] ?? ''),
    rules: (payload?.['rules'] ?? []) as StrategyDetailValues['rules'],
    parseErrors: (payload?.['parseErrors'] ?? []) as string[],
    unavailable: payload?.['unavailable'] === true,
  }
}

onMounted(async () => {
  klineBus.on('strategyDetail.changed', (ev) => handleChanged(ev.payload))
  await pullSnapshot()
})

onUnmounted(() => {
  if (toastTimer) clearTimeout(toastTimer)
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

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sdp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.toast-bar {
  position: absolute;
  top: 52px;
  left: 16px;
  right: 16px;
  z-index: 10;
  padding: 10px 12px;
  border-radius: 8px;
  background: rgba(25, 137, 250, 0.14);
  color: #1989fa;
  font-size: 13px;
}

.sdp-body {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 14px;
}

.card-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text);
  margin-bottom: 8px;
}

.card-text {
  font-size: 14px;
  line-height: 1.5;
  color: var(--k-text);
  word-break: break-all;
  white-space: pre-wrap;
}

.card-sub {
  font-size: 12px;
  line-height: 1.5;
  color: var(--k-text-tertiary);
  margin-top: 4px;
  word-break: break-all;
}

.card-warn {
  font-size: 12px;
  line-height: 1.5;
  color: #ff9500;
  margin-top: 4px;
  word-break: break-all;
}

.rule-row {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  margin-top: 4px;
}

.rule-idx {
  font-size: 13px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.rule-text {
  font-size: 13px;
  line-height: 1.5;
  color: var(--k-text);
  word-break: break-all;
}

.rule-err {
  font-size: 12px;
  color: #ee0a24;
  margin-top: 4px;
  word-break: break-all;
}

.action-row {
  display: flex;
  gap: 10px;
}

.action-btn {
  flex: 1;
  border: none;
  border-radius: 10px;
  height: 44px;
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
  background: rgba(25, 137, 250, 0.12);
  color: #1989fa;
}

.action-btn:disabled {
  background: var(--k-bg);
  color: var(--k-text-tertiary);
  cursor: default;
}

.sdp-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>
