<template>
  <div class="sheet-page">
    <!-- K线设置面板（底部 75% 高，对齐原生 settingsOverlay）：
         P1 规则化迁移 — 内容区由 FcPageHost 按规则 JSON 渲染（含 picker/重置确认弹层） -->
    <div v-if="activeName === 'settings'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">K线设置</span>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body">
          <FcPageHost name="sheet-settings" domain="sheet" @close="close" />
        </div>
      </div>
    </div>

    <!-- 指标面板（主图 / 副图两形态，对齐原生 mainSheetContent/subSheetContent） -->
    <div v-if="activeName === 'mainIndicators' || activeName === 'subIndicators'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">{{ indicatorsTitle }}</span>
          <button class="panel-reset" @click="resetBuiltinConfirm = true">重置内置指标</button>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body" v-if="indicators">
          <!-- 主图形态 -->
          <template v-if="activeName === 'mainIndicators'">
            <div class="sec-title">技术指标公式 · 主图</div>
            <div class="ind-grid">
              <button
                v-for="d in indicators.mainDefs"
                :key="d.id"
                class="ind-tile"
                :class="{ on: d.on }"
                role="button"
                :aria-label="`chart.indicator.main.${d.name}`"
                @click="toggleMain(d)"
              >
                <span class="ind-check">{{ d.on ? '☑' : '☐' }}</span>
                <span class="ind-name">{{ d.name }}</span>
              </button>
            </div>
            <button class="param-entry" @click="openSystemEditor(true, null)">⚙ 公式编辑 · 技术指标公式 ›</button>
            <div class="sec-title">自定义技术指标（主图）</div>
            <button class="param-entry" @click="openCustomEditor('main')">＋ 新增/管理 ›</button>
            <div v-if="indicators.mainCustoms.length === 0" class="block-empty">暂无主图自定义技术指标</div>
            <div v-else class="custom-rows">
              <div v-for="c in indicators.mainCustoms" :key="c.id" class="custom-row">
                <button class="custom-main" @click="activateMainCustom(c)">
                  <span class="custom-check">{{ c.active ? '◉' : '○' }}</span>
                  <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
                  <span class="custom-name">{{ c.name }}</span>
                </button>
                <button class="custom-edit" @click="openCustomEditor('main')">✎</button>
              </div>
            </div>
          </template>

          <!-- 副图形态 -->
          <template v-else-if="activeSlot">
            <div class="sec-title">选择副图指标 · {{ activeSlot.title }}</div>
            <template v-for="g in activeSlot.groups" :key="g.group">
              <div class="sec-title">{{ g.group }}</div>
              <div class="ind-grid">
                <button
                  v-for="k in g.kinds"
                  :key="k"
                  class="sub-tile"
                  :class="{ on: !activeSlot.customID && activeSlot.kind === k }"
                  @click="selectSubKind(k)"
                >{{ k }}</button>
              </div>
            </template>
            <button
              v-if="!activeSlot.customID && activeSlot.hasTemplate"
              class="param-entry"
              @click="openSystemEditor(false, activeSlot.kind)"
            >⚙ {{ activeSlot.kind }} 公式编辑 · 技术指标公式 ›</button>
            <div class="sec-title">自定义技术指标（副图）</div>
            <button class="param-entry" @click="openCustomEditor('sub')">＋ 新增/管理 ›</button>
            <div v-if="activeSlot.customs.length === 0" class="block-empty">暂无副图自定义技术指标</div>
            <div v-else class="custom-rows">
              <div v-for="c in activeSlot.customs" :key="c.id" class="custom-row">
                <button class="custom-main" @click="selectSubCustom(c)">
                  <span class="custom-check">{{ c.active ? '◉' : '○' }}</span>
                  <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
                  <span class="custom-name">{{ c.name }}</span>
                  <span v-if="c.active" class="custom-current">当前</span>
                </button>
                <button class="custom-edit" @click="openCustomEditor('sub')">✎</button>
              </div>
            </div>
          </template>
          <div style="height: 24px"></div>
        </div>
      </div>
    </div>

    <!-- 重置内置指标确认 -->
    <van-dialog
      v-model:show="resetBuiltinConfirm"
      title="重置内置指标"
      show-cancel-button
      confirm-button-text="重置"
      confirm-button-color="#ee0a24"
      @confirm="resetBuiltin"
    >
      <div class="dialog-note">将把所有内置指标恢复为编译时的内容，确定重置吗？</div>
    </van-dialog>

    <!-- 图表搜索面板（顶部锚定覆盖式，对齐原生 chartSearchBar） -->
    <template v-if="activeName === 'search'">
      <div class="panel-mask" @click="close">
        <div class="search-layer" @click.stop>
          <div class="search-row">
            <button class="search-x" @click="close">✕</button>
            <van-search
              v-model="keyword"
              class="search-field"
              placeholder="搜索代码/名称"
              shape="round"
              @update:model-value="onKeyword"
            />
            <button v-if="keyword" class="search-clear" @click="keyword = ''; results = []">⊗</button>
          </div>
          <div class="search-results">
            <div v-if="results.length === 0 && keyword" class="search-empty">没有匹配的标的</div>
            <div
              v-for="r in results"
              :key="r.file"
              class="search-row-item"
              @click="pick(r)"
            >
              <span class="sr-name">{{ r.name }}</span>
              <span class="sr-code">{{ r.code }}</span>
            </div>
          </div>
        </div>
      </div>
    </template>
    <!-- 快捷面板（悬浮球，P2-6a：列表态 / 详情态票面 / picked 票面三视图） -->
    <div v-if="activeName === 'quick'" class="panel-mask" @click="closeQuick">
      <div class="panel quick-panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">快捷面板</span>
          <button class="panel-done" @click="closeQuick">关闭</button>
        </div>
        <div class="panel-body" v-if="quick">
          <template v-if="quick.view === 'detail' || quick.view === 'picked'">
            <!-- 详情态 / picked 票面态：账户条 + 行情头 + 票面 + 持仓块 + 快捷动作 -->
            <div v-if="!quick.detail?.hasAccount" class="block-empty">请先选择有效的模拟账户（模拟页新建）</div>
            <template v-else>
              <div class="qk-meta-row">
                <span class="qk-acc" @click="accPickerOpen = true">{{ quick.selectedName }} ▾</span>
                <span class="qk-cash">可用 {{ fmtAmount(quick.detail.cash) }}</span>
                <span class="qk-phase">{{ quick.detail.tradingPhase }}</span>
              </div>
              <div class="qk-quote" v-if="quick.detail.meta">
                <div class="q-left">
                  <div class="q-name">{{ quick.detail.meta.name }}</div>
                  <div class="q-code">{{ quick.detail.meta.code }}</div>
                </div>
                <span class="q-price big" :class="pctClass(quick.detail.meta)">{{ fmtPrice(quick.detail.meta) }}</span>
                <span class="pct-pill" :class="pillClass(quick.detail.meta)">{{ fmtPct(quick.detail.meta) }}</span>
              </div>
              <!-- 票面（Web 本地表单，提交一次写回） -->
              <div class="ticket">
                <div class="ticket-seg">
                  <button class="seg buy" :class="{ on: ticket.direction === 'buy' }" @click="ticket.direction = 'buy'">买入</button>
                  <button class="seg sell" :class="{ on: ticket.direction === 'sell' }" @click="ticket.direction = 'sell'">卖出</button>
                  <button class="seg" @click="ticket.priceType = ticket.priceType === 'limit' ? 'market' : 'limit'">
                    {{ ticket.priceType === 'limit' ? '限价' : '市价' }}
                  </button>
                </div>
                <label class="ticket-row">
                  <span>委托价</span>
                  <input
                    v-model="ticket.priceText"
                    class="ticket-input"
                    inputmode="decimal"
                    :disabled="ticket.priceType === 'market'"
                    :placeholder="ticket.priceType === 'market' ? '市价' : String(ticketLastPrice ?? '')"
                  />
                  <span class="unit">元</span>
                </label>
                <label class="ticket-row">
                  <span>数量</span>
                  <input v-model="ticket.qtyText" class="ticket-input" inputmode="numeric" placeholder="0" />
                  <span class="unit">股</span>
                </label>
                <div class="pos-chips">
                  <button v-for="r in [0.25, 0.5, 0.75, 1]" :key="r" class="pos-chip" @click="applyPosition(r)">{{ r * 100 }}%</button>
                </div>
                <div v-if="ticketError" class="ticket-error">{{ ticketError }}</div>
                <button
                  class="submit-btn"
                  :class="ticket.direction === 'buy' ? 'buy' : 'sell'"
                  @click="submitTicket"
                >{{ ticket.direction === 'buy' ? '买入' : '卖出' }} {{ ticket.priceType === 'limit' ? '限价' : '市价' }}</button>
              </div>
              <div class="pos-block" v-if="quick.detail.ticket?.position">
                <div class="qk-meta-row">
                  <span>持仓 {{ fmtShares(quick.detail.ticket.position.qty) }} · 可用 {{ fmtShares(quick.detail.ticket.position.availableQty) }}</span>
                  <span :class="profitClass(quick.detail.ticket.position.profit)">
                    {{ fmtSigned0(quick.detail.ticket.position.profit) }} ({{ fmtPctRaw(quick.detail.ticket.position.profitPct * 100) }})
                  </span>
                </div>
              </div>
              <div class="qk-actions" v-if="quick.detail.meta">
                <button class="tool-btn" @click="closeAll">一键清仓</button>
              </div>
            </template>
          </template>

          <template v-else-if="quick.view === 'list' && quick.list">
            <!-- 列表态：账户摘要 + 快捷动作 + 自选迷你列表 + 在途委托 -->
            <div class="qk-meta-row">
              <span class="qk-acc" @click="accPickerOpen = true">{{ quick.selectedName }} ▾</span>
              <span class="qk-cash">总资产 {{ fmtAmount(quick.list.summary.totalAssets) }}</span>
              <span class="qk-phase">当日 <span :class="profitClass(quick.list.summary.dayProfit)">{{ fmtSigned0(quick.list.summary.dayProfit) }}</span></span>
            </div>
            <div class="qk-actions">
              <button class="tool-btn" @click="accPickerOpen = true">切换账户</button>
              <button class="tool-btn" @click="cancelAll">一键撤单 ({{ quick.list.activeOrderCount }})</button>
              <button class="tool-btn" @click="closeQuick">关闭面板</button>
            </div>
            <div class="sec-title">自选</div>
            <div v-if="quick.list.watchlist.length === 0" class="block-empty">暂无自选</div>
            <div v-else class="quote-rows">
              <div v-for="q in quick.list.watchlist" :key="q.file" class="quote-row">
                <div class="q-left">
                  <div class="q-name">{{ q.name }}</div>
                  <div class="q-code">{{ q.code }}</div>
                </div>
                <span class="q-price" :class="pctClass(q)">{{ fmtPrice(q) }}</span>
                <span class="pct-pill" :class="pillClass(q)">{{ fmtPct(q) }}</span>
                <button class="mini-btn buy" @click="pickTicket(q, 'buy')">买</button>
                <button class="mini-btn sell" @click="pickTicket(q, 'sell')">卖</button>
              </div>
            </div>
            <div class="sec-title">在途委托</div>
            <div v-if="quick.list.activeOrders.length === 0" class="block-empty">暂无在途委托</div>
            <div v-else class="mini-orders">
              <div v-for="o in quick.list.activeOrders" :key="o.id" class="mini-order">
                <span class="dir-tag" :class="o.direction === 'buy' ? 'tag-buy' : 'tag-sell'">{{ o.direction === 'buy' ? '买入' : '卖出' }}</span>
                <span class="q-name">{{ o.name }}</span>
                <span class="q-code">{{ fmtShares(o.qty) }} 股 · {{ o.status }}</span>
              </div>
            </div>
          </template>
        </div>
      </div>
    </div>

    <!-- 公式中心（tech 段，P2-8a：浏览/删除；编辑与新建直进 Web 编辑器全屏页） -->
    <div v-if="activeName === 'formulaCenter'" class="panel-mask" @click="close">
      <div class="panel" @click.stop>
        <div class="panel-header">
          <span class="panel-title">公式管理 · 技术指标（{{ formula?.period ?? '' }}）</span>
          <button class="panel-done" @click="close">完成</button>
        </div>
        <div class="panel-body" v-if="formula">
          <div class="sec-title">系统指标 · 主图</div>
          <div class="formula-rows">
            <div v-for="d in formula.mainItems" :key="d.id" class="formula-row">
              <span class="q-name">{{ d.name }}</span>
              <button v-if="d.hasTemplate" class="tool-btn" @click="openEditor({ target: 'system', id: d.id, isMain: true })">编辑</button>
            </div>
          </div>
          <template v-for="g in formula.subGroups" :key="g.group">
            <div class="sec-title">系统指标 · {{ g.group }}</div>
            <div class="formula-rows">
              <div v-for="k in g.kinds" :key="k" class="formula-row">
                <span class="q-name">{{ k }}</span>
                <button class="tool-btn" @click="openEditor({ target: 'system', id: k, isMain: false })">编辑</button>
              </div>
            </div>
          </template>
          <div class="sec-title">自定义技术指标</div>
          <button class="param-entry" @click="openEditor({ target: 'custom' })">＋ 新建 / 管理 ›</button>
          <div v-if="formula.customs.length === 0" class="block-empty">暂无自定义技术指标</div>
          <div v-else class="custom-rows">
            <div v-for="c in formula.customs" :key="c.id" class="custom-row">
              <span class="custom-color" :style="{ background: '#' + c.colorHex }"></span>
              <span class="custom-name">{{ c.name }}</span>
              <span class="cfg-note">{{ c.scope === 'main' ? '主图' : '副图' }} · {{ c.periods.length }} 周期</span>
              <button class="inline-btn" aria-label="formulaCenter.editCustom" @click="openEditor({ target: 'custom', id: c.id })">编辑</button>
              <button class="inline-btn cancel" @click="deleteCustom(c)">删除</button>
            </div>
          </div>
          <div class="cfg-foot-note">编辑与新建在 Web 公式编辑器完成（保存后重新打开本面板即见最新）。</div>
          <div style="height: 24px"></div>
        </div>
      </div>
    </div>

    <!-- 指标组合编辑页（P2 指标组合：全屏卡片形态，五组合 × 五周期编辑） -->
    <div v-if="activeName === 'presetEditor'" class="editor-full">
      <PresetEditorPanel @close="close" />
    </div>

    <!-- 训练设置浮层（P2-6c-3：居中卡片形态，对齐原生 TrainingSetupSheet） -->
    <div v-if="activeName === 'training'" class="panel-mask" @click="close">
      <div class="train-card" @click.stop>
        <div class="train-header">
          <span class="panel-title">单人训练</span>
          <button class="train-x" @click="close">✕</button>
        </div>
        <div class="train-body">
          <div class="sec-title">分类</div>
          <div class="chip-row">
            <button
              v-for="c in trainCategories"
              :key="c"
              class="chip"
              :class="{ on: trainCategory === c }"
              @click="trainCategory = c; trainError = ''"
            >{{ c }}</button>
          </div>

          <template v-if="trainCategory === '我的分组'">
            <div class="sec-title">分组</div>
            <div v-if="trainGroups.length === 0" class="cfg-note">暂无可用分组</div>
            <div v-else class="chip-row">
              <button
                v-for="g in trainGroups"
                :key="g.id"
                class="chip"
                :class="{ on: trainGroupID === g.id }"
                @click="trainGroupID = g.id; trainError = ''"
              >{{ g.name }}</button>
            </div>
          </template>

          <div class="sec-title">训练账户</div>
          <div class="chip-row" aria-label="trainingSetup.accountType">
            <button
              v-for="t in trainAccountTypes"
              :key="t.value"
              class="chip"
              :class="{ on: trainAccountType === t.value }"
              @click="trainAccountType = t.value; trainError = ''; void savePrefs({ accountType: t.value })"
            >{{ t.title }}</button>
          </div>
          <div class="cfg-note">{{ trainAccountType === 'percent' ? '不占用资金，按仓位比例（1/4、1/3、1/2、全仓）买卖，任何标的都买得起' : '固定本金，买入前校验资金；开启训练要求本金至少买得起 2 手（200 股）' }}</div>
          <div v-if="trainAccountType === 'fixedAmount'" class="train-capital" aria-label="trainingSetup.capital">
            <span>本金</span>
            <input v-model="trainCapitalText" class="train-capital-input" inputmode="numeric" placeholder="100000" @change="void savePrefs({ capitalText: trainCapitalText })" />
            <span class="p-unit">元</span>
          </div>

          <div class="sec-title">交易模式</div>
          <div class="chip-row" aria-label="trainingSetup.tradeMode">
            <button
              v-for="m in trainTradeModes"
              :key="m.value"
              class="chip"
              :class="{ on: trainTradeMode === m.value }"
              @click="trainTradeMode = m.value; trainError = ''; void savePrefs({ tradeMode: m.value })"
            >{{ m.title }}</button>
          </div>
          <div class="cfg-note">{{ trainTradeMode === 'sameDayClose' ? '点下单立刻以当前训练日收盘价成交（成交日 = 当前训练日）' : '隔日限价委托：点下单只挂单，仅下一训练日有效；该日行情触及委托价才按委托价成交，未触及即作废' }}</div>

          <div class="sec-title">标的</div>
          <div class="train-target-line">
            <span class="train-target" :class="{ none: !trainSelected }">
              {{ trainSelected ? `${trainSelected.name} ${trainSelected.code}` : '未选择' }}
            </span>
            <button class="train-random" @click="pickRandomTarget">随机抽取</button>
          </div>
          <div class="train-search">
            <input
              v-model="trainKeyword"
              class="train-search-input"
              placeholder="输入名称 / 代码搜索"
              @input="onTrainKeyword"
            />
            <button v-if="trainKeyword" class="train-search-x" @click="trainKeyword = ''; trainResults = []">⊗</button>
          </div>
          <div v-if="trainResults.length > 0" class="train-results">
            <div
              v-for="r in trainResults"
              :key="r.file"
              class="train-result-row"
              @click="selectTrainTarget(r)"
            >
              <span class="sr-name">{{ r.name }}</span>
              <span class="sr-code">{{ r.code }}</span>
              <span v-if="!r.trainable" class="train-untrainable">历史不足</span>
              <span v-else-if="trainSelected?.file === r.file" class="train-check">✓</span>
            </div>
          </div>

          <div class="sec-title">起始日期</div>
          <div class="train-target-line">
            <span class="train-target">{{ trainDateText }}</span>
            <button class="train-random" :disabled="!canRandomDate" @click="randomizeTrainDate">随机</button>
          </div>
          <div v-if="trainRangeText" class="cfg-note">可选区间 {{ trainRangeText }}</div>
          <input
            v-if="trainRange"
            v-model="trainDateInput"
            type="date"
            class="train-date-input"
            :min="ymd(trainRange.min)"
            :max="ymd(trainRange.max)"
          />
          <div v-if="trainSelected && trainRange && !trainRange.trainable" class="warn-line-orange">
            该标的历史数据不足（需至少能取到最新库日期前 65 天）
          </div>

          <div v-if="trainError" class="train-error">{{ trainError }}</div>
          <div style="height: 8px"></div>
        </div>
        <div class="train-footer" aria-label="trainingSetup.cancel">
          <button class="train-cancel" @click="close">取消</button>
          <button
            class="train-start"
            aria-label="trainingSetup.start"
            :disabled="!canStartTraining"
            @click="startTraining"
          >开始训练</button>
        </div>
      </div>
    </div>

    <!-- 重新选择标的（金额账户本金买不起 2 手，对齐原生 alert） -->
    <van-dialog
      v-model:show="trainReselectOpen"
      title="标的需要重新选择"
      :message="trainReselectMessage"
      show-cancel-button
      confirm-button-text="重新选择标的"
      confirm-button-color="#ee0a24"
      @confirm="clearTrainTarget"
    />

    <!-- 账户切换（快捷面板内 chips） -->
    <van-action-sheet
      v-model:show="accPickerOpen"
      :actions="accActions"
      cancel-text="取消"
      close-on-click-action
      @select="onAccSelect"
    />

    <!-- 卖出二次确认 -->
    <van-dialog
      v-model:show="sellConfirmOpen"
      :title="`确认卖出 ${ticketMetaName} ${fmtShares(ticketQty)} 股？`"
      show-cancel-button
      confirm-button-text="确认卖出"
      confirm-button-color="#ee0a24"
      @confirm="doSubmit"
    />
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { klineBus } from '../bridge/klineBus'
import { showToast } from 'vant'
import PresetEditorPanel from '../components/sheet/PresetEditorPanel.vue'
import FcPageHost from '../fc/FcPageHost.vue'
import type {
  ChartSearchResult,
  CustomIndicatorSnap,
  IndicatorDefSnap,
  IndicatorsSnapshot,
  SubSlotSnap,
  TrainingAnchorResult,
  TrainingPickResult,
  TrainingSearchResult,
  TrainingSetupSnapshot,
} from '../types/protocol'

const activeName = ref<string | null>(null)
const pageSeq = ref(0)
const indicators = ref<IndicatorsSnapshot | null>(null)
const activeSlotKey = ref<string | null>(null)

const keyword = ref('')
const results = ref<ChartSearchResult[]>([])

// ===== 共享格式化（对齐原生 MarketRow.render / SimFormat；红涨绿跌） =====
function fmtPrice(q: QuickQuote): string
function fmtPrice(v: number): string
function fmtPrice(arg: QuickQuote | number): string {
  const v = typeof arg === 'number' ? arg : arg.price
  return v === null || v === undefined ? '—' : v.toFixed(2)
}

function fmtPct(q: QuickQuote): string {
  return q.pct === null || q.pct === undefined ? '—' : fmtPctRaw(q.pct)
}

function fmtPctRaw(v: number): string {
  return `${v > 0 ? '+' : ''}${v.toFixed(2)}%`
}

function fmtAmount(v: number): string {
  return Math.round(v).toLocaleString('en-US')
}

function fmtShares(v: number): string {
  return v.toLocaleString('en-US')
}

function fmtSigned0(v: number): string {
  return `${v > 0 ? '+' : ''}${Math.round(v).toLocaleString('en-US')}`
}

function pctClass(q: QuickQuote): string {
  const p = q.pct ?? 0
  return p > 0 ? 'up' : p < 0 ? 'down' : ''
}

function pillClass(q: QuickQuote): string {
  const p = q.pct ?? 0
  return p > 0 ? 'pill-up' : p < 0 ? 'pill-down' : 'pill-flat'
}

function profitClass(v: number): string {
  return v < 0 ? 'down' : 'up'
}

const resetBuiltinConfirm = ref(false)

// ===== 指标面板（P2-5b） =====
const indicatorsTitle = computed(() =>
  activeName.value === 'mainIndicators' ? '主图指标'
    : `选择副图指标 · ${activeSlot.value?.title ?? ''}`)

const activeSlot = computed(() =>
  indicators.value?.subSlots.find((s) => s.slot === activeSlotKey.value) ?? null)

/** 当前激活主图自定义指标（互斥：激活自定义即隐藏系统指标判断由原生侧处理） */
function toggleMain(d: IndicatorDefSnap): void {
  if (!indicators.value) return
  void actIndicators('toggleMain', { id: d.id, on: !d.on })
}

function selectSubKind(kind: string): void {
  if (!activeSlot.value) return
  void actIndicators('selectSub', { slot: activeSlot.value.slot, kind })
}

function selectSubCustom(c: CustomIndicatorSnap): void {
  if (!activeSlot.value) return
  void actIndicators('selectSub', { slot: activeSlot.value.slot, customID: c.id })
}

function activateMainCustom(c: CustomIndicatorSnap): void {
  void actIndicators('activateMainCustom', { customID: c.active ? null : c.id })
}

function resetBuiltin(): void {
  void actIndicators('resetBuiltin', {})
}

function openSystemEditor(isMain: boolean, subId: string | null): void {
  void actIndicators('openSystemEditor', { isMain, subId })
  activeName.value = null   // 原生同款交互：先关面板再进编辑器（原生编辑器盖全屏）
}

function openCustomEditor(target: 'main' | 'sub'): void {
  void actIndicators('openCustomEditor', { target })
  activeName.value = null
}

/** 指标写回公共路径：动作成功即回读快照（写回模式 v2；重算由原生 recomputeHandler 执行） */
async function actIndicators(action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('chart', `indicators.${action}`, payload)
    await pullIndicators()
  } catch (e) {
    console.error(`indicators.${action} 失败`, e)
  }
}

async function pullIndicators(): Promise<void> {
  try {
    const s = ((await klineBus.request('chart', 'indicators.snapshot')) ?? {}) as Record<string, unknown>
    indicators.value = {
      period: String(s.period ?? ''),
      mainDefs: (s.mainDefs ?? []) as IndicatorDefSnap[],
      mainCustoms: (s.mainCustoms ?? []) as CustomIndicatorSnap[],
      subSlots: (s.subSlots ?? []) as SubSlotSnap[],
    }
    if (activeSlotKey.value === null && indicators.value.subSlots.length > 0) {
      activeSlotKey.value = indicators.value.subSlots[0].slot
    }
  } catch (e) {
    console.error('indicators.snapshot 失败', e)
  }
}

// ===== 快捷面板（P2-6a：悬浮球；三视图 + Web 票面） =====
interface QuickAccount { id: string; name: string; badge: string; colorHex: string }
interface QuickQuote { file: string; code: string; name: string; price: number | null; pct: number | null }
interface QuickSnapshot {
  trainingActive: boolean
  view: 'detail' | 'picked' | 'list'
  accounts: QuickAccount[]
  selectedName: string
  detail: {
    meta: QuickQuote
    accountName: string
    cash: number
    tradingPhase: string
    hasAccount: boolean
    ticket: { cash: number; lastPrice: number | null; position: { qty: number; availableQty: number; costPrice: number; lastPrice: number; profit: number; profitPct: number; sellableQty: number } | null } | null
  } | null
  list: {
    summary: { totalAssets: number; dayProfit: number; totalProfit: number }
    activeOrderCount: number
    watchlist: QuickQuote[]
    activeOrders: { id: string; name: string; direction: 'buy' | 'sell'; status: string; qty: number }[]
  } | null
}

const quick = ref<QuickSnapshot | null>(null)
const accPickerOpen = ref(false)
const sellConfirmOpen = ref(false)
const ticketError = ref('')

/** 票面本地表单态（Web 编辑，提交一次写回；lastPrice 用于市价/默认价展示） */
const ticket = ref({ direction: 'buy' as 'buy' | 'sell', priceType: 'limit' as 'limit' | 'market', priceText: '', qtyText: '' })
const ticketMetaName = computed(() => quick.value?.detail?.meta.name ?? '')
const ticketQty = computed(() => parseInt(ticket.value.qtyText || '0', 10) || 0)
const ticketLastPrice = computed(() => quick.value?.detail?.ticket?.lastPrice ?? quick.value?.detail?.meta.price ?? null)
const ticketCash = computed(() => quick.value?.detail?.ticket?.cash ?? 0)
const ticketSellable = computed(() => quick.value?.detail?.ticket?.position?.availableQty ?? 0)

const accActions = computed(() =>
  (quick.value?.accounts ?? []).map((a) => ({ name: a.name, value: a.id })),
)

function onAccSelect(action: { name: string; value: string }): void {
  void actQuick('selectAccount', { accountID: action.value })
}

/** 仓位 chips：买入按现金可买整手、卖出按可卖数量（提交时原生精确校验兜底） */
function applyPosition(ratio: number): void {
  const price = ticket.value.priceType === 'limit'
    ? (parseFloat(ticket.value.priceText) || ticketLastPrice.value || 0)
    : (ticketLastPrice.value || 0)
  if (ticket.value.direction === 'buy') {
    const affordable = Math.floor(((ticketCash.value * ratio) / Math.max(price, 0.01)) / 100) * 100
    ticket.value.qtyText = String(affordable)
  } else {
    ticket.value.qtyText = String(Math.floor(ticketSellable.value * ratio))
  }
}

function pickTicket(q: QuickQuote, direction: 'buy' | 'sell'): void {
  ticket.value = { direction, priceType: 'limit', priceText: '', qtyText: '' }
  ticketError.value = ''
  void actQuick('pickTicket', { file: q.file, direction })
}

/** 提交前本地预检（对齐原生票面：限价需价格、整手数量），提交带卖出二次确认 */
function submitTicket(): void {
  const qty = ticketQty.value
  if (ticket.value.priceType === 'limit' && !(parseFloat(ticket.value.priceText) > 0)) {
    ticketError.value = '请输入有效的委托价'
    return
  }
  if (qty <= 0) {
    ticketError.value = '请输入委托数量'
    return
  }
  ticketError.value = ''
  if (ticket.value.direction === 'sell') {
    sellConfirmOpen.value = true
    return
  }
  void doSubmit()
}

async function doSubmit(): Promise<void> {
  const meta = quick.value?.detail?.meta
  const accountID = quick.value?.accounts.find((a) => a.name === quick.value?.selectedName)?.id
  if (!meta || !accountID) {
    ticketError.value = '请先选择有效的模拟账户'
    return
  }
  try {
    await klineBus.request('trade', 'submit', {
      accountID,
      metaID: '',   // 原生按 file 反查？——metaID 用 file 由桥解析：改为传 file
      direction: ticket.value.direction,
      priceType: ticket.value.priceType,
      price: ticket.value.priceType === 'limit' ? parseFloat(ticket.value.priceText) : null,
      qty: ticketQty.value,
      file: meta.file,
    })
    showToast({ message: '委托已提交', duration: 1800 })
    await pullQuick()
  } catch (e) {
    ticketError.value = String(e instanceof Error ? e.message : e).slice(0, 60)
  }
}

function closeQuick(): void {
  klineBus.request('sheet', 'close', {}).catch((e) => console.error(e))
  activeName.value = null
}

async function actQuick(action: string, payload: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('quick', action, payload)
    await pullQuick()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

async function pullQuick(): Promise<void> {
  try {
    quick.value = ((await klineBus.request('quick', 'snapshot')) ?? {}) as unknown as QuickSnapshot
    // 票面默认值跟随最新价（对齐原生 didEditPrice=false 时 price=lastPrice；数量默认 100）
    const last = quick.value?.detail?.ticket?.lastPrice ?? quick.value?.detail?.meta.price ?? null
    if (last !== null && ticket.value.priceText === '') {
      ticket.value.priceText = String(last)
    }
    if (ticket.value.qtyText === '') {
      ticket.value.qtyText = '100'
    }
  } catch (e) {
    console.error('quick.snapshot 失败', e)
  }
}

async function cancelAll(): Promise<void> {
  await actQuick('cancelAll', {})
  showToast({ message: '撤单请求已提交', duration: 1600 })
}

async function closeAll(): Promise<void> {
  await actQuick('closeAll', {})
  showToast({ message: '清仓请求已提交', duration: 1600 })
}

// ===== 公式中心（P2-8a：tech 段浏览/删除；编辑与新建直进 Web 编辑器全屏页） =====
interface FormulaSnapshot {
  period: string
  mainItems: { id: string; name: string; isSystem: boolean; hasTemplate: boolean }[]
  subGroups: { group: string; kinds: string[] }[]
  customs: { id: string; name: string; colorHex: string; scope: 'main' | 'sub'; periods: string[] }[]
}

const formula = ref<FormulaSnapshot | null>(null)

async function pullFormula(): Promise<void> {
  try {
    formula.value = ((await klineBus.request('chart', 'formula.snapshot')) ?? {}) as unknown as FormulaSnapshot
  } catch (e) {
    console.error('formula.snapshot 失败', e)
  }
}

async function deleteCustom(c: { id: string; name: string }): Promise<void> {
  try {
    await klineBus.request('chart', 'formula.deleteCustom', { id: c.id })
    showToast({ message: `已删除「${c.name}」`, duration: 1600 })
    await pullFormula()
  } catch (e) {
    showToast({ message: String(e instanceof Error ? e.message : e).slice(0, 40), duration: 1800 })
  }
}

function openEditor(target: { target: 'system'; id: string; isMain: boolean } | { target: 'custom'; id?: string }): void {
  // 编辑/新建直进 Web 编辑器全屏页（原生侧关面板 + 打开 formulaEditor；本地同步清理）
  klineBus.request('chart', 'formula.openEditor', target as unknown as Record<string, unknown>).catch((e) => console.error(e))
  activeName.value = null
}

// ===== 训练设置浮层（P2-6c-3；表单态 Web 本地，数据动作走 training.*） =====
const trainCategories = ['全部', '沪深主板', 'ETF 指数', '自选', '我的分组']
const trainAccountTypes = [
  { value: 'percent', title: '百分比账户' },
  { value: 'fixedAmount', title: '仓位金额账户' },
] as const
const trainTradeModes = [
  { value: 'sameDayClose', title: '当日收盘价成交' },
  { value: 'nextDayClose', title: '隔日委托' },
] as const

const trainPrefs = ref<TrainingSetupSnapshot | null>(null)
const trainGroups = ref<{ id: string; name: string }[]>([])
const trainCategory = ref('全部')
const trainGroupID = ref<string>('')
const trainAccountType = ref<'percent' | 'fixedAmount'>('percent')
const trainCapitalText = ref('100000')
const trainTradeMode = ref<'sameDayClose' | 'nextDayClose'>('sameDayClose')
const trainSelected = ref<{ file: string; name: string; code: string } | null>(null)
const trainRange = ref<{ min: number; max: number; trainable: boolean } | null>(null)
const trainStartDate = ref<number | null>(null)
const trainDateInput = ref('')
const trainKeyword = ref('')
const trainResults = ref<TrainingSearchResult[]>([])
const trainError = ref('')
const trainReselectOpen = ref(false)
const trainReselectMessage = ref('')
let trainSearchTimer: ReturnType<typeof setTimeout> | null = null

const trainDateText = computed(() =>
  trainStartDate.value ? ymd(trainStartDate.value) : '未选择')
const trainRangeText = computed(() =>
  trainRange.value && trainRange.value.min > 0
    ? `${ymd(trainRange.value.min)} ~ ${ymd(trainRange.value.max)}` : '')
const canRandomDate = computed(() => !!trainRange.value?.trainable)
const canStartTraining = computed(() => {
  if (!trainSelected.value || !trainStartDate.value || !trainRange.value?.trainable) return false
  if (trainAccountType.value === 'fixedAmount') {
    const cap = Number.parseFloat(trainCapitalText.value.replace(/[^0-9.]/g, ''))
    if (!Number.isFinite(cap) || cap <= 0) return false
  }
  return true
})

/** YYYYMMDD → YYYY-MM-DD（date input 用） */
function ymd(v: number): string {
  const s = String(v)
  return s.length === 8 ? `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}` : s
}

/** YYYY-MM-DD → YYYYMMDD（本地时区，避免 UTC 偏移） */
function ymdInt(text: string): number {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text)
  if (!m) return 0
  return Number(m[1]) * 10000 + Number(m[2]) * 100 + Number(m[3])
}

async function pullTrainingSetup(): Promise<void> {
  try {
    const s = (await klineBus.request('training', 'setup.snapshot')) as unknown as TrainingSetupSnapshot
    trainPrefs.value = s
    trainGroups.value = s.groups ?? []
    trainAccountType.value = (s.prefs.accountType as 'percent' | 'fixedAmount') ?? 'percent'
    trainCapitalText.value = String(s.prefs.capitalText ?? '100000')
    trainTradeMode.value = (s.prefs.tradeMode as 'sameDayClose' | 'nextDayClose') ?? 'sameDayClose'
    if (!trainGroups.value.some((g) => g.id === trainGroupID.value)) {
      trainGroupID.value = trainGroups.value[0]?.id ?? ''
    }
  } catch (e) {
    console.error('training.setup.snapshot 失败', e)
  }
}

async function savePrefs(patch: Record<string, unknown>): Promise<void> {
  try {
    await klineBus.request('training', 'setPrefs', patch)
  } catch (e) {
    console.error('training.setPrefs 失败', e)
  }
}

function onTrainKeyword(): void {
  if (trainSearchTimer) clearTimeout(trainSearchTimer)
  trainSearchTimer = setTimeout(() => void runTrainSearch(), 300)
}

async function runTrainSearch(): Promise<void> {
  const kw = trainKeyword.value.trim()
  if (!kw) {
    trainResults.value = []
    return
  }
  try {
    const s = (await klineBus.request('training', 'search', { keyword: kw })) as Record<string, unknown>
    trainResults.value = (Array.isArray(s.results) ? s.results : []) as TrainingSearchResult[]
  } catch (e) {
    console.error('training.search 失败', e)
  }
}

/** 随机抽取：百分比路径响应直接带结果；金额路径 queued 等 changed(picked/pickFailed) */
function pickRandomTarget(): void {
  trainError.value = ''
  void klineBus.request('training', 'pickRandom', {
    category: trainCategory.value,
    groupID: trainCategory.value === '我的分组' ? (trainGroupID.value || null) : null,
    accountType: trainAccountType.value,
    capital: trainAccountType.value === 'fixedAmount'
      ? Number.parseFloat(trainCapitalText.value.replace(/[^0-9.]/g, '')) || null
      : null,
  }).then((data) => {
    const d = data as unknown as TrainingPickResult | undefined
    if (d?.file) void applyTrainPick(d)
  }).catch((e) => {
    trainError.value = String((e as Error).message ?? e).replace(/^invalid_payload: /, '')
  })
}

/** 抽中/选中后：拉日期区间并设起始日（抽中自带起始日；搜索选中随机一个自然日） */
async function applyTrainPick(pick: { file: string; name: string; code: string; startDate?: number }): Promise<void> {
  try {
    const a = (await klineBus.request('training', 'anchor', { file: pick.file })) as unknown as TrainingAnchorResult
    trainSelected.value = { file: pick.file, name: pick.name, code: pick.code }
    trainRange.value = { min: a.minDate ?? 0, max: a.maxDate ?? 0, trainable: a.trainable }
    if (a.trainable) {
      if (pick.startDate) trainStartDate.value = pick.startDate
      else randomizeTrainDate()
      trainDateInput.value = trainStartDate.value ? ymd(trainStartDate.value) : ''
    } else {
      trainStartDate.value = null
      trainDateInput.value = ''
    }
  } catch (e) {
    console.error('training.anchor 失败', e)
  }
}

function selectTrainTarget(r: TrainingSearchResult): void {
  trainError.value = ''
  trainKeyword.value = ''
  trainResults.value = []
  void applyTrainPick(r)
}

/** [min, max] 自然日随机（对齐原生 randomDate） */
function randomizeTrainDate(): void {
  const r = trainRange.value
  if (!r?.trainable || r.min <= 0 || r.max <= 0) return
  const lower = ymdToDate(r.min)
  const upper = ymdToDate(r.max)
  const days = Math.round((upper.getTime() - lower.getTime()) / 86_400_000)
  const offset = days > 0 ? Math.floor(Math.random() * (days + 1)) : 0
  const picked = new Date(lower.getTime() + offset * 86_400_000)
  trainStartDate.value = dateToYmdInt(picked)
  trainDateInput.value = ymd(trainStartDate.value)
}

function ymdToDate(v: number): Date {
  const s = String(v)
  return new Date(Number(s.slice(0, 4)), Number(s.slice(4, 6)) - 1, Number(s.slice(6, 8)))
}

function dateToYmdInt(d: Date): number {
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate()
}

/** date input 变更 → 起始日（钳制到区间内） */
watch(trainDateInput, (text) => {
  const v = ymdInt(text)
  if (!v) return
  const r = trainRange.value
  if (r && r.min > 0 && r.max > 0) {
    trainStartDate.value = Math.min(Math.max(v, r.min), r.max)
  } else {
    trainStartDate.value = v
  }
})

function startTraining(): void {
  if (!trainSelected.value || !trainStartDate.value) return
  trainError.value = ''
  void klineBus.request('training', 'begin', {
    file: trainSelected.value.file,
    startDate: trainStartDate.value,
    accountType: trainAccountType.value,
    capital: trainAccountType.value === 'fixedAmount'
      ? Number.parseFloat(trainCapitalText.value.replace(/[^0-9.]/g, '')) || null
      : null,
    tradeMode: trainTradeMode.value,
  }).catch((e) => {
    trainError.value = String((e as Error).message ?? e).replace(/^invalid_payload: /, '')
  })
}

function clearTrainTarget(): void {
  trainSelected.value = null
  trainRange.value = null
  trainStartDate.value = null
  trainDateInput.value = ''
}

function handleTrainingChanged(payload: Record<string, unknown> | undefined): void {
  const reason = String(payload?.['reason'] ?? '')
  if (reason === 'begun') {
    // 已开训：关面板进训练态（训练图表/快捷面板/回放由原生接管）
    close()
  } else if (reason === 'beginFailed') {
    trainError.value = String(payload?.['message'] ?? '')
  } else if (reason === 'beginReselect') {
    trainReselectMessage.value = String(payload?.['message'] ?? '')
    trainReselectOpen.value = true
  } else if (reason === 'picked') {
    void applyTrainPick(payload as unknown as { file: string; name: string; code: string; startDate?: number })
  } else if (reason === 'pickFailed') {
    trainError.value = String(payload?.['message'] ?? '')
  }
}

// ===== 打开路由（sheet.open 事件） =====
async function handleSheetOpen(payload: Record<string, unknown> | undefined): Promise<void> {
  const name = typeof payload?.name === 'string' ? payload.name : null
  activeName.value = name
  if (name === 'search') {
    keyword.value = ''
    results.value = []
  }
  if (name === 'quick') {
    ticket.value = { direction: 'buy', priceType: 'limit', priceText: '', qtyText: '' }
    ticketError.value = ''
    await pullQuick()
  }
  if (name === 'formulaCenter') {
    await pullFormula()
  }
  if (name === 'mainIndicators' || name === 'subIndicators') {
    activeSlotKey.value = typeof payload?.slot === 'string' ? payload.slot : null
    await pullIndicators()
  }
  if (name === 'training') {
    trainError.value = ''
    trainResults.value = []
    trainKeyword.value = ''
    await pullTrainingSetup()
  }
}

// ===== 动作 =====
function close(): void {
  klineBus.request('sheet', 'close', {}).catch((e) => console.error(e))
  activeName.value = null
}

// ===== 搜索（原生同款 300ms 防抖） =====
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
    const s = ((await klineBus.request('chart', 'search.query', { keyword: kw })) ?? {}) as Record<string, unknown>
    results.value = (Array.isArray(s.results) ? (s.results as Record<string, unknown>[]) : []).map((r) => ({
      file: String(r.file ?? ''),
      code: String(r.code ?? ''),
      name: String(r.name ?? ''),
      type: String(r.type ?? ''),
    }))
  } catch (e) {
    console.error('search.query 失败', e)
  }
}

function pick(r: ChartSearchResult): void {
  // 原生侧 pick 成功后自动 close（浮层遮罩由 Swift 切走），Web 端同步清理本地态
  klineBus.request('chart', 'search.pick', { file: r.file }).catch((e) => console.error(e))
  keyword.value = ''
  results.value = []
  activeName.value = null
}

onMounted(async () => {
  await klineBus.detect()
  klineBus.on('sheet.open', (ev) => void handleSheetOpen(ev.payload))
  klineBus.on('training.changed', (ev) => handleTrainingChanged(ev.payload))
  // dev/PC 调试循环：非 native 通道时支持 #/sheet?open=name 直开弹层，便于规则页迭代验证
  if (klineBus.transport !== 'native') {
    const open = new URLSearchParams(window.location.hash.split('?')[1] ?? '').get('open')
    if (open) await handleSheetOpen({ name: open })
  }
  // 浮层就绪拉取：sheet.open 事件可能早于本 WebView 创建/加载完成发出（首次打开时序）
  // → 事件丢失面板永不渲染；就绪后主动向宿主拉取当前待展示弹层
  try {
    await klineBus.request('sheet', 'ready', {})
  } catch (e) {
    console.error('sheet.ready 失败', e)
  }
})
</script>

<style scoped>
.sheet-page {
  width: 100vw;
  height: 100vh;
  position: relative;
  background: transparent;
}

/* ===== 训练设置浮层（居中卡片，对齐原生 TrainingSetupSheet） ===== */
.train-card {
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  width: min(520px, calc(100vw - 48px));
  height: min(62vh, 520px);
  min-height: 200px;
  background: var(--k-bg-secondary);
  border-radius: 20px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.train-header {
  display: flex;
  align-items: center;
  padding: 10px 4px 10px 16px;
  flex-shrink: 0;
}

.train-x {
  width: 44px;
  height: 44px;
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.train-body {
  flex: 1;
  overflow-y: auto;
  padding: 0 16px;
  border-top: 0.5px solid var(--k-divider, #c6c6c8);
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
}

.chip-row {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.chip {
  border: none;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 13px;
  height: 32px;
  padding: 0 14px;
  border-radius: 16px;
  cursor: pointer;
}

.chip.on {
  background: var(--k-accent);
  color: #ffffff;
  font-weight: 600;
}

.train-capital {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 0 2px;
}

.train-capital-input {
  width: 170px;
  height: 34px;
  border: none;
  border-radius: 8px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
}

.train-target-line {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 36px;
}

.train-target {
  flex: 1;
  font-size: 14px;
  font-weight: 500;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.train-target.none {
  font-weight: 400;
  color: var(--k-text-secondary);
}

.train-random {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 13px;
  font-weight: 500;
  cursor: pointer;
}

.train-random:disabled { color: var(--k-text-tertiary); cursor: default; }

.train-search {
  display: flex;
  align-items: center;
  gap: 6px;
  height: 36px;
  background: var(--k-bg);
  border-radius: 10px;
  padding: 0 10px;
}

.train-search-input {
  flex: 1;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 14px;
  outline: none;
}

.train-search-x {
  border: none;
  background: none;
  color: var(--k-text-secondary);
  font-size: 14px;
  cursor: pointer;
}

.train-results {
  background: var(--k-bg);
  border-radius: 10px;
  overflow: hidden;
  margin-top: 6px;
}

.train-result-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 9px 10px;
  border-bottom: 0.5px solid var(--k-divider, #c6c6c8);
  cursor: pointer;
}

.train-result-row:last-child { border-bottom: none; }

.train-untrainable {
  margin-left: auto;
  font-size: 11px;
  color: #ff9500;
}

.train-check {
  margin-left: auto;
  color: var(--k-accent);
  font-size: 12px;
}

.train-date-input {
  width: 100%;
  height: 36px;
  border: none;
  border-radius: 10px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 14px;
  padding: 0 10px;
  outline: none;
  margin-top: 4px;
}

.train-error {
  font-size: 12px;
  color: #ee0a24;
  padding: 8px 0 0;
}

.train-footer {
  display: flex;
  gap: 12px;
  padding: 14px 16px;
  flex-shrink: 0;
}

.train-cancel {
  flex: 1;
  height: 44px;
  border: none;
  border-radius: 12px;
  background: var(--k-bg);
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
}

.train-start {
  flex: 1;
  height: 44px;
  border: none;
  border-radius: 12px;
  background: var(--k-accent);
  color: #ffffff;
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.train-start:disabled {
  background: var(--k-bg);
  color: var(--k-text-tertiary);
  cursor: default;
}

.panel-mask {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.35);
}

/* ===== K线设置面板（底部 75%，顶角圆角，对齐原生 TopRoundedCornerRect） ===== */
.panel {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 75%;
  background: var(--k-bg);
  border-radius: 16px 16px 0 0;
  display: flex;
  flex-direction: column;
}

.panel-header {
  display: flex;
  align-items: center;
  padding: 12px 16px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.panel-title {
  flex: 1;
  font-size: 17px;
  font-weight: 600;
  color: var(--k-text);
}

.panel-done {
  border: none;
  background: none;
  color: var(--k-accent);
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}

.panel-body {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
}

.sec-title {
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 8px 2px 6px;
}

.sec-title.danger {
  color: #ee0a24;
}

/* 指标组合编辑页：全屏不透明容器（盖住设置面板，返回即关整个弹层链） */
.editor-full {
  position: fixed;
  inset: 0;
  z-index: 10;
  background: var(--k-bg);
}

.dialog-note {
  font-size: 13px;
  color: var(--k-text-secondary);
  padding: 12px 16px 20px;
  text-align: center;
}

/* ===== 图表搜索面板（顶部锚定，对齐原生 chartSearchBar） ===== */
.search-layer {
  background: var(--k-bg);
  padding: 4px 0;
}

.search-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 4px 6px;
}

.search-x {
  width: 24px;
  height: 24px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  flex-shrink: 0;
}

.search-field {
  flex: 1;
  padding: 0;
  background: none;
}

.search-clear {
  width: 24px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 14px;
  cursor: pointer;
}

.search-results {
  max-height: 320px;
  overflow-y: auto;
}

.search-empty {
  font-size: 13px;
  color: var(--k-text-tertiary);
  padding: 12px;
}

.search-row-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 9px 12px;
  cursor: pointer;
  border-bottom: 0.5px solid var(--k-border);
}

.sr-name {
  font-size: 14px;
  color: var(--k-text);
}

.sr-code {
  font-size: 12px;
  color: var(--k-text-secondary);
}

/* ===== 指标面板（P2-5b，对齐 ChartSheetKit 视觉令牌） ===== */
.panel-reset {
  border: none;
  background: none;
  color: #ee0a24;
  font-size: 13px;
  cursor: pointer;
  flex-shrink: 0;
}

.ind-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  padding: 0 0 6px;
}

.ind-tile,
.sub-tile {
  flex: 1 1 calc(25% - 8px);
  min-width: 80px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  border: 1px solid rgba(128, 128, 128, 0.25);
  border-radius: 8px;
  background: var(--k-bg-secondary);
  opacity: 0.45;
  color: var(--k-text);
  font-size: 13px;
  padding: 12px 4px;
  cursor: pointer;
}

.ind-tile.on,
.sub-tile.on {
  opacity: 1;
  border-color: #1989fa;
  background: var(--k-bg-secondary);
  font-weight: 600;
  color: #1989fa;
}

.ind-check {
  font-size: 14px;
}

.sub-tile {
  flex-direction: row;
  justify-content: center;
}

.param-entry {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border: none;
  border-radius: 8px;
  background: rgba(25, 137, 250, 0.08);
  color: #1989fa;
  font-size: 13px;
  padding: 12px 14px;
  margin: 8px 0;
  cursor: pointer;
}

.custom-rows {
  display: flex;
  flex-direction: column;
}

.custom-row {
  display: flex;
  align-items: center;
  min-height: 42px;
}

.custom-main {
  flex: 1;
  display: flex;
  align-items: center;
  gap: 10px;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 14px;
  padding: 9px 0;
  cursor: pointer;
  text-align: left;
}

.custom-check {
  font-size: 15px;
  color: #1989fa;
}

.custom-check:not(.on) {
  color: var(--k-text-tertiary);
}

.custom-color {
  width: 14px;
  height: 5px;
  border-radius: 2px;
  flex-shrink: 0;
}

.custom-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.custom-current {
  font-size: 10px;
  color: #1989fa;
}

.custom-edit {
  width: 32px;
  height: 32px;
  border: none;
  background: none;
  color: var(--k-text-tertiary);
  font-size: 13px;
  cursor: pointer;
}

.inline-btn {
  width: 44px;
  height: 30px;
  flex-shrink: 0;
  border: 1px solid var(--k-border);
  border-radius: 6px;
  background: none;
  color: #1989fa;
  font-size: 12px;
  cursor: pointer;
}

.inline-btn.cancel {
  color: #ee0a24;
}

/* ===== 快捷面板（P2-6a） ===== */
.quick-panel {
  height: 67%;
}

.qk-meta-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 12px;
  padding: 6px 0;
}

.qk-acc {
  font-weight: 600;
  color: var(--k-accent);
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.qk-cash {
  color: var(--k-text);
  font-variant-numeric: tabular-nums;
}

.qk-phase {
  color: var(--k-text-secondary);
  flex-shrink: 0;
}

.qk-quote {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 6px 0;
  border-top: 0.5px solid var(--k-border);
}

.q-price.big {
  font-size: 17px;
}

.qk-actions {
  display: flex;
  gap: 8px;
  padding: 8px 0;
}

.ticket {
  border: 0.5px solid var(--k-border);
  border-radius: 10px;
  padding: 8px 10px;
  margin: 4px 0;
}

.ticket-seg {
  display: flex;
  gap: 2px;
  background: var(--k-bg-secondary);
  border-radius: 7px;
  padding: 2px;
  margin-bottom: 8px;
}

.seg {
  flex: 1;
  border: none;
  border-radius: 5px;
  background: none;
  color: var(--k-text-secondary);
  font-size: 13px;
  padding: 6px 0;
  cursor: pointer;
}

.seg.buy.on {
  background: #ff4d4f;
  color: #ffffff;
  font-weight: 700;
}

.seg.sell.on {
  background: #00b578;
  color: #ffffff;
  font-weight: 700;
}

.ticket-row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 36px;
  border-bottom: 0.5px solid var(--k-border);
  font-size: 13px;
  color: var(--k-text-secondary);
}

.ticket-input {
  flex: 1;
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  text-align: right;
  font-variant-numeric: tabular-nums;
  outline: none;
  min-width: 0;
}

.ticket-input:disabled {
  color: var(--k-text-secondary);
}

.unit {
  color: var(--k-text-tertiary);
  font-size: 12px;
}

.pos-chips {
  display: flex;
  gap: 6px;
  padding: 8px 0;
}

.pos-chip {
  flex: 1;
  border: 1px solid var(--k-border);
  border-radius: 6px;
  background: none;
  color: var(--k-text-secondary);
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

.submit-btn.buy {
  background: #ff4d4f;
}

.submit-btn.sell {
  background: #00b578;
}

.pos-block {
  border-top: 0.5px solid var(--k-border);
}

.mini-btn {
  width: 30px;
  height: 24px;
  flex-shrink: 0;
  border: none;
  border-radius: 5px;
  color: #ffffff;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}

.mini-btn.buy {
  background: #ff4d4f;
}

.mini-btn.sell {
  background: #00b578;
}

.mini-orders {
  display: flex;
  flex-direction: column;
}

.mini-order {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 36px;
  font-size: 12.5px;
}
</style>

<style>
/* ===== 弹层浮层页专用全局覆盖（非 scoped，作用于本 WebView 实例的文档根） =====
 * SheetPage 的 WebView 以 isOpaque=false 加载（透明 WKWebView），
 * 但 theme.css 给 html/body 画了 var(--k-bg) 白底——全屏白块盖住下层 K 线图表
 * （2026-11-19 实测「面板打开后图表变白」根因）。此处将文档根透明化，
 * 面板外区域透出遮罩与图表。Tab 页 WebView 不受影响：各自根 div 有页面背景，
 * 且 WKWebView 层仍为 systemBackground 白底兜底。 */
html,
body {
  background: transparent !important;
}

#app {
  background: transparent;
  min-height: unset;
}
</style>
