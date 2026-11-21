<template>
  <div class="tkp">
    <!-- 页头：模拟下单 ｜ 标的 ｜ 关闭（对齐 SimFullScreenTicket） -->
    <div class="nav-line">
      <span class="nav-title">模拟下单</span>
      <span class="nav-meta">{{ metaText }}</span>
      <button class="nav-x" aria-label="ticket.close" @click="emit('close')">✕</button>
    </div>

    <div class="tkp-body" v-if="loaded">
      <!-- 账户信息 -->
      <div class="acct-line">
        <span class="acct-name">{{ acctName }}</span>
        <span class="acct-cash">可用 {{ acctCashText }}</span>
      </div>

      <!-- 方向 -->
      <div class="seg-dir">
        <button class="dir-btn buy" :class="{ on: modelValue.direction === 'buy' }" @click="set({ direction: 'buy' })">买入</button>
        <button class="dir-btn sell" :class="{ on: modelValue.direction === 'sell' }" @click="set({ direction: 'sell' })">卖出</button>
      </div>

      <!-- 报价类型 -->
      <div class="seg-price">
        <button class="pt-btn" :class="{ on: modelValue.priceType === 'limit' }" @click="set({ priceType: 'limit' })">限价</button>
        <button class="pt-btn" :class="{ on: modelValue.priceType === 'market' }" @click="set({ priceType: 'market' })">市价</button>
      </div>

      <!-- 委托价 / 数量 -->
      <label class="t-line">
        <span>委托价</span>
        <input
          class="t-input"
          inputmode="decimal"
          :disabled="modelValue.priceType === 'market'"
          :value="modelValue.priceText"
          :placeholder="modelValue.priceType === 'market' ? '市价' : ''"
          @input="set({ priceText: ($event.target as HTMLInputElement).value })"
        />
        <span class="t-unit">元</span>
      </label>
      <label class="t-line">
        <span>数量</span>
        <input
          class="t-input"
          inputmode="numeric"
          :value="modelValue.qtyText"
          placeholder="0"
          @input="set({ qtyText: ($event.target as HTMLInputElement).value })"
        />
        <span class="t-unit">股</span>
      </label>

      <!-- 仓位快捷（买入按现金可买整手、卖出按可卖） -->
      <div class="pos-chips" aria-label="ticket.positionChips">
        <button v-for="r in [0.25, 0.5, 0.75, 1]" :key="r" class="pos-chip" @click="emit('position', r)">{{ r * 100 }}%</button>
      </div>

      <!-- 可买 / 可卖提示（按费率纯算术，文案由 adapter 注入） -->
      <div class="avail-line" v-if="showAvail">
        <span>{{ availText }}</span>
      </div>

      <!-- 费用与委托后可用资金 -->
      <div class="fee-block" v-if="feeText">
        <div class="fee-line"><span>预计费用合计</span><span>{{ feeText }}</span></div>
        <div class="fee-line" v-if="cashAfterText"><span>委托后可用资金</span><span>{{ cashAfterText }}</span></div>
      </div>

      <div v-if="error" class="tkp-error">{{ error }}</div>

      <!-- 提交 -->
      <button
        class="submit-btn"
        :class="modelValue.direction"
        aria-label="ticket.submit"
        @click="emit('submit')"
      >{{ modelValue.direction === 'buy' ? '买入' : '卖出' }} {{ modelValue.priceType === 'limit' ? '限价' : '市价' }}</button>
      <div class="t-line footer-note">提交统一走模拟账户校验与写入；失败原因就地展示</div>
    </div>

    <div v-else class="tkp-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// k-ticket-form：全屏下单票面（page-ticket 主体）。票面状态为一个字段值；
// 可买可卖/费用文案由 adapter 按 snapshot 费率纯算术计算后经 props 注入；
// submit/position/close 抛给 adapter（本地预检 + trade.submit + 卖出二次确认）。
export interface TicketFormState {
  direction: 'buy' | 'sell'
  priceType: 'limit' | 'market'
  priceText: string
  qtyText: string
}

const props = withDefaults(defineProps<{
  modelValue?: TicketFormState
  loaded?: boolean
  metaText?: string
  acctName?: string
  acctCashText?: string
  showAvail?: boolean
  availText?: string
  feeText?: string
  cashAfterText?: string
  error?: string
}>(), {
  modelValue: () => ({ direction: 'buy', priceType: 'limit', priceText: '', qtyText: '' }),
  loaded: false,
  metaText: '',
  acctName: '',
  acctCashText: '',
  showAvail: false,
  availText: '',
  feeText: '',
  cashAfterText: '',
  error: '',
})

const emit = defineEmits<{
  (e: 'update:modelValue', v: TicketFormState): void
  (e: 'submit'): void
  (e: 'position', ratio: number): void
  (e: 'close'): void
}>()

function set(patch: Partial<TicketFormState>): void {
  emit('update:modelValue', { ...props.modelValue, ...patch })
}
</script>

<style scoped>
.tkp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

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
