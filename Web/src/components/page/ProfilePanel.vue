<template>
  <div class="ppp">
    <div class="nav-line">
      <button class="nav-link" aria-label="profile.back" @click="emit('close')">‹ 返回</button>
      <span class="nav-center">个人中心</span>
      <span class="nav-side"></span>
    </div>

    <div class="ppp-body" v-if="snap">
      <div class="avatar">👤</div>
      <div class="user-name">Kline 用户</div>
      <div class="user-meta">v{{ snap.version }} ({{ snap.build }})</div>

      <div class="info-card">
        <div class="info-row"><span>主库状态</span><span :class="snap.dbLoaded ? 'ok' : 'warn'">{{ snap.dbLoaded ? '已加载' : '加载中' }}</span></div>
        <div class="info-row"><span>同步调度</span><span>{{ syncScheduleText }}</span></div>
        <div class="info-row"><span>仅交易日</span><span>{{ snap.tradingDaysOnly ? '是' : '否' }}</span></div>
      </div>

      <!-- 显示主题 -->
      <div class="entry-card">
        <div class="entry-row">
          <span class="entry-title">显示主题</span>
          <span class="entry-value">{{ themeText }}</span>
        </div>
        <div class="theme-chips" aria-label="profile.theme">
          <button
            v-for="t in themes"
            :key="t.value"
            class="mini-chip"
            :class="{ on: preference === t.value }"
            @click="setTheme(t.value)"
          >{{ t.title }}</button>
        </div>
      </div>

      <!-- 公式管理 -->
      <button class="entry-card row" aria-label="profile.formulaCenter" @click="openFormulaCenter">
        <span class="entry-title">公式管理</span>
        <span class="chev">›</span>
      </button>

      <!-- 本地更新 -->
      <button class="entry-card row" aria-label="profile.localUpdate.entry" @click="openPage('localUpdate')">
        <span class="entry-title">本地更新</span>
        <span class="chev">›</span>
      </button>

      <!-- 联机同步 -->
      <button class="entry-card row" aria-label="profile.lansync.entry" @click="openPage('lanSync')">
        <span class="entry-title">联机同步</span>
        <span class="chev">›</span>
      </button>

      <!-- Python 引擎实验室 -->
      <button class="entry-card row" aria-label="profile.pythonLab.entry" @click="openPage('pythonLab')">
        <span class="entry-title">Python 引擎实验室</span>
        <span class="chev">›</span>
      </button>

      <div style="height: 16px"></div>
    </div>
    <div v-else class="ppp-loading">加载中…</div>
  </div>
</template>

<script setup lang="ts">
// P2-9b：个人中心 Web 版（profile 页）。数据复用 profile.snapshot（协议 v2 既有动作）；
// 主题走 theme.get/set（theme.changed 广播全实例跟随）；本地更新/联机同步/引擎实验室
// 入口在同一切换 WebView 内 activeName 切换；公式管理桥原生公式中心（sheet 弹层 + 全屏中心）。
import { computed, onMounted, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { ProfileSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<ProfileSnapshot | null>(null)
const preference = ref('system')

const themes = [
  { value: 'system', title: '跟随系统' },
  { value: 'light', title: '日间' },
  { value: 'dark', title: '夜间' },
]

const themeText = computed(() => themes.find((t) => t.value === preference.value)?.title ?? '跟随系统')

const syncScheduleText = computed(() =>
  snap.value?.syncEnabled ? (snap.value.scheduleTimes.join(' / ') || '已启用') : '未启用')

async function pullSnapshot(): Promise<void> {
  try {
    snap.value = ((await klineBus.request('profile', 'snapshot')) ?? {}) as unknown as ProfileSnapshot
  } catch (e) {
    console.error('profile.snapshot 失败', e)
  }
  try {
    const t = (await klineBus.request('theme', 'get')) as Record<string, unknown>
    preference.value = String(t?.preference ?? 'system')
  } catch { /* 主题读取失败保持默认 */ }
}

async function setTheme(value: string): Promise<void> {
  preference.value = value
  try {
    await klineBus.request('theme', 'set', { preference: value })
    // theme.changed 广播全部 WebView 实例（含本页），深浅色即时切换
  } catch (e) {
    console.error('theme.set 失败', e)
  }
}

/** 公式管理：桥原生公式中心（tech 段 = Web 弹层面板；picker/strategy = 原生全屏中心） */
function openFormulaCenter(): void {
  void klineBus.request('sheet', 'close', {}).catch(() => {})
  void klineBus.request('chart', 'formula.openCenter', {}).catch((e) => console.error(e))
  emit('close')
}

/** 全屏 Web 页入口：请求原生切换 activePage（同 WebView 内 page.open 驱动切换，无缝） */
function openPage(name: string): void {
  void klineBus.request('page', 'open', { name }).catch((e) => console.error(e))
}

onMounted(async () => {
  await pullSnapshot()
})
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 56px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 20px;
  cursor: pointer;
  padding: 8px 12px;
  min-height: 44px;
}

.nav-center {
  flex: 1;
  font-size: 20px;
  font-weight: 700;
  color: var(--k-text);
  padding-left: 4px;
}

.nav-side { width: 60px; }

.ppp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.ppp-body {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
}

.avatar {
  font-size: 64px;
  text-align: center;
  padding: 8px 0 4px;
}

.user-name {
  font-size: 20px;
  font-weight: 700;
  text-align: center;
}

.user-meta {
  font-size: 13px;
  color: var(--k-text-secondary);
  text-align: center;
  margin: 4px 0 16px;
}

.info-card, .entry-card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 6px 16px;
  margin-bottom: 14px;
}

.entry-card.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 52px;
  width: 100%;
  border: none;
  cursor: pointer;
  text-align: left;
  color: var(--k-text);
  font-size: 16px;
  padding: 6px 16px;
}

.entry-title { font-size: 16px; }

.entry-value { font-size: 14px; color: var(--k-text-secondary); }

.chev { color: var(--k-text-tertiary); font-size: 14px; }

.info-row {
  display: flex;
  justify-content: space-between;
  min-height: 44px;
  align-items: center;
  font-size: 14px;
  border-bottom: 0.5px solid var(--k-border);
}

.info-row:last-child { border-bottom: none; }

.info-row .ok { color: #00b578; }
.info-row .warn { color: #ff9500; }

.theme-chips {
  display: flex;
  gap: 8px;
  padding: 4px 0 10px;
}

.mini-chip {
  border: none;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 13px;
  height: 36px;
  padding: 0 14px;
  border-radius: 18px;
  cursor: pointer;
}

.mini-chip.on {
  background: var(--k-accent, #1989fa);
  color: #ffffff;
  font-weight: 600;
}

.ppp-loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: var(--k-text-tertiary);
}
</style>
