<template>
  <div class="page">
    <div class="banner">Web 试点（P0）：只读快照 · 写操作桥接属 P1</div>

    <div v-if="!bridgeAvailable" class="card warn">
      非桥接环境（PC 浏览器开发调试）：以下为占位数据，桥接探针不可用
    </div>

    <div class="card">
      <div class="card-title">版本信息</div>
      <div class="row"><span>App 版本</span><b>{{ snap.version }} ({{ snap.build }})</b></div>
      <div class="row"><span>Web 构建</span><b>{{ buildTs }}</b></div>
    </div>

    <div class="card">
      <div class="card-title">显示主题</div>
      <div class="row"><span>主题偏好</span><b>{{ themePreferenceTitle }}</b></div>
      <div class="row"><span>实际外观</span><b>{{ themeMode === 'dark' ? '夜间' : '日间' }}</b></div>
    </div>

    <div class="card">
      <div class="card-title">行情自动更新</div>
      <div class="row"><span>状态</span><b>{{ snap.syncEnabled ? '开启' : '关闭' }}</b></div>
      <div class="row"><span>时刻表</span><b>{{ scheduleText }}</b></div>
      <div class="row"><span>仅交易日</span><b>{{ snap.tradingDaysOnly ? '是' : '否' }}</b></div>
    </div>

    <div class="card">
      <div class="card-title">数据库</div>
      <div class="row"><span>主库状态</span><b :class="{ ok: snap.dbLoaded }">{{ snap.dbLoaded ? '已加载' : '未加载' }}</b></div>
    </div>

    <div class="card">
      <div class="card-title">桥接探针</div>
      <div class="row"><span>桥接通道</span><b>{{ bridgeAvailable ? 'kline ✓' : '不可用' }}</b></div>
      <div class="row">
        <span>往返延迟</span>
        <b>{{ rttMs >= 0 ? rttMs.toFixed(1) + ' ms' : '—' }}</b>
      </div>
      <div class="row">
        <span>内存足迹</span>
        <b>{{ memMB >= 0 ? memMB.toFixed(1) + ' MB' : '—' }}</b>
      </div>
    </div>

    <div class="footer">Kline 混合架构 · Swift 原生宿主 + Vue3 视图层 · 协议 v1</div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { KnownEvents } from '../types/protocol'

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

const themePreferenceTitle = computed(
  () => ({ system: '跟随系统', light: '日间模式', dark: '夜间模式' }[themePreference.value] ?? themePreference.value),
)
const scheduleText = computed(() => (snap.scheduleTimes.length ? snap.scheduleTimes.join(' / ') : '—'))

let pingTimer: number | undefined

function applyTheme(t: { preference?: unknown; mode?: unknown }): void {
  if (typeof t.preference === 'string') themePreference.value = t.preference
  if (typeof t.mode === 'string') themeMode.value = t.mode
  document.documentElement.setAttribute('data-theme', themeMode.value === 'dark' ? 'dark' : 'light')
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

  // 环境自报（桥接排障）：window.klineBus 挂载形态 + 通道可用性，落 Swift debug_log
  void klineBus
    .request('app', 'jsdiag', {
      hasWindowBus: typeof (window as any).klineBus,
      hasWebkitHandler: klineBus.isAvailable(),
      buildTs,
    })
    .catch(() => {})

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

.card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 14px 16px;
  margin-bottom: 14px;
}

.card.warn {
  font-size: 13px;
  color: #b25000;
}

.card-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text-secondary);
  padding-bottom: 8px;
  border-bottom: 1px solid var(--k-divider);
  margin-bottom: 4px;
}

.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  min-height: 40px;
  font-size: 15px;
  color: var(--k-text);
}

.row span {
  color: var(--k-text-secondary);
}

.row b {
  font-weight: 500;
}

.row b.ok {
  color: var(--k-ok);
}

.footer {
  text-align: center;
  font-size: 11px;
  color: var(--k-text-secondary);
  padding-top: 8px;
}
</style>
