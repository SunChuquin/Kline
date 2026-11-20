<template>
  <div class="shp">
    <div class="search-top">
      <button class="sh-x" aria-label="search.close" @click="emit('close')">✕</button>
      <van-search
        v-model="keyword"
        class="sh-field"
        placeholder="搜索代码/名称"
        shape="round"
        @update:model-value="onKeyword"
      />
      <button v-if="keyword" class="sh-clear" @click="keyword = ''; results = []">⊗</button>
    </div>
    <div class="sh-results">
      <div v-if="results.length === 0 && keyword" class="sh-empty">没有匹配的标的</div>
      <div
        v-for="(r, i) in results"
        :key="r.file"
        class="sh-row"
        :aria-label="`search.row.${i}`"
        @click="pick(r)"
      >
        <span class="sr-name">{{ r.name }}</span>
        <span class="sr-code">{{ r.code }}</span>
        <span class="sr-type">{{ r.type }}</span>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// P2-9b：搜索页 Web 版（search）。query 与 chart.search.query 同口径（searchMeta）；
// 选中进 K 线详情（原生关页 + DetailRouter）。
import { onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { ChartSearchResult } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const keyword = ref('')
const results = ref<ChartSearchResult[]>([])
let searchTimer: ReturnType<typeof setTimeout> | null = null

function onKeyword(): void {
  if (searchTimer) clearTimeout(searchTimer)
  searchTimer = setTimeout(() => void runSearch(), 300)
}

async function runSearch(): Promise<void> {
  const kw = keyword.value.trim()
  if (!kw) {
    results.value = []
    return
  }
  try {
    const s = ((await klineBus.request('search', 'query', { keyword: kw })) ?? {}) as Record<string, unknown>
    results.value = (Array.isArray(s.results) ? s.results : []) as ChartSearchResult[]
  } catch (e) {
    console.error('search.query 失败', e)
  }
}

function pick(r: ChartSearchResult): void {
  // 原生 openDetail 成功后自动关搜索页并进详情
  void klineBus.request('search', 'openDetail', { file: r.file }).catch((e) => console.error(e))
  keyword.value = ''
  results.value = []
}
</script>

<style scoped>
.shp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.search-top {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.sh-x {
  width: 32px;
  height: 32px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  flex-shrink: 0;
}

.sh-field {
  flex: 1;
  padding: 0;
  background: none;
}

.sh-clear {
  width: 28px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 14px;
  cursor: pointer;
}

.sh-results {
  flex: 1;
  overflow-y: auto;
}

.sh-empty {
  font-size: 13px;
  color: var(--k-text-tertiary);
  padding: 16px;
  text-align: center;
}

.sh-row {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 16px;
  cursor: pointer;
  border-bottom: 0.5px solid var(--k-border);
  min-height: 44px;
}

.sr-name {
  font-size: 14px;
  color: var(--k-text);
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sr-code {
  font-size: 12px;
  color: var(--k-text-secondary);
  flex-shrink: 0;
}

.sr-type {
  font-size: 11px;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}
</style>
