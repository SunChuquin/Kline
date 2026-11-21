<template>
  <template v-if="groups.length > 0">
    <div v-for="g in groups" :key="g.id" class="card">
      <div class="card-title">{{ g.name }}</div>
      <div v-for="item in g.items" :key="item.draftID" class="draft-row">
        <div class="draft-name">{{ item.name }} {{ item.code }}</div>
        <div class="draft-sentence">{{ item.kindTitle }} · {{ item.sentence }}</div>
      </div>
    </div>
  </template>
  <div v-else class="card">
    <div class="card-title">将生成的条件单</div>
    <div class="card-sub">没有可生成的条件单，请看下方跳过原因</div>
  </div>
</template>

<script setup lang="ts">
// k-draft-groups：生成确认草稿分组卡（按账户分组渲染草稿行；
// groups 为空时显示占位引导卡，对齐原生 StrategyGenConfirmView）。
import { computed } from 'vue'

export interface DraftGroup {
  id: string
  name: string
  items: { draftID: string; name: string; code: string; kindTitle: string; sentence: string }[]
}

const props = withDefaults(defineProps<{
  modelValue?: { groups?: DraftGroup[] }
}>(), {
  modelValue: () => ({}),
})

const groups = computed(() => props.modelValue.groups ?? [])
</script>

<style scoped>
.card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 14px;
}

.card-title {
  font-size: 13px;
  font-weight: 600;
  margin-bottom: 8px;
}

.card-sub {
  font-size: 11px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-top: 4px;
}

.draft-row {
  padding: 4px 0;
}

.draft-name {
  font-size: 13px;
  font-weight: 500;
  color: var(--k-text, #000);
}

.draft-sentence {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-top: 2px;
}
</style>
