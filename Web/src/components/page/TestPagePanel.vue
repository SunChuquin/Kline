<template>
  <div class="tpp">
    <!-- 页头：返回 ｜ 测试页面（对齐原生 ProfileView 头部） -->
    <div class="nav-line">
      <button class="nav-link" aria-label="testPage.back" @click="onBack">‹ 返回</button>
      <span class="nav-center">{{ detailTitle ? detailTitle : '测试页面' }}</span>
      <span style="width: 60px"></span>
    </div>

    <!-- 页内详情态（DetailPage 复刻：点任意 mock 项进入） -->
    <div v-if="detailTitle" class="detail">
      <div class="detail-icon">ⓘ</div>
      <div class="detail-title">{{ detailTitle }}</div>
      <div class="detail-text">这是「{{ detailTitle }}」的详情页面。你可以在这里展示更多相关内容。</div>
    </div>

    <!-- 列表态（ProfileView 复刻：顶部横滑 + 左右分栏双滚动） -->
    <div v-else class="content">
      <div class="card">
        <div class="card-head">
          <span class="card-title">{{ industry.title }}</span>
          <span v-if="industry.updateTime" class="card-time">{{ industry.updateTime }}</span>
          <span v-else-if="industry.showMore" class="card-more">›</span>
        </div>
        <div class="h-scroll">
          <button
            v-for="item in industry.items"
            :key="item.title"
            class="text-chip"
            :aria-label="`testPage.item.${item.title}`"
            @click="detailTitle = item.title"
          >
            <span class="text-chip-title">{{ item.title }}</span>
            <span class="text-chip-sub" :class="item.isUp ? 'up' : 'down'">{{ item.subtitle }}</span>
          </button>
        </div>
      </div>

      <div class="columns">
        <div class="col">
          <div v-for="card in leftCards" :key="card.title" class="card">
            <div class="card-head">
              <span class="card-title">{{ card.title }}</span>
              <span v-if="card.updateTime" class="card-time">{{ card.updateTime }}</span>
              <span v-else-if="card.showMore" class="card-more">›</span>
            </div>
            <div v-if="card.icons" class="h-scroll">
              <button
                v-for="item in card.items"
                :key="item.title"
                class="icon-item"
                :class="{ bare: !card.iconBg }"
                :aria-label="`testPage.item.${item.title}`"
                @click="detailTitle = item.title"
              >
                <span class="icon">{{ item.icon }}</span>
                <span class="icon-title">{{ item.title }}</span>
              </button>
            </div>
            <div v-else class="list">
              <button
                v-for="item in card.items"
                :key="item.title"
                class="list-row"
                :aria-label="`testPage.item.${item.title}`"
                @click="detailTitle = item.title"
              >
                <span class="rank" :class="{ top: (item.rank ?? 9) <= 3 }">{{ item.rank }}</span>
                <span class="list-title">{{ item.title }}</span>
                <span v-if="item.badge" class="badge" :class="item.badgeTone">{{ item.badge }}</span>
              </button>
            </div>
          </div>
        </div>

        <div class="col">
          <div v-for="card in rightCards" :key="card.title" class="card">
            <div class="card-head">
              <span class="card-title">{{ card.title }}</span>
              <span v-if="card.updateTime" class="card-time">{{ card.updateTime }}</span>
              <span v-else-if="card.showMore" class="card-more">›</span>
            </div>
            <div v-if="card.icons" class="h-scroll">
              <button
                v-for="item in card.items"
                :key="item.title"
                class="icon-item"
                :class="{ bare: !card.iconBg }"
                :aria-label="`testPage.item.${item.title}`"
                @click="detailTitle = item.title"
              >
                <span class="icon">{{ item.icon }}</span>
                <span class="icon-title">{{ item.title }}</span>
              </button>
            </div>
            <div v-else class="list">
              <button
                v-for="item in card.items"
                :key="item.title"
                class="list-row"
                :aria-label="`testPage.item.${item.title}`"
                @click="detailTitle = item.title"
              >
                <span class="rank" :class="{ top: (item.rank ?? 9) <= 3 }">{{ item.rank }}</span>
                <span class="list-title">{{ item.title }}</span>
                <span v-if="item.badge" class="badge" :class="item.badgeTone">{{ item.badge }}</span>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
// P2 Web 化收尾：测试页（testPage）。原生 ProfileView 为纯 mock 演示页（假数据 + 占位
// 详情页，无任何业务依赖），Web 端静态复刻、零桥协议动作（打开走 page.open("testPage")，
// 关闭走 page.close）；点任意 mock 项进页内详情态（DetailPage 复刻）。
// 模拟 Tab 双击入口已改桥（ContentView.handleTabTap）。
import { ref } from 'vue'

const emit = defineEmits<{ (e: 'close'): void }>()

const detailTitle = ref('')

// mock 数据（原生 MockData.swift 同款，纯静态）
const industry = {
  title: '热门行业', showMore: true, updateTime: null as string | null,
  items: [
    { title: '半导体', subtitle: '+5.23%', isUp: true },
    { title: '证券', subtitle: '+3.85%', isUp: true },
    { title: '保险', subtitle: '+2.12%', isUp: true },
    { title: '银行', subtitle: '+1.56%', isUp: true },
    { title: '医药', subtitle: '-1.23%', isUp: false },
    { title: '房地产', subtitle: '-0.85%', isUp: false },
  ],
}

interface IconCard {
  title: string
  showMore: boolean
  updateTime: string | null
  icons: true
  iconBg: boolean
  items: { icon: string; title: string }[]
}
interface ListTitledCard {
  title: string
  showMore: boolean
  updateTime: string | null
  icons: false
  items: { rank: number; title: string; badge: string | null; badgeTone: string }[]
}

const appRecommend: IconCard = {
  title: '应用推荐', showMore: true, updateTime: null, icons: true, iconBg: true,
  items: [
    { icon: '🛍', title: '我的持仓' }, { icon: '📈', title: '资金流向' },
    { icon: '✨', title: '技术选股' }, { icon: '🏢', title: '新股IPO' },
    { icon: '🔄', title: '强弱分析' }, { icon: '🏆', title: '龙虎榜' },
    { icon: '📅', title: '潜伏日历' }, { icon: '💬', title: '意见反馈' },
  ],
}
const hotNews: ListTitledCard = {
  title: '今日热点', showMore: false, updateTime: '更新于 19:44', icons: false,
  items: [
    { rank: 1, title: '第二批公募业绩基准调整全面铺开，最...', badge: '热', badgeTone: 'red' },
    { rank: 2, title: '史上最重！证监会出手，两家私募合计...', badge: '热', badgeTone: 'red' },
    { rank: 3, title: '闪电开户，0元领L2>>', badge: null, badgeTone: 'gray' },
    { rank: 4, title: '新能源赛道迎来重大利好，机构纷纷加仓', badge: null, badgeTone: 'gray' },
    { rank: 5, title: '科技股集体爆发，半导体领涨市场', badge: '热', badgeTone: 'red' },
  ],
}
const marketDynamic: IconCard = {
  title: '市场动态', showMore: true, updateTime: '刚刚更新', icons: true, iconBg: true,
  items: [
    { icon: '📈', title: '涨幅榜' }, { icon: '📉', title: '跌幅榜' },
    { icon: '⭐', title: '人气榜' }, { icon: '🕐', title: '今日复盘' },
    { icon: '📰', title: '财经资讯' }, { icon: '🥧', title: '板块轮动' },
  ],
}
const dataCenter: IconCard = {
  title: '数据中心', showMore: true, updateTime: null, icons: true, iconBg: false,
  items: [
    { icon: '📅', title: '打新日历' }, { icon: '📄', title: '研报' },
    { icon: '🔥', title: '涨停聚焦' }, { icon: '📈', title: '投资机会' },
  ],
}
const toolCenter: IconCard = {
  title: '工具中心', showMore: false, updateTime: null, icons: true, iconBg: true,
  items: [
    { icon: '🧮', title: '计算器' }, { icon: '📏', title: '度量工具' },
    { icon: '🧭', title: '指南针' }, { icon: '⏱', title: '倒计时' },
    { icon: '🎯', title: '目标设置' },
  ],
}
const moreNews: ListTitledCard = {
  title: '财经要闻', showMore: true, updateTime: '5分钟前更新', icons: false,
  items: [
    { rank: 1, title: '央行宣布下调存款准备金率0.5个百分点', badge: '重要', badgeTone: 'orange' },
    { rank: 2, title: '新能源汽车销量创新高，产业链迎机遇', badge: '热', badgeTone: 'red' },
    { rank: 3, title: '半导体行业迎来政策利好，龙头企业受益', badge: null, badgeTone: 'gray' },
    { rank: 4, title: '医药板块持续调整，机构建议关注低估值标的', badge: null, badgeTone: 'gray' },
    { rank: 5, title: '消费复苏态势明显，零售板块有望反弹', badge: '新', badgeTone: 'green' },
    { rank: 6, title: '人工智能应用加速落地，相关概念股走强', badge: '热', badgeTone: 'red' },
    { rank: 7, title: '光伏产业景气度高企，组件价格企稳回升', badge: null, badgeTone: 'gray' },
    { rank: 8, title: '银行板块估值修复，中长期投资价值显现', badge: null, badgeTone: 'gray' },
  ],
}

const leftCards: (IconCard | ListTitledCard)[] = [appRecommend, hotNews, marketDynamic, moreNews]
const rightCards: (IconCard | ListTitledCard)[] = [dataCenter, toolCenter, moreNews, appRecommend]

/** 返回：详情态回列表，列表态关页回模拟 Tab */
function onBack(): void {
  if (detailTitle.value) {
    detailTitle.value = ''
  } else {
    emit('close')
  }
}
</script>

<style scoped>
.nav-line {
  display: flex;
  align-items: center;
  height: 48px;
  padding: 0 8px;
  border-bottom: 0.5px solid var(--k-border);
  flex-shrink: 0;
}

.nav-link {
  border: none;
  background: none;
  color: var(--k-text);
  font-size: 15px;
  font-weight: 500;
  cursor: pointer;
  padding: 8px 10px;
}

.nav-center {
  flex: 1;
  text-align: center;
  font-size: 16px;
  font-weight: 600;
  color: var(--k-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tpp {
  height: 100vh;
  display: flex;
  flex-direction: column;
  background: var(--k-bg);
  color: var(--k-text);
}

.content {
  flex: 1;
  overflow-y: auto;
  padding: 16px;
}

.card {
  background: var(--k-bg-secondary);
  border-radius: 12px;
  padding: 12px;
  margin-bottom: 16px;
}

.card-head {
  display: flex;
  align-items: center;
  margin-bottom: 12px;
}

.card-title {
  font-size: 15px;
  font-weight: 700;
}

.card-time {
  margin-left: auto;
  font-size: 12px;
  color: var(--k-text-tertiary);
}

.card-more {
  margin-left: auto;
  font-size: 15px;
  color: var(--k-text-tertiary);
}

.h-scroll {
  display: flex;
  gap: 12px;
  overflow-x: auto;
  padding-bottom: 2px;
}

/* 文字型 chip（热门行业：红涨绿跌） */
.text-chip {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  border: none;
  background: var(--k-bg);
  border-radius: 8px;
  padding: 10px 16px;
  cursor: pointer;
  flex-shrink: 0;
}

.text-chip-title {
  font-size: 13px;
  color: var(--k-text);
}

.text-chip-sub {
  font-size: 12px;
  font-weight: 500;
}

.text-chip-sub.up { color: #ee0a24; }
.text-chip-sub.down { color: #07c160; }

/* 图标卡（SF Symbols 以 emoji 等价呈现） */
.icon-item {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 8px;
  border: none;
  background: none;
  cursor: pointer;
  flex-shrink: 0;
  padding: 0;
}

.icon-item .icon {
  width: 52px;
  height: 52px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 26px;
  border-radius: 12px;
  background: var(--k-bg);
}

.icon-item.bare .icon {
  background: transparent;
}

.icon-title {
  font-size: 12px;
  color: var(--k-text);
}

/* 列表卡 */
.list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.list-row {
  display: flex;
  align-items: center;
  gap: 12px;
  border: none;
  background: none;
  cursor: pointer;
  padding: 0;
  text-align: left;
}

.rank {
  width: 24px;
  text-align: center;
  font-size: 14px;
  font-weight: 700;
  color: var(--k-text-tertiary);
  flex-shrink: 0;
}

.rank.top {
  color: #ee0a24;
}

.list-title {
  font-size: 14px;
  color: var(--k-text);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  flex: 1;
}

.badge {
  font-size: 11px;
  color: #ffffff;
  padding: 2px 6px;
  border-radius: 4px;
  flex-shrink: 0;
}

.badge.red { background: #ee0a24; }
.badge.orange { background: #ff976a; }
.badge.green { background: #07c160; }
.badge.gray { background: var(--k-text-tertiary); }

/* 左右分栏双滚动 */
.columns {
  display: flex;
  gap: 12px;
  align-items: flex-start;
}

.col {
  flex: 1;
  min-width: 0;
  max-height: calc(100vh - 220px);
  overflow-y: auto;
}

/* 页内详情态 */
.detail {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 16px;
  padding: 0 32px;
  text-align: center;
}

.detail-icon {
  font-size: 52px;
  color: #1989fa;
}

.detail-title {
  font-size: 20px;
  font-weight: 700;
}

.detail-text {
  font-size: 14px;
  color: var(--k-text-tertiary);
  line-height: 1.6;
}
</style>
