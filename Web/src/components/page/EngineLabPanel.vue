<template>
  <div class="elp">
    <!-- 顶部返回栏（对齐原生 PythonEngineLabView） -->
    <div class="nav-bar">
      <button class="nav-back" aria-label="page.back" @click="emit('close')">‹</button>
      <span class="nav-title">Python 引擎实验室</span>
    </div>

    <div class="elp-body">
      <!-- 状态区 -->
      <div class="sec-label">引擎状态</div>
      <div class="card">
        <button class="row" :disabled="!!snap?.isBusy" @click="act('refresh')">
          <span class="row-title">刷新状态</span>
          <span class="st-icon state-blue">⟳</span>
        </button>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">当前状态</span>
          <span class="row-value status-value" :class="statusClass">{{ snap?.statusText ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">引擎来源</span>
          <span class="row-value">{{ snap?.source ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">引擎路径</span>
          <span class="row-value path-value">{{ snap?.appPath ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">引擎版本</span>
          <span class="row-value">{{ snap?.manifest ?? '—' }}</span>
        </div>
        <div class="divider"></div>
        <div class="row">
          <span class="row-title">解释器</span>
          <span class="row-value" :class="{ 'tone-green': snap?.isLoaded }">
            {{ snap?.isLoaded ? '已加载（进程内常驻）' : '未加载' }}
          </span>
        </div>
      </div>

      <!-- 忙指示（说明当前阶段 + 下载进度，避免用户以为卡死） -->
      <div v-if="snap?.isBusy" class="busy-hint">
        ◌ {{ snap?.busyText }}
        <span v-if="snap?.busyText.startsWith('下载引擎包')" class="busy-pct">{{ snap?.downloadPercent }}%</span>
      </div>

      <!-- 操作区（三段式：下载 → 安装 → 加载；实验①-④经 pyrunner 隔离执行） -->
      <div class="sec-label">操作</div>
      <div class="card">
        <button class="row" :disabled="!!snap?.isBusy" @click="act('download')">
          <span class="row-title" :class="{ dim: !!snap?.isBusy }">下载引擎包（.tipa）</span>
          <span v-if="downloading" class="st-icon state-yellow">{{ snap?.downloadPercent }}</span>
          <span v-else-if="snap?.isBusy" class="st-icon state-yellow">◌</span>
          <span v-else class="st-icon state-blue">⤓</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!!snap?.isBusy" @click="act('install')">
          <span class="row-title" :class="{ dim: !!snap?.isBusy }">用 TrollStore 安装</span>
          <span class="st-icon state-blue">▣</span>
        </button>
        <div class="divider"></div>
        <button
          class="row"
          :disabled="!loadEnabled"
          @click="act('loadEngine')"
        >
          <span class="row-title" :class="{ dim: !loadEnabled }">加载引擎（进程内 dlopen+init 计时）</span>
          <span v-if="loadingSpinner" class="st-icon state-yellow">◌</span>
          <span v-else class="st-icon" :class="loadEnabled ? 'state-blue' : 'state-gray'">▶</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!expEnabled(1)" @click="act('runExp', { id: 1 })">
          <span class="row-title" :class="{ dim: !expEnabled(1) }">实验① 最小脚本（隔离）</span>
          <span v-if="expSpinner(1)" class="st-icon state-yellow">◌</span>
          <span v-else class="st-icon" :class="expEnabled(1) ? 'state-blue' : 'state-gray'">①</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!expEnabled(2)" @click="act('runExp', { id: 2 })">
          <span class="row-title" :class="{ dim: !expEnabled(2) }">实验② 冷启动与150根计时（隔离）</span>
          <span v-if="expSpinner(2)" class="st-icon state-yellow">◌</span>
          <span v-else class="st-icon" :class="expEnabled(2) ? 'state-blue' : 'state-gray'">②</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!expEnabled(3)" @click="act('runExp', { id: 3 })">
          <span class="row-title" :class="{ dim: !expEnabled(3) }">实验③ 并发吞吐（隔离）</span>
          <span v-if="expSpinner(3)" class="st-icon state-yellow">◌</span>
          <span v-else class="st-icon" :class="expEnabled(3) ? 'state-blue' : 'state-gray'">③</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!expEnabled(4)" @click="act('runExp', { id: 4 })">
          <span class="row-title" :class="{ dim: !expEnabled(4) }">实验④ 首帧端到端（进程内桥接）</span>
          <span v-if="snap?.runningExp === 4" class="st-icon state-yellow">◌</span>
          <span v-else class="st-icon" :class="expEnabled(4) ? 'state-blue' : 'state-gray'">④</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!!snap?.isBusy" @click="act('cleanDownloads')">
          <span class="row-title" :class="{ dim: !!snap?.isBusy, danger: true }">清理下载文件</span>
          <span class="st-icon" :class="snap?.isBusy ? 'state-gray' : 'state-red'">✕</span>
        </button>
        <div class="divider"></div>
        <button class="row" :disabled="!!snap?.isBusy" @click="act('exportCrash')">
          <span class="row-title" :class="{ dim: !!snap?.isBusy }">导出崩溃报告</span>
          <span class="st-icon" :class="snap?.isBusy ? 'state-gray' : 'state-blue'">⤓</span>
        </button>
      </div>

      <div class="foot-note">
        流程：① 下载引擎包（.tipa + sha256 校验，落在 Documents/Downloads）→ ② 用 TrollStore 安装（安装时整包授信代码签名，装成 Engine.app）→ ③ 回本页「刷新状态」确认已安装后即可跑实验①②③。实验经 pyrunner 独立子进程执行 Python（root 拉起、进程隔离），引擎崩溃只死子进程，绝不影响本 App；超时多为子进程崩溃，stderr 见 Documents/py_runner_stderr.log。「加载引擎」仅为测量进程内 dlopen/Py_Initialize 计时，跑实验无需它。Engine.app 的卸载请在 TrollStore 内操作；「清理下载文件」只删除已下载的 tipa。
      </div>

      <!-- 结果输出区（等宽字体逐行展示，自动滚底） -->
      <div class="sec-label">结果输出</div>
      <div ref="outRef" class="out-console">
        <div v-if="(snap?.outputLines.length ?? 0) === 0" class="out-empty">（暂无输出）</div>
        <div v-for="(line, i) in snap?.outputLines ?? []" :key="i" class="out-line">{{ line }}</div>
      </div>
      <div style="height: 16px"></div>
    </div>
  </div>
</template>

<script setup lang="ts">
// Python 引擎实验室 Web 面板（P2-6c-1，对齐原生 PythonEngineLabView）：
// 引擎状态/实验编排/输出行全部原生（PythonEngineHost 单例），Web 经 lab.* 动作触发、
// lab.snapshot 消费（host.objectWillChange 节流推送刷新）。
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { LabSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<LabSnapshot | null>(null)
const outRef = ref<HTMLDivElement | null>(null)

async function pull(): Promise<void> {
  try {
    snap.value = (await klineBus.request('lab', 'snapshot')) as unknown as LabSnapshot
  } catch (e) {
    console.error('lab.snapshot 失败', e)
  }
}

function act(action: string, payload?: Record<string, unknown>): void {
  void klineBus.request('lab', action, payload)
    .then(() => pull())
    .catch((e) => console.error(`lab.${action} 失败`, e))
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('lab.changed', () => void pull())
  await pull()
})

// 输出行变化自动滚底（对齐原生 ScrollViewReader.scrollTo）
watch(() => snap.value?.outputLines.length ?? 0, async () => {
  await nextTick()
  outRef.value?.scrollTo({ top: outRef.value.scrollHeight })
})

// ===== 行启用/转圈语义（对齐原生 actionRow 的 enabled/showSpinner） =====

const downloading = computed(() =>
  !!snap.value?.isBusy && (snap.value?.busyText ?? '').startsWith('下载引擎包'))

const loadingSpinner = computed(() => {
  const t = snap.value?.busyText ?? ''
  return !!snap.value?.isBusy && (t.startsWith('dlopen') || t.startsWith('Py_Initialize'))
})

const loadEnabled = computed(() => {
  const s = snap.value
  return !!s && !s.isBusy && s.status === 'installed' && !s.isLoaded
})

function expEnabled(id: number): boolean {
  const s = snap.value
  if (!s) return false
  if (id <= 3) return !s.isBusy && s.status === 'installed'
  // 实验④：进程内桥接，要求引擎空闲且未在跑其它实验
  return !s.isBusy && s.runningExp === 0 && s.status === 'installed'
}

function expSpinner(id: number): boolean {
  const s = snap.value
  if (!s) return false
  if (id <= 3) return !!s.isBusy && s.busyText === 'pyrunner 运行脚本…' && s.runningExp === id
  return s.runningExp === 4
}

const statusClass = computed(() => {
  switch (snap.value?.status) {
    case 'installed': return 'tone-green'
    case 'versionMismatch': return 'tone-yellow'
    case 'corrupted': return 'tone-red'
    default: return ''
  }
})
</script>

<style scoped>
.elp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
}

.nav-bar {
  display: flex;
  align-items: center;
  height: 56px;
  flex-shrink: 0;
  background: var(--k-bg);
}

.nav-back {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 24px;
  cursor: pointer;
  margin-left: 8px;
}

.nav-title {
  font-size: 20px;
  font-weight: 700;
  color: var(--k-text);
}

.elp-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px;
  border-top: 0.5px solid var(--k-divider, #c6c6c8);
}

.sec-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text-secondary);
  padding: 10px 2px 6px;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  overflow: hidden;
  margin-bottom: 4px;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 16px;
}

.row {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 48px;
  padding: 0 16px;
  border: none;
  background: none;
  cursor: pointer;
  text-align: left;
  color: var(--k-text);
}

.row:disabled { cursor: default; }

.row-title {
  font-size: 16px;
  color: var(--k-text);
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.row-title.dim { color: var(--k-text-tertiary); }

.row-title.danger { color: #ff3b30; }

.row-value {
  font-size: 15px;
  color: var(--k-text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 62%;
  text-align: right;
}

.status-value {
  white-space: normal;
  line-height: 1.35;
}

.path-value {
  white-space: normal;
  word-break: break-all;
  line-height: 1.35;
  font-size: 12px;
}

.st-icon {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  font-weight: 600;
  flex-shrink: 0;
}

.state-gray { background: rgba(128, 128, 128, 0.2); color: #8e8e93; }
.state-yellow { background: rgba(255, 204, 0, 0.25); color: #cc9900; }
.state-green { background: rgba(52, 199, 89, 0.2); color: var(--k-ok); }
.state-red { background: rgba(255, 59, 48, 0.2); color: #ff3b30; }
.state-blue { background: rgba(0, 122, 255, 0.15); color: var(--k-accent); font-size: 16px; }

.tone-green { color: var(--k-ok); }
.tone-yellow { color: #cc9900; }
.tone-red { color: #ff3b30; }

.busy-hint {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 6px 4px;
}

.busy-pct {
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}

.foot-note {
  font-size: 12px;
  color: var(--k-text-secondary);
  line-height: 1.5;
  padding: 10px 4px;
}

.out-console {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 10px;
  max-height: 280px;
  overflow-y: auto;
  font-family: ui-monospace, Menlo, monospace;
}

.out-empty {
  font-size: 12px;
  color: var(--k-text-tertiary);
}

.out-line {
  font-size: 11px;
  color: var(--k-text-secondary);
  line-height: 1.5;
  word-break: break-all;
}
</style>
