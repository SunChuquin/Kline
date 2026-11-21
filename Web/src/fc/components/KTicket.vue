<template>
  <div class="ticket">
    <div class="ticket-seg">
      <button class="seg buy" :class="{ on: modelValue.direction === 'buy' }" :aria-label="'ticket.direction.buy'" @click="set({ direction: 'buy' })">买入</button>
      <button class="seg sell" :class="{ on: modelValue.direction === 'sell' }" :aria-label="'ticket.direction.sell'" @click="set({ direction: 'sell' })">卖出</button>
      <button class="seg" :aria-label="'ticket.priceType'" @click="set({ priceType: modelValue.priceType === 'limit' ? 'market' : 'limit' })">
        {{ modelValue.priceType === 'limit' ? '限价' : '市价' }}
      </button>
    </div>
    <label class="ticket-row">
      <span>委托价</span>
      <input
        class="ticket-input"
        inputmode="decimal"
        :disabled="modelValue.priceType === 'market'"
        :value="modelValue.priceText"
        :placeholder="modelValue.priceType === 'market' ? '市价' : String(lastPrice ?? '')"
        @input="set({ priceText: ($event.target as HTMLInputElement).value })"
      />
      <span class="unit">元</span>
    </label>
    <label class="ticket-row">
      <span>数量</span>
      <input class="ticket-input" inputmode="numeric" :value="modelValue.qtyText" placeholder="0" @input="set({ qtyText: ($event.target as HTMLInputElement).value })" />
      <span class="unit">股</span>
    </label>
    <div class="pos-chips">
      <button v-for="r in [0.25, 0.5, 0.75, 1]" :key="r" class="pos-chip" @click="emit('position', r)">{{ r * 100 }}%</button>
    </div>
    <div v-if="error" class="ticket-error">{{ error }}</div>
    <button class="submit-btn" :class="modelValue.direction === 'buy' ? 'buy' : 'sell'" :aria-label="'ticket.submit'" @click="emit('submit')">
      {{ modelValue.direction === 'buy' ? '买入' : '卖出' }} {{ modelValue.priceType === 'limit' ? '限价' : '市价' }}
    </button>
  </div>
</template>

<script setup lang="ts">
// k-ticket：下单票面（买卖 seg + 委托价/数量 + 仓位 chips + 提交按钮）。
// 表单输入语义：整个票面状态为一个字段值；submit/position 抛给 adapter 校验写回。
export interface TicketState {
  direction: 'buy' | 'sell'
  priceType: 'limit' | 'market'
  priceText: string
  qtyText: string
}

const props = withDefaults(defineProps<{
  modelValue?: TicketState
  lastPrice?: number | null
  error?: string
}>(), {
  modelValue: () => ({ direction: 'buy', priceType: 'limit', priceText: '', qtyText: '' }),
  lastPrice: null,
})

const emit = defineEmits<{
  (e: 'update:modelValue', v: TicketState): void
  (e: 'submit'): void
  (e: 'position', ratio: number): void
}>()

function set(patch: Partial<TicketState>): void {
  emit('update:modelValue', { ...props.modelValue, ...patch })
}
</script>

<style scoped>
.ticket {
  border: 0.5px solid var(--k-divider, #c6c6c8);
  border-radius: 10px;
  padding: 8px 10px;
  margin: 4px 0;
}

.ticket-seg {
  display: flex;
  gap: 2px;
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 7px;
  padding: 2px;
  margin-bottom: 8px;
}

.seg {
  flex: 1;
  border: none;
  border-radius: 5px;
  background: none;
  color: var(--k-text-secondary, #6c6c70);
  font-size: 13px;
  padding: 6px 0;
  cursor: pointer;
}

.seg.buy.on { background: #ff4d4f; color: #ffffff; font-weight: 700; }
.seg.sell.on { background: #00b578; color: #ffffff; font-weight: 700; }

.ticket-row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 36px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
}

.ticket-input {
  flex: 1;
  border: none;
  background: none;
  color: var(--k-text, #000);
  font-size: 15px;
  text-align: right;
  font-variant-numeric: tabular-nums;
  outline: none;
  min-width: 0;
}

.ticket-input:disabled { color: var(--k-text-secondary, #6c6c70); }

.unit { color: var(--k-text-tertiary, #c7c7cb); font-size: 12px; }

.pos-chips {
  display: flex;
  gap: 6px;
  padding: 8px 0;
}

.pos-chip {
  flex: 1;
  border: 1px solid var(--k-divider, #c6c6c8);
  border-radius: 6px;
  background: none;
  color: var(--k-text-secondary, #6c6c70);
  font-size: 11.5px;
  padding: 4px 0;
  cursor: pointer;
}

.ticket-error {
  font-size: 12px;
  color: #ee0a24;
  padding: 4px 0;
}

.submit-btn {
  width: 100%;
  border: none;
  border-radius: 9px;
  color: #ffffff;
  font-size: 15px;
  font-weight: 700;
  padding: 11px 0;
  cursor: pointer;
}

.submit-btn.buy { background: #ff4d4f; }
.submit-btn.sell { background: #00b578; }
</style>
