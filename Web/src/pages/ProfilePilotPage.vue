<template>
  <div class="page">
    <div class="banner">Web 试点：只读快照 + 组件库验收（P1）</div>

    <div v-if="!bridgeAvailable" class="card-warn">
      非桥接环境（PC 浏览器开发调试）：以下为占位数据，桥接探针不可用
    </div>

    <KCard title="版本信息">
      <KCell label="App 版本" :value="snap.version + ' (' + snap.build + ')'" />
      <KCell label="Web 构建" :value="buildTs" />
    </KCard>

    <KCard title="显示主题">
      <KCell label="主题偏好">
        <template #value>
          <KSelect v-model="themePreference" :options="themeOptions" @change="setTheme" />
        </template>
      </KCell>
      <KCell label="实际外观" :value="themeMode === 'dark' ? '夜间' : '日间'" />
    </KCard>

    <KCard title="行情自动更新">
      <KCell label="状态" :value="snap.syncEnabled ? '开启' : '关闭'" />
      <KCell label="时刻表" :value="scheduleText" />
      <KCell label="仅交易日" :value="snap.tradingDaysOnly ? '是' : '否'" />
    </KCard>

    <KCard title="数据库">
      <KCell label="主库状态">
        <template #value>
          <b :class="{ ok: snap.dbLoaded }">{{ snap.dbLoaded ? '已加载' : '未加载' }}</b>
        </template>
      </KCell>
    </KCard>

    <KCard title="桥接探针">
      <KCell label="桥接通道" :value="bridgeAvailable ? 'kline ✓' : '不可用'" />
      <KCell label="往返延迟">
        <template #value><b>{{ rttMs >= 0 ? rttMs.toFixed(1) + ' ms' : '—' }}</b></template>
      </KCell>
      <KCell label="内存足迹">
        <template #value><b>{{ memMB >= 0 ? memMB.toFixed(1) + ' MB' : '—' }}</b></template>
      </KCell>
    </KCard>

    <div class="footer">Kline 混合架构 · Swift 原生宿主 + Vue3 视图层 · 协议 v2</div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { KnownEvents } from '../types/protocol'
import KCard from '../components/kline/KCard.vue'
import KCell from '../components/kline/KCell.vue'
import KSelect from '../components/kline/KSelect.vue'

const buildTs = __BUILD_TS__
const bridgeAvailable = ref(true)
const rttMs = ref(-1)
const memMB = ref(-1)
const themePreference = ref('system')
const themeMode = ref('light')
const snap = reactive({
  version: '—',
  build: '—',
  syncEnabled: false,
  scheduleTimes: [] as string[],
  tradingDaysOnly: true,
  dbLoaded: false,
})

// 主题写回（协议 v2 theme.set）：写回后状态由 theme.changed 事件回推，不乐观更新
const themeOptions = [
  { label: '跟随系统', value: 'system' },
  { label: '日间模式', value: 'light' },
  { label: '夜间模式', value: 'dark' },
]

const scheduleText = computed(() => (snap.scheduleTimes.length ? snap.scheduleTimes.join(' / ') : '—'))

let pingTimer: number | undefined

function applyTheme(t: { preference?: unknown; mode?: unknown }): void {
  if (typeof t.preference === 'string') themePreference.value = t.preference
  if (typeof t.mode === 'string') themeMode.value = t.mode
  document.documentElement.setAttribute('data-theme', themeMode.value === 'dark' ? 'dark' : 'light')
}

async function setTheme(value: string | number): Promise<void> {
  try {
    await klineBus.request('theme', 'set', { preference: String(value) })
    // 写回成功：不在此更新本地状态，等 theme.changed 事件回推（写回模式 v2 单一数据流）
  } catch (e) {
    // 写回失败：回读真实主题纠正选择（不发额外事件，纯请求）
    console.error('主题写回失败', e)
    klineBus
      .request('theme', 'get')
      .then((t) => applyTheme((t ?? {}) as Record<string, unknown>))
      .catch(() => {})
  }
}

async function pingOnce(): Promise<void> {
  const started = performance.now()
  try {
    await klineBus.request('app', 'ping', { clientTs: started })
    const rtt = performance.now() - started
    rttMs.value = rtt
    // 顺带把页面实测 RTT 报给原生侧落 debug_log（验收证据）
    klineBus.request('app', 'reportRtt', { rttMs: rtt }).catch(() => {})
  } catch {
    // 探针失败静默：顶部 banner 已提示桥接不可用
  }
}

onMounted(async () => {
  if (!klineBus.isAvailable()) {
    bridgeAvailable.value = false
    return
  }

  klineBus.on(KnownEvents.themeChanged, (e) => applyTheme((e.payload ?? {}) as Record<string, unknown>))
  klineBus.on(KnownEvents.appMemory, (e) => {
    const mb = Number((e.payload ?? {})['footprintMB'])
    if (!Number.isNaN(mb)) memMB.value = mb
  })

  try {
    applyTheme(((await klineBus.request('theme', 'get')) ?? {}) as Record<string, unknown>)
  } catch {
    // 主题读取失败保持默认
  }

  try {
    const s = ((await klineBus.request('profile', 'snapshot')) ?? {}) as Record<string, unknown>
    snap.version = typeof s.version === 'string' ? s.version : '—'
    snap.build = typeof s.build === 'string' ? s.build : '—'
    snap.syncEnabled = s.syncEnabled === true
    snap.scheduleTimes = Array.isArray(s.scheduleTimes) ? (s.scheduleTimes as string[]) : []
    snap.tradingDaysOnly = s.tradingDaysOnly !== false
    snap.dbLoaded = s.dbLoaded === true
  } catch {
    // 快照失败保持占位
  }

  void pingOnce()
  pingTimer = window.setInterval(() => void pingOnce(), 5000)
})

onUnmounted(() => {
  if (pingTimer !== undefined) window.clearInterval(pingTimer)
})
</script>

<style scoped>
.page {
  min-height: 100vh;
  padding: 14px 16px 24px;
  background: var(--k-bg);
}

.banner {
  font-size: 12px;
  color: var(--k-text-secondary);
  padding: 8px 0 14px;
}

.card-warn {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 14px 16px;
  margin-bottom: 14px;
  font-size: 13px;
  color: #b25000;
}

/* 卡片纵向间距 */
.page > :deep(.k-card) {
  margin-bottom: 14px;
}

b {
  font-weight: 500;
  color: var(--k-text);
}

b.ok {
  color: var(--k-ok);
}

.footer {
  text-align: center;
  font-size: 11px;
  color: var(--k-text-secondary);
  padding-top: 8px;
}
</style>
