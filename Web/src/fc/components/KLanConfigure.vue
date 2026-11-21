<template>
  <div>
    <!-- ② configure：对端信息 + 6 类勾选（细粒度子项展开）+ 主库警示 + 开始拉取 -->
    <div class="card peer-info">
      <span class="peer-icon">(((•)))</span>
      <div class="peer-text">
        <div class="peer-name">{{ modelValue.peer.name }}</div>
        <div class="peer-host">{{ modelValue.peer.host }}:{{ modelValue.peer.port }} · {{ modelValue.peer.appVersion }}</div>
      </div>
    </div>

    <div class="sec-label">获取内容（对端 → 本机）</div>
    <div class="card cats">
      <template v-for="(cat, idx) in modelValue.categories" :key="cat.key">
        <div class="cat-row">
          <button class="cat-main" :aria-label="'lansync.category.' + cat.key" @click="emit('toggleCategory', cat.key)">
            <span class="pick" :class="pickClass(cat)">{{ pickGlyph(cat) }}</span>
            <div class="cat-text">
              <div class="cat-title">{{ cat.title }}</div>
              <div class="cat-sub">本机 {{ cat.localSummary }} ｜ 对端 {{ cat.remoteSummary }}</div>
            </div>
          </button>
          <button
            v-if="cat.hasChildren"
            class="cat-expand"
            :aria-label="'lansync.expand.' + cat.key"
            @click="emit('toggleExpand', cat.key)"
          >{{ modelValue.expanded[cat.key] ? '▾' : '›' }}</button>
        </div>
        <template v-if="cat.hasChildren && modelValue.expanded[cat.key]">
          <button
            v-for="c in cat.children"
            :key="c.key"
            class="child-row"
            :aria-label="'lansync.child.' + cat.key + '.' + c.key"
            @click="emit('toggleChild', cat.key, c.key)"
          >
            <span class="pick small" :class="childChecked(cat, c) ? 'all' : 'none'">{{ childChecked(cat, c) ? '✓' : '' }}</span>
            <span class="child-name">{{ c.name }}</span>
            <span class="child-qty">{{ c.quantity }}</span>
          </button>
        </template>
        <div v-if="idx < modelValue.categories.length - 1" class="divider"></div>
      </template>
    </div>

    <div v-if="pickOf('main') === 'all'" class="warn-card">
      ⚠ 主库约 GB 级，WiFi 传输耗时较长；替换后需重启 App 生效
    </div>
    <div class="warn-card">
      ℹ 指标缓存（indicator_cache.db，GB 级）不支持 WiFi 同步：请保持设备 USB 连接 Mac，
      在 Mac 终端运行 <b>scripts/kline_sync_cache_usb.sh</b>（5GB 约 1 分钟，组合定义随库同步）。
    </div>

    <button class="primary-btn" aria-label="lansync.start" :disabled="!hasAnyPick" @click="emit('start')">开始拉取</button>
  </div>
</template>

<script setup lang="ts">
// k-lan-configure：联机同步 configure 子页（对端信息/类别勾选树/警示卡/开始拉取）。
// 哑组件：picks/expanded 状态由 adapter 维护；toggleCategory/toggleChild/toggleExpand/
// start 抛给 adapter（勾选语义对齐原生 CategoryPick）。
import { computed } from 'vue'

export interface LanCategory {
  key: string
  title: string
  localSummary: string
  remoteSummary: string
  hasChildren: boolean
  children: { key: string; name: string; quantity: string }[]
}

export interface LanConfigureState {
  peer: { name: string; host: string; port: number; appVersion: string }
  categories: LanCategory[]
  picks: Record<string, 'none' | 'all' | string[]>
  expanded: Record<string, boolean>
}

const props = withDefaults(defineProps<{
  modelValue?: LanConfigureState
}>(), {
  modelValue: () => ({
    peer: { name: '', host: '', port: 0, appVersion: '' },
    categories: [],
    picks: {},
    expanded: {},
  }),
})

const emit = defineEmits<{
  (e: 'toggleCategory', catKey: string): void
  (e: 'toggleChild', catKey: string, childKey: string): void
  (e: 'toggleExpand', catKey: string): void
  (e: 'start'): void
}>()

function pickOf(catKey: string): 'none' | 'all' | string[] {
  return props.modelValue.picks[catKey] ?? 'none'
}

function pickClass(cat: LanCategory): string {
  const p = pickOf(cat.key)
  if (p === 'all') return 'all'
  if (Array.isArray(p) && p.length > 0) return 'mixed'
  return 'none'
}

function pickGlyph(cat: LanCategory): string {
  const p = pickOf(cat.key)
  if (p === 'all') return '✓'
  if (Array.isArray(p) && p.length > 0) return '–'
  return ''
}

function childChecked(cat: LanCategory, child: { key: string }): boolean {
  const p = pickOf(cat.key)
  if (p === 'all') return true
  return Array.isArray(p) && p.includes(child.key)
}

const hasAnyPick = computed(() =>
  Object.values(props.modelValue.picks).some((p) => p === 'all' || (Array.isArray(p) && p.length > 0)))
</script>

<style scoped>
.card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  margin-bottom: 10px;
}

.sec-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text-secondary, #6c6c70);
  padding: 10px 2px 6px;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 16px;
}

.peer-info {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 48px;
  padding: 0 16px;
}

.peer-icon {
  color: var(--k-accent, #007aff);
  font-size: 13px;
  flex-shrink: 0;
}

.peer-text { flex: 1; min-width: 0; }

.peer-name {
  font-size: 16px;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.peer-host {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  margin-top: 3px;
}

.cat-row {
  display: flex;
  align-items: center;
}

.cat-main {
  flex: 1;
  display: flex;
  align-items: center;
  gap: 12px;
  border: none;
  background: none;
  min-height: 56px;
  padding: 0 0 0 16px;
  cursor: pointer;
  text-align: left;
  color: var(--k-text, #000);
}

.cat-text { flex: 1; min-width: 0; }

.cat-title {
  font-size: 16px;
  color: var(--k-text, #000);
}

.cat-sub {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
  margin-top: 3px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.cat-expand {
  width: 52px;
  height: 56px;
  border: none;
  background: none;
  color: var(--k-text-tertiary, #c7c7cb);
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}

.pick {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: 1.5px solid var(--k-text-tertiary, #c7c7cb);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  color: transparent;
  flex-shrink: 0;
}

.pick.all,
.pick.mixed {
  border-color: var(--k-accent, #007aff);
  background: var(--k-accent, #007aff);
  color: #ffffff;
}

.pick.small {
  width: 18px;
  height: 18px;
  font-size: 11px;
}

.child-row {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  border: none;
  background: none;
  min-height: 40px;
  padding: 0 16px 0 48px;
  cursor: pointer;
  text-align: left;
  color: var(--k-text, #000);
}

.child-name {
  flex: 1;
  font-size: 14px;
  color: var(--k-text, #000);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.child-qty {
  font-size: 12px;
  color: var(--k-text-secondary, #6c6c70);
}

.warn-card {
  background: rgba(255, 204, 0, 0.15);
  border-radius: 12px;
  padding: 12px;
  font-size: 13px;
  color: var(--k-text, #000);
  margin-bottom: 10px;
}

.primary-btn {
  width: 100%;
  min-height: 48px;
  border: none;
  border-radius: 12px;
  background: var(--k-accent, #007aff);
  color: #ffffff;
  font-size: 17px;
  font-weight: 600;
  cursor: pointer;
}

.primary-btn:disabled {
  opacity: 0.35;
  cursor: default;
}
</style>
