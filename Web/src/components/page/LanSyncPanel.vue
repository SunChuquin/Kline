<template>
  <div class="lp">
    <!-- 顶部返回栏（对齐原生 LANSyncView；传输/配对中禁用返回） -->
    <div class="nav-bar">
      <button class="nav-back" aria-label="page.back" :disabled="busy" @click="back">‹</button>
      <span class="nav-title">联机同步</span>
    </div>

    <div class="lp-body">
      <!-- ① devices：本机服务 / 暴露开关 / 扫描 / 已发现设备 / 手动直连 -->
      <template v-if="subPage === 'devices'">
        <div class="sec-label">本机服务</div>
        <div class="card" aria-label="lansync.local.status">
          <div class="svc-line">
            <span class="dot" :class="snap?.serverOnline ? 'on' : 'off'"></span>
            <span class="svc-state">{{ snap?.serverOnline ? '在线' : '离线' }}</span>
            <button class="svc-refresh" aria-label="lansync.probe" :disabled="snap?.probing" @click="act('probe')">
              {{ snap?.probing ? '⟳…' : '⟳' }}
            </button>
          </div>
          <div class="svc-sub">{{ snap?.deviceName ?? '—' }} · 端口 {{ snap?.port ?? '—' }}</div>
          <div class="svc-hint">对端设备需保持 Kline 在前台</div>
        </div>

        <div class="card expose-card">
          <div class="expose-text">
            <div class="expose-title">允许对端获取本机内容</div>
            <div class="expose-sub" :class="{ warm: snap?.isExposed }">
              {{ snap?.isExposed ? '已暴露：对端可扫描到本机并拉取其内容' : '已隐藏：不广播、不接受同步' }}
            </div>
          </div>
          <van-switch
            aria-label="lansync.expose.toggle"
            :model-value="snap?.isExposed ?? false"
            size="22px"
            @update:model-value="(v: boolean) => act('setExposed', { on: v })"
          />
        </div>

        <div class="sec-label">已发现设备</div>
        <button class="card scan-btn" aria-label="lansync.scan.once" :disabled="snap?.isBrowsing" @click="act('scan')">
          <span>⌕</span>
          <span>{{ snap?.isBrowsing ? '扫描中…' : '扫描一次' }}</span>
        </button>
        <div v-if="snap?.isBrowsing" class="card searching">◌ 正在搜索同网段设备…</div>
        <button
          v-for="(p, i) in snap?.peers ?? []"
          :key="p.id"
          class="card peer-card"
          :aria-label="'lansync.peer.' + i"
          :disabled="connecting"
          @click="act('connect', { peerId: p.id })"
        >
          <span class="peer-icon">(((•)))</span>
          <div class="peer-text">
            <div class="peer-name">{{ p.name }}</div>
            <div class="peer-host">{{ p.host }}:{{ p.port }}</div>
          </div>
          <span class="peer-chevron">{{ connecting ? '◌' : '›' }}</span>
        </button>

        <div class="sec-label">手动直连</div>
        <div class="card manual-card">
          <input
            v-model="manualAddress"
            class="manual-field"
            aria-label="lansync.manual.field"
            placeholder="对端 IP:端口，如 192.168.1.5:5051"
            autocapitalize="off"
            autocorrect="off"
          />
          <button class="manual-connect" aria-label="lansync.manual.connect" :disabled="connecting" @click="connectManual">
            {{ connecting ? '连接中' : '连接' }}
          </button>
        </div>
        <div class="foot-note">对端未出现在列表时可直接输入其 IP 与端口（缺省端口 5051）</div>
      </template>

      <!-- ② configure：对端信息 + 6 类勾选（细粒度子项展开）+ 主库警示 + 开始拉取 -->
      <template v-else-if="subPage === 'configure' && snap?.configure">
        <div class="card peer-info">
          <span class="peer-icon">(((•)))</span>
          <div class="peer-text">
            <div class="peer-name">{{ snap.configure.peer.name }}</div>
            <div class="peer-host">{{ snap.configure.peer.host }}:{{ snap.configure.peer.port }} · {{ snap.configure.peer.appVersion }}</div>
          </div>
        </div>

        <div class="sec-label">获取内容（对端 → 本机）</div>
        <div class="card cats">
          <template v-for="(cat, idx) in snap.configure.categories" :key="cat.key">
            <div class="cat-row">
              <button class="cat-main" :aria-label="'lansync.category.' + cat.key" @click="toggleCategory(cat)">
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
                @click="expanded[cat.key] = !expanded[cat.key]"
              >{{ expanded[cat.key] ? '▾' : '›' }}</button>
            </div>
            <template v-if="cat.hasChildren && expanded[cat.key]">
              <button
                v-for="c in cat.children"
                :key="c.key"
                class="child-row"
                :aria-label="'lansync.child.' + cat.key + '.' + c.key"
                @click="toggleChild(cat, c)"
              >
                <span class="pick small" :class="childChecked(cat, c) ? 'all' : 'none'">{{ childChecked(cat, c) ? '✓' : '' }}</span>
                <span class="child-name">{{ c.name }}</span>
                <span class="child-qty">{{ c.quantity }}</span>
              </button>
            </template>
            <div v-if="idx < snap.configure.categories.length - 1" class="divider"></div>
          </template>
        </div>

        <div v-if="pickOf('main') === 'all'" class="warn-card">
          ⚠ 主库约 GB 级，WiFi 传输耗时较长；替换后需重启 App 生效
        </div>
        <div v-if="pickOf('indicatorCache') !== 'none'" class="warn-card">
          ℹ 指标缓存按组合同步：勾选的组合其缓存行会合并到本机，同时**自动覆盖对应的组合定义**
          （保证缓存指纹与本机一致才能命中）；本机未勾选的组合不受影响，本机「局部独立配置」的定义也不会被覆盖。
        </div>

        <button class="primary-btn" aria-label="lansync.start" :disabled="!hasAnyPick" @click="startSync">开始拉取</button>
      </template>

      <!-- ③ running：配对 / 进度 / 完成 / 失败（phase 由原生传输引擎发布） -->
      <template v-else-if="subPage === 'running'">
        <div v-if="!tr || tr.phase === 'idle'" class="phase-center">
          <div class="spinner">◌</div>
          <div class="phase-sub">正在准备…</div>
        </div>

        <div v-else-if="tr.phase === 'pairing'" class="phase-center">
          <div class="spinner">◌</div>
          <div class="phase-title">正在建立同步会话…</div>
          <div class="phase-sub">{{ directionText }}</div>
        </div>

        <div v-else-if="tr.phase === 'transferring'" class="card progress-card">
          <div class="phase-title">{{ directionText }}</div>
          <van-progress :percentage="progressPct" stroke-width="6" />
          <div class="progress-line">
            <span class="progress-pct">{{ progressPct }}%</span>
            <span class="progress-speed">{{ fmtSpeed(tr.bytesPerSecond) }}</span>
          </div>
          <div class="progress-file">当前文件：{{ tr.currentFile || '—' }}</div>
        </div>

        <div v-else-if="tr.phase === 'done'" class="card done-card">
          <div class="result-head ok">✓ 同步完成</div>
          <div class="result-summary" :aria-label="'lansync.result.summary|' + tr.resultSummary">
            {{ tr.resultSummary }}
          </div>
          <div v-if="tr.backupDir" class="result-sub">已备份本机原文件到 Documents/{{ tr.backupDir }}</div>
          <div v-if="tr.needsRestart" class="result-warn">⚠ 主库已替换，请重启 App 生效</div>
          <button class="primary-btn" aria-label="lansync.done.button" @click="subPage = 'devices'">完成</button>
        </div>

        <div v-else class="card fail-card">
          <div class="result-head bad">✕ 同步失败</div>
          <div class="result-summary" :aria-label="'lansync.fail.message|' + (tr.failMessage ?? '')">
            {{ tr.failMessage ?? '' }}
          </div>
          <div class="result-sub">{{ directionText }}</div>
          <button class="primary-btn" @click="subPage = 'configure'">重试</button>
        </div>
      </template>
    </div>

    <van-dialog
      v-model:show="alertOpen"
      :title="alertTitle"
      :message="alertMsg"
      confirm-button-text="好"
    />
  </div>
</template>

<script setup lang="ts">
// 联机同步 Web 面板（P2-6c-1，对齐原生 LANSyncView 三态页）：
// 子页切换 / 各类勾选粒度 / 展开集合 / 手动直连输入 = Web 本地态；
// 服务探测 / 扫描 / 连接 / 拉取 = lan.* 动作；传输 phase/progress 经 lan.changed 推送回读。
import { computed, onMounted, reactive, ref } from 'vue'
import { klineBus } from '../../bridge/klineBus'
import type { LANCategorySnap, LANPeerSnap, LANSSnapshot } from '../../types/protocol'

const emit = defineEmits<{ (e: 'close'): void }>()

const snap = ref<LANSSnapshot | null>(null)
const subPage = ref<'devices' | 'configure' | 'running'>('devices')
const manualAddress = ref('')
/** 各类别勾选粒度（未选 / 整类全选 / 自定义子项集合），语义对齐原生 CategoryPick */
const picks = reactive<Record<string, 'none' | 'all' | string[]>>({})
const expanded = reactive<Record<string, boolean>>({})
const alertOpen = ref(false)
const alertTitle = ref('')
const alertMsg = ref('')

const busy = computed(() => snap.value?.busy ?? false)
const connecting = computed(() => snap.value?.connecting ?? false)
const tr = computed(() => snap.value?.transfer ?? null)
const progressPct = computed(() => Math.round((tr.value?.progress ?? 0) * 100))
const directionText = computed(() => `拉取：${snap.value?.configure?.peer.name ?? '对端'} → 本机`)

async function pull(): Promise<void> {
  try {
    snap.value = (await klineBus.request('lan', 'snapshot')) as unknown as LANSSnapshot
  } catch (e) {
    console.error('lan.snapshot 失败', e)
  }
}

function act(action: string, payload?: Record<string, unknown>): void {
  void klineBus
    .request('lan', action, payload)
    .then(() => pull())
    .catch((e) => console.error(`lan.${action} 失败`, e))
}

function back(): void {
  if (subPage.value === 'devices') emit('close')
  else subPage.value = 'devices'
}

function connectManual(): void {
  const text = manualAddress.value.trim()
  if (!text) return
  act('connect', { address: text })
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('lan.changed', (ev) => {
    const p = ev.payload ?? {}
    const reason = String(p['reason'] ?? '')
    const message = p['message'] ? String(p['message']) : ''
    if (reason === 'connectFailed') {
      alertTitle.value = '无法连接'
      alertMsg.value = message
      alertOpen.value = true
    } else if (reason === 'mainDBReplaced') {
      alertTitle.value = '主库已替换'
      alertMsg.value = message
      alertOpen.value = true
    } else if (reason === 'connected') {
      subPage.value = 'configure'
    }
    void pull()
  })
  await pull()
})

// ===== 勾选粒度（语义对齐原生 toggleCategoryPick / toggleChildPick） =====

function pickOf(catKey: string): 'none' | 'all' | string[] {
  return picks[catKey] ?? 'none'
}

function pickClass(cat: LANCategorySnap): string {
  const p = pickOf(cat.key)
  if (p === 'all') return 'all'
  if (Array.isArray(p) && p.length > 0) return 'mixed'
  return 'none'
}

function pickGlyph(cat: LANCategorySnap): string {
  const p = pickOf(cat.key)
  if (p === 'all') return '✓'
  if (Array.isArray(p) && p.length > 0) return '–'
  return ''
}

function toggleCategory(cat: LANCategorySnap): void {
  picks[cat.key] = pickOf(cat.key) === 'all' ? 'none' : 'all'
}

function toggleChild(cat: LANCategorySnap, child: { key: string }): void {
  const allKeys = cat.children.map((c) => c.key)
  const p = pickOf(cat.key)
  if (p === 'none') {
    picks[cat.key] = [child.key]
    return
  }
  if (p === 'all') {
    const rest = allKeys.filter((k) => k !== child.key)
    picks[cat.key] = rest.length ? rest : 'none'
    return
  }
  const set = new Set(p as string[])
  if (set.has(child.key)) set.delete(child.key)
  else set.add(child.key)
  const arr = [...set]
  if (!arr.length) picks[cat.key] = 'none'
  else if (arr.length === allKeys.length && allKeys.every((k) => set.has(k))) picks[cat.key] = 'all'
  else picks[cat.key] = arr
}

function childChecked(cat: LANCategorySnap, child: { key: string }): boolean {
  const p = pickOf(cat.key)
  if (p === 'all') return true
  return Array.isArray(p) && p.includes(child.key)
}

const hasAnyPick = computed(() =>
  Object.values(picks).some((p) => p === 'all' || (Array.isArray(p) && p.length > 0)))

function startSync(): void {
  const cats = snap.value?.configure?.categories ?? []
  const selections = cats.flatMap((cat) => {
    const p = pickOf(cat.key)
    if (p === 'none') return []
    if (p === 'all') return [{ category: cat.key, mode: 'all', childKeys: [] }]
    return [{ category: cat.key, mode: 'children', childKeys: p as string[] }]
  })
  if (!selections.length) return
  void klineBus.request('lan', 'start', { selections })
    .then(() => { subPage.value = 'running' })
    .catch((e) => console.error('lan.start 失败', e))
}

function fmtSpeed(bps: number): string {
  return `${(bps / 1_048_576).toFixed(1)} MB/s`
}
</script>

<style scoped>
.lp {
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

.nav-back:disabled {
  color: var(--k-text-tertiary);
}

.nav-title {
  font-size: 20px;
  font-weight: 700;
  color: var(--k-text);
}

.lp-body {
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
  margin-bottom: 10px;
}

.divider {
  height: 0.5px;
  background: var(--k-divider, #c6c6c8);
  margin-left: 16px;
}

/* 本机服务卡 */
.svc-line {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 14px 16px 0;
}

.dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
}

.dot.on { background: var(--k-ok); }
.dot.off { background: #ff3b30; }

.svc-state {
  font-size: 16px;
  font-weight: 500;
  color: var(--k-text);
  flex: 1;
}

.svc-refresh {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 18px;
  cursor: pointer;
}

.svc-refresh:disabled { color: var(--k-text-tertiary); }

.svc-sub {
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 6px 16px 0;
}

.svc-hint {
  font-size: 12px;
  color: var(--k-text-tertiary);
  padding: 3px 16px 14px;
}

/* 暴露开关卡 */
.expose-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 14px 16px;
}

.expose-text { flex: 1; }

.expose-title {
  font-size: 16px;
  color: var(--k-text);
}

.expose-sub {
  font-size: 12px;
  color: var(--k-text-tertiary);
  margin-top: 3px;
}

.expose-sub.warm { color: #ff9500; }

/* 扫描按钮 */
.scan-btn {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  border: none;
  color: var(--k-accent);
  font-size: 15px;
  font-weight: 600;
  min-height: 44px;
  padding: 0 16px;
  cursor: pointer;
  text-align: left;
}

.scan-btn:disabled { color: var(--k-text-tertiary); }

.searching {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 48px;
  padding: 0 16px;
  font-size: 14px;
  color: var(--k-text-secondary);
}

/* 设备卡 */
.peer-card {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  border: none;
  min-height: 56px;
  padding: 0 16px;
  cursor: pointer;
  text-align: left;
  color: var(--k-text);
}

.peer-icon {
  color: var(--k-accent);
  font-size: 13px;
  flex-shrink: 0;
}

.peer-text { flex: 1; min-width: 0; }

.peer-name {
  font-size: 16px;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.peer-host {
  font-size: 12px;
  color: var(--k-text-secondary);
  margin-top: 3px;
}

.peer-chevron {
  color: var(--k-text-tertiary);
  font-size: 14px;
  font-weight: 600;
}

/* 手动直连 */
.manual-card {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px 16px;
}

.manual-field {
  flex: 1;
  height: 40px;
  border: none;
  border-radius: 10px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 15px;
  padding: 0 12px;
  outline: none;
}

.manual-connect {
  width: 76px;
  height: 40px;
  border: none;
  border-radius: 10px;
  background: var(--k-bg);
  color: var(--k-accent);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.manual-connect:disabled { color: var(--k-text-tertiary); }

.foot-note {
  font-size: 12px;
  color: var(--k-text-tertiary);
  padding: 2px 4px 12px;
}

/* configure 页 */
.peer-info {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 48px;
  padding: 0 16px;
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
  color: var(--k-text);
}

.cat-text { flex: 1; min-width: 0; }

.cat-title {
  font-size: 16px;
  color: var(--k-text);
}

.cat-sub {
  font-size: 12px;
  color: var(--k-text-secondary);
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
  color: var(--k-text-tertiary);
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
}

/* 勾选圈 */
.pick {
  width: 22px;
  height: 22px;
  border-radius: 50%;
  border: 1.5px solid var(--k-text-tertiary);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  font-size: 13px;
  color: transparent;
  flex-shrink: 0;
}

.pick.all,
.pick.mixed {
  border-color: var(--k-accent);
  background: var(--k-accent);
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
  color: var(--k-text);
}

.child-name {
  flex: 1;
  font-size: 14px;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.child-qty {
  font-size: 12px;
  color: var(--k-text-secondary);
}

.warn-card {
  background: rgba(255, 204, 0, 0.15);
  border-radius: 12px;
  padding: 12px;
  font-size: 13px;
  color: var(--k-text);
  margin-bottom: 10px;
}

.primary-btn {
  width: 100%;
  min-height: 48px;
  border: none;
  border-radius: 12px;
  background: var(--k-accent);
  color: #ffffff;
  font-size: 17px;
  font-weight: 600;
  cursor: pointer;
}

.primary-btn:disabled {
  opacity: 0.35;
  cursor: default;
}

.primary-btn + .primary-btn {
  margin-top: 10px;
}

/* running 页 */
.phase-center {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 160px;
  gap: 12px;
}

.spinner {
  font-size: 22px;
  color: var(--k-accent);
  animation: lp-spin 1s linear infinite;
}

@keyframes lp-spin {
  to { transform: rotate(360deg); }
}

.phase-title {
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text);
}

.phase-sub {
  font-size: 13px;
  color: var(--k-text-secondary);
}

.progress-card {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.progress-line {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
}

.progress-pct {
  font-size: 30px;
  font-weight: 700;
  color: var(--k-text);
}

.progress-speed {
  font-size: 14px;
  color: var(--k-text-secondary);
}

.progress-file {
  font-size: 12px;
  color: var(--k-text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.done-card,
.fail-card {
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.done-card { background: rgba(52, 199, 89, 0.12); }
.fail-card { background: rgba(255, 59, 48, 0.12); }

.result-head {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text);
}

.result-head.ok { color: var(--k-ok); }
.result-head.bad { color: #ff3b30; }

.result-summary {
  font-size: 14px;
  color: var(--k-text);
  word-break: break-all;
}

.result-sub {
  font-size: 13px;
  color: var(--k-text-secondary);
}

.result-warn {
  font-size: 13px;
  color: var(--k-text);
}
</style>
