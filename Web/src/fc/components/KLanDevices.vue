<template>
  <div>
    <!-- ① devices：本机服务 / 暴露开关 / 扫描 / 已发现设备 / 手动直连 -->
    <div class="sec-label">本机服务</div>
    <div class="card" aria-label="lansync.local.status">
      <div class="svc-line">
        <span class="dot" :class="modelValue.serverOnline ? 'on' : 'off'"></span>
        <span class="svc-state">{{ modelValue.serverOnline ? '在线' : '离线' }}</span>
        <button class="svc-refresh" aria-label="lansync.probe" :disabled="modelValue.probing" @click="emit('probe')">
          {{ modelValue.probing ? '⟳…' : '⟳' }}
        </button>
      </div>
      <div class="svc-sub">{{ modelValue.deviceName || '—' }} · 端口 {{ modelValue.port ?? '—' }}</div>
      <div class="svc-hint">对端设备需保持 Kline 在前台</div>
    </div>

    <div class="card expose-card">
      <div class="expose-text">
        <div class="expose-title">允许对端获取本机内容</div>
        <div class="expose-sub" :class="{ warm: modelValue.isExposed }">
          {{ modelValue.isExposed ? '已暴露：对端可扫描到本机并拉取其内容' : '已隐藏：不广播、不接受同步' }}
        </div>
      </div>
      <VanSwitch
        aria-label="lansync.expose.toggle"
        :model-value="modelValue.isExposed"
        size="22px"
        @update:model-value="(v: boolean) => emit('setExposed', v)"
      />
    </div>

    <div class="sec-label">已发现设备</div>
    <button class="card scan-btn" aria-label="lansync.scan.once" :disabled="modelValue.isBrowsing" @click="emit('scan')">
      <span>⌕</span>
      <span>{{ modelValue.isBrowsing ? '扫描中…' : '扫描一次' }}</span>
    </button>
    <div v-if="modelValue.isBrowsing" class="card searching">◌ 正在搜索同网段设备…</div>
    <button
      v-for="(p, i) in modelValue.peers"
      :key="p.id"
      class="card peer-card"
      :aria-label="'lansync.peer.' + i"
      :disabled="modelValue.connecting"
      @click="emit('connect', p.id)"
    >
      <span class="peer-icon">(((•)))</span>
      <div class="peer-text">
        <div class="peer-name">{{ p.name }}</div>
        <div class="peer-host">{{ p.host }}:{{ p.port }}</div>
      </div>
      <span class="peer-chevron">{{ modelValue.connecting ? '◌' : '›' }}</span>
    </button>

    <div class="sec-label">手动直连</div>
    <div class="card manual-card">
      <input
        class="manual-field"
        aria-label="lansync.manual.field"
        placeholder="对端 IP:端口，如 192.168.1.5:5051"
        autocapitalize="off"
        autocorrect="off"
        :value="modelValue.manualAddress"
        @input="onAddr"
      />
      <button
        class="manual-connect"
        aria-label="lansync.manual.connect"
        :disabled="modelValue.connecting"
        @click="emit('connectManual', modelValue.manualAddress.trim())"
      >
        {{ modelValue.connecting ? '连接中' : '连接' }}
      </button>
    </div>
    <div class="foot-note">对端未出现在列表时可直接输入其 IP 与端口（缺省端口 5051）</div>
  </div>
</template>

<script setup lang="ts">
// k-lan-devices：联机同步 devices 子页（本机服务卡/暴露开关/扫描/对端列表/手动直连）。
// 哑组件：lan.snapshot 快照由 adapter 注入 modelValue；probe/setExposed/scan/
// connect(peerId)/connectManual(address) 抛给 adapter 写桥。
import { Switch as VanSwitch } from 'vant'
import 'vant/es/switch/style/index'

export interface LanDevicePeer {
  id: string
  name: string
  host: string
  port: number
}

export interface LanDevicesState {
  serverOnline: boolean
  probing: boolean
  port: number | null
  deviceName: string
  isExposed: boolean
  isBrowsing: boolean
  connecting: boolean
  peers: LanDevicePeer[]
  manualAddress: string
}

const props = withDefaults(defineProps<{
  modelValue?: LanDevicesState
}>(), {
  modelValue: () => ({
    serverOnline: false,
    probing: false,
    port: null,
    deviceName: '',
    isExposed: false,
    isBrowsing: false,
    connecting: false,
    peers: [],
    manualAddress: '',
  }),
})

const emit = defineEmits<{
  (e: 'update:modelValue', v: LanDevicesState): void
  (e: 'probe'): void
  (e: 'setExposed', on: boolean): void
  (e: 'scan'): void
  (e: 'connect', peerId: string): void
  (e: 'connectManual', address: string): void
}>()

function onAddr(ev: Event): void {
  const v = (ev.target as HTMLInputElement).value
  emit('update:modelValue', { ...props.modelValue, manualAddress: v })
}
</script>

<style scoped>
.sec-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--k-text-secondary, #6c6c70);
  padding: 10px 2px 6px;
}

.card {
  background: var(--k-bg-secondary, #f2f2f7);
  border-radius: 12px;
  margin-bottom: 10px;
}

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

.dot.on { background: var(--k-ok, #34c759); }
.dot.off { background: #ff3b30; }

.svc-state {
  font-size: 16px;
  font-weight: 500;
  color: var(--k-text, #000);
  flex: 1;
}

.svc-refresh {
  border: none;
  background: none;
  color: var(--k-accent, #007aff);
  font-size: 18px;
  cursor: pointer;
}

.svc-refresh:disabled { color: var(--k-text-tertiary, #c7c7cb); }

.svc-sub {
  font-size: 13px;
  color: var(--k-text-secondary, #6c6c70);
  padding: 6px 16px 0;
}

.svc-hint {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 3px 16px 14px;
}

.expose-card {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 14px 16px;
}

.expose-text { flex: 1; }

.expose-title {
  font-size: 16px;
  color: var(--k-text, #000);
}

.expose-sub {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  margin-top: 3px;
}

.expose-sub.warm { color: #ff9500; }

.scan-btn {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  border: none;
  color: var(--k-accent, #007aff);
  font-size: 15px;
  font-weight: 600;
  min-height: 44px;
  padding: 0 16px;
  cursor: pointer;
  text-align: left;
}

.scan-btn:disabled { color: var(--k-text-tertiary, #c7c7cb); }

.searching {
  display: flex;
  align-items: center;
  gap: 10px;
  min-height: 48px;
  padding: 0 16px;
  font-size: 14px;
  color: var(--k-text-secondary, #6c6c70);
}

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
  color: var(--k-text, #000);
}

.peer-card:disabled { cursor: default; }

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

.peer-chevron {
  color: var(--k-text-tertiary, #c7c7cb);
  font-size: 14px;
  font-weight: 600;
}

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
  background: var(--k-bg, #ffffff);
  color: var(--k-text, #000);
  font-size: 15px;
  padding: 0 12px;
  outline: none;
}

.manual-connect {
  width: 76px;
  height: 40px;
  border: none;
  border-radius: 10px;
  background: var(--k-bg, #ffffff);
  color: var(--k-accent, #007aff);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.manual-connect:disabled { color: var(--k-text-tertiary, #c7c7cb); }

.foot-note {
  font-size: 12px;
  color: var(--k-text-tertiary, #c7c7cb);
  padding: 2px 4px 12px;
}
</style>
