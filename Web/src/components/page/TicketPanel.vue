<template>
  <div class="tkp">
    <!-- 页头：模拟下单 ｜ 标的 ｜ 关闭（对齐 SimFullScreenTicket） -->
    <div class="nav-line">
      <span class="nav-title">模拟下单</span>
      <span class="nav-meta">{{ snap?.meta.name }} {{ snap?.meta.code }}</span>
      <button class="nav-x" aria-label="ticket.close" @click="emit('close')">✕</button>
    </div>

    <div class="tkp-body" v-if="snap">
      <!-- 账户信息 -->
      <div class="acct-line">
        <span class="acct-name">{{ snap.account.name }}</span>
        <span class="acct-cash">可用 {{ fmtAmount(snap.account.cash) }}</span>
      </div>

      <!-- 方向 -->
      <div class="seg-dir">
        <button class="dir-btn buy" :class="{ on: direction === 'buy' }" @click="direction = 'buy'">买入</button>
        <button class="dir-btn sell" :class="{ on: direction === 'sell' }" @click="direction = 'sell'">卖出</button>
      </div>

      <!-- 报价类型 -->
      <div class="seg-price">
        <button class="pt-btn" :class="{ on: priceType === 'limit' }" @click="priceType = 'limit'">限价</button>
        <button class="pt-btn" :class="{ on: priceType === 'market' }" @click="priceType = 'market'">市价</button>
      </div>

      <!-- 委托价 / 数量 -->
      <label class="t-line">
        <span>委托价</span>
        <input
          v-model="priceText"
          class="t-input"
          inputmode="decimal"
          :disabled="priceType === 'market'"
          :placeholder="priceType === 'market' ? '市价' : ''"
          @input="didEditPrice = true"
        />
        <span class="t-unit">元</span>
      </label>
      <label class="t-line">
        <span>数量</span>
        <input v-model="qtyText" class="t-input" inputmode="numeric" placeholder="0" @input="syncQty" />
        <span class="t-unit">股</span>
      </label>

      <!-- 仓位快捷（买入按现金可买整手、卖出按可卖） -->
      <div class="pos-chips" aria-label="ticket.positionChips">
        <button v-for="r in [0.25, 0.5, 0.75, 1]" :key="r" class="pos-chip" @click="applyPosition(r)">{{ r * 100 }}%</button>
      </div>

      <!-- 可买 / 可卖提示（按费率纯算术） -->
      <div class="avail-line" v-if="priceType === 'limit' && effectivePrice > 0">
        <span v-if="direction === 'buy'">可买 {{ buyAvailText }}</span>
        <span v-else>可卖 {{ sellable }}</span>
      </div>

      <!-- 费用与委托后可用资金 -->
      <div class="fee-block" v-if="feeText">
        <div class="fee-line"><span>预计费用合计</span><span>{{ feeText }}</span></div>
        <div class="fee-line" v-if="cashAfterText"><span>委托后可用资金</span><span>{{ cashAfterText }}</span></div>
      </div>

      <div v-if="errorText" class="tkp-error">{{ errorText }}</div>

      <!-- 提交 -->
      <button
        class="submit-btn"
        :class="direction"
        aria-label="ticket.submit"
        @click="submit"
      >{{ direction === 'buy' ? '买入' : '卖出' }} {{ priceType === 'limit' ? '限价' : '市价' }}</button>
      <div class="t-line footer-note">提交统一走模拟账户校验与写入；失败原因就地展示</div>
    </div>

    <div v-else class="tkp-loading">加载中…</div>

    <!-- 卖出二次确认（对齐原生 showSellConfirm） -->
    <van-dialog
      v-model:show="sellConfirm"
      :title="`确认卖出 ${snap?.meta.name ?? ''} ${qty} 股？`"
      show-cancel-button
      confirm-button-text="确认卖出"
      confirm-button-color="#00b578"
      @confirm="doSubmit"
    />
  </div>
</template>

<script setup lang="ts">
// P2-9a：全屏下单页 Web 版（ticket）。票面为 Web 本地表单；提交复用 trade.submit
// （快捷面板 Web 票面同款链路：校验/费用/写入全在原生 SimStore.submit）。
// 费用合计 / 仓位快捷 / 可买可卖由 Web 端按 snapshot 下发的费率常量纯算术计算。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { TicketSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<TicketSnapshot | null>(null)
const direction = ref<'buy' | 'sell'>('buy')
const priceType = ref<'limit' | 'market'>('limit')
const priceText = ref('')
const qtyText = ref('')
const didEditPrice = ref(false)
const errorText = ref('')
const sellConfirm = ref(false)

const qty = computed(() => parseInt(qtyText.value || '0', 10) || 0)
/** 生效价格：限价取输入、市价取最新价 */
const effectivePrice = computed(() => {
  if (priceType.value === 'market') return snap.value?.lastPrice ?? 0
  return parseFloat(priceText.value) || 0
})

const amount = computed(() => effectivePrice.value * qty.value)

/** 佣金：成交额 × 费率，不足最低按最低（对齐 SimTradingRules.commission） */
function commission(a: number): number {
  const rules = snap.value!.rules
  return Math.max(a * rules.commissionRate, rules.commissionMin)
}

/** 合计费用：佣金 + 印花税（仅卖出） */
const totalFee = computed(() => {
  if (!snap.value || amount.value <= 0) return 0
  const rules = snap.value.rules
  const stamp = direction.value === 'sell' ? amount.value * rules.stampTaxRate : 0
  return commission(amount.value) + stamp
})

const feeText = computed(() =>
  totalFee.value > 0 ? moneyText(totalFee.value) : '')

/** 委托后可用资金：买入扣金额与费用、卖出加金额扣费用 */
const cashAfterText = computed(() => {
  if (!snap.value || amount.value <= 0 || totalFee.value <= 0) return ''
  const delta = direction.value === 'buy'
    ? snap.value.account.cash - amount.value - totalFee.value
    : snap.value.account.cash + amount.value - totalFee.value
  return moneyText(delta)
})

/** 可买整手：现金 / (价 × (1 + 佣金率)) 向下取整到整手（近似口径，提交易原生复核） */
const buyAvailText = computed(() => {
  if (!snap.value) return '0'
  const p = effectivePrice.value
  if (p <= 0) return '0'
  const rules = snap.value.rules
  const perLot = p * rules.lotSize * (1 + rules.commissionRate)
  const lots = Math.floor(snap.value.account.cash / Math.max(perLot, 0.01))
  return `${lots * rules.lotSize} 股`
})

/** 可卖数量：持仓入口的 availableQty（T+1 口径由原生维护） */
const sellable = computed(() => snap.value?.position?.availableQty ?? 0)

function moneyText(v: number): string {
  return v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

/** 仓位快捷：买入按现金可买整手比例、卖出按可卖比例（对齐原生 positionChips 口径） */
function applyPosition(ratio: number): void {
  if (!snap.value) return
  const rules = snap.value.rules
  if (direction.value === 'buy') {
    const p = effectivePrice.value
    if (p <= 0) return
    const perLot = p * rules.lotSize * (1 + rules.commissionRate)
    const lots = Math.floor((snap.value.account.cash * ratio) / Math.max(perLot, 0.01))
    qtyText.value = String(lots * rules.lotSize)
  } else {
    qtyText.value = String(Math.floor(sellable.value * ratio))
  }
  syncQty()
}

function syncQty(): void {
  const digits = qtyText.value.replace(/\D/g, '')
  qtyText.value = digits
}

/** 委托价默认跟随最新价（用户手动改过则不再跟随） */
function followPrice(): void {
  if (!didEditPrice.value && snap.value?.lastPrice) {
    priceText.value = snap.value.lastPrice.toFixed(2)
  }
}

async function pullSnapshot(): Promise<void> {
  try {
    snap.value = ((await klineBus.request('ticket', 'snapshot')) ?? {}) as TicketSnapshot
    direction.value = snap.value.initialDirection
    followPrice()
    // 持仓入口预填卖出全部可卖（对齐原生持仓行下单语义：方向来自入口参数，数量由用户输入）
  } catch (e) {
    console.error('ticket.snapshot 失败', e)
    errorText.value = String(e instanceof Error ? e.message : e).slice(0, 60)
  }
}

/** 本地预检（对齐原生票面：限价需价格、整手数量） */
function submit(): void {
  if (!snap.value) return
  const rules = snap.value.rules
  if (priceType.value === 'limit' && !(parseFloat(priceText.value) > 0)) {
    errorText.value = '请输入有效的委托价'
    return
  }
  if (qty.value <= 0) {
    errorText.value = '请输入委托数量'
    return
  }
  if (qty.value % rules.lotSize !== 0) {
    errorText.value = `委托数量需为 ${rules.lotSize} 股的整数倍`
    return
  }
  errorText.value = ''
  if (direction.value === 'sell') {
    sellConfirm.value = true
    return
  }
  void doSubmit()
}

async function doSubmit(): Promise<void> {
  if (!snap.value) return
  try {
    await klineBus.request('trade', 'submit', {
      accountID: snap.value.account.id,
      metaID: '',
      direction: direction.value,
      priceType: priceType.value,
      price: priceType.value === 'limit' ? parseFloat(priceText.value) : null,
      qty: qty.value,
      file: snap.value.meta.file,
    })
    // 成功即关页（对齐原生 fullScreenCover 提交成功关闭）
    emit('close')
  } catch (e) {
    errorText.value = String(e instanceof Error ? e.message : e).slice(0, 60)
  }
}

onMounted(async () => {
  await pullSnapshot()
})
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  gap: 8px;
  height: 52px;
  padding: 0 16px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-title {
  font-size: 15px;
  font-weight: 700;
  color: var(--k-text);
}

.nav-meta {
  flex: 1;
  font-size: 12px;
  color: var(--k-text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.nav-x {
  width: 32px;
  height: 32px;
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}

.tkp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.tkp-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
}

.acct-line {
  display: flex;
  justify-content: space-between;
  font-size: 13px;
  padding: 6px 0;
}

.acct-name { font-weight: 500; }

.acct-cash { color: var(--k-text-secondary); font-variant-numeric: tabular-nums; }

.seg-dir {
  display: flex;
  gap: 8px;
  margin: 8px 0;
}

.dir-btn {
  flex: 1;
  height: 44px;
  border: 1px solid var(--k-border);
  border-radius: 8px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.dir-btn.buy.on {
  background: #ff4d4f;
  border-color: #ff4d4f;
  color: #ffffff;
}

.dir-btn.sell.on {
  background: #00b578;
  border-color: #00b578;
  color: #ffffff;
}

.seg-price {
  display: flex;
  gap: 8px;
  margin-bottom: 10px;
}

.pt-btn {
  flex: 1;
  height: 36px;
  border: 1px solid var(--k-border);
  border-radius: 8px;
  background: var(--k-bg-secondary);
  color: var(--k-text);
  font-size: 13px;
  cursor: pointer;
}

.pt-btn.on {
  border-color: var(--k-accent, #1989fa);
  color: var(--k-accent, #1989fa);
  font-weight: 600;
}

.t-line {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 44px;
  border-bottom: 0.5px solid var(--k-border);
  font-size: 13px;
  color: var(--k-text-secondary);
}

.t-input {
  flex: 1;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  text-align: right;
  font-variant-numeric: tabular-nums;
  outline: none;
  min-width: 0;
}

.t-input:disabled { color: var(--k-text-secondary); }

.t-unit {
  color: var(--k-text-tertiary);
  font-size: 12px;
}

.pos-chips {
  display: flex;
  gap: 6px;
  padding: 10px 0;
}

.pos-chip {
  flex: 1;
  border: 1px solid var(--k-border);
  border-radius: 6px;
  background: none;
  color: var(--k-text-secondary);
  font-size: 11.5px;
  padding: 6px 0;
  cursor: pointer;
}

.avail-line {
  font-size: 11.5px;
  color: var(--k-text-secondary);
  padding: 2px 0 6px;
}

.fee-block {
  border-top: 0.5px solid var(--k-border);
  padding: 8px 0;
}

.fee-line {
  display: flex;
  justify-content: space-between;
  font-size: 11.5px;
  color: var(--k-text-secondary);
  padding: 2px 0;
  font-variant-numeric: tabular-nums;
}

.tkp-error {
  font-size: 12px;
  color: #ee0a24;
  padding: 6px 0;
}

.submit-btn {
  width: 100%;
  border: none;
  border-radius: 9px;
  color: #ffffff;
  font-size: 15px;
  font-weight: 700;
  padding: 12px 0;
  cursor: pointer;
  margin-top: 8px;
}

.submit-btn.buy { background: #ff4d4f; }
.submit-btn.sell { background: #00b578; }

.footer-note {
  justify-content: center;
  border-bottom: none;
  font-size: 10.5px;
  color: var(--k-text-tertiary);
}

.tkp-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>
