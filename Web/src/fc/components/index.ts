// fc/components/index.ts：k-* 自定义组件注册表（运行时与设计器共用同一源码）。
// 组件名即规则 JSON 中的 type（form-create 自定义组件）。
import type { Component } from 'vue'
import KActionsRow from './KActionsRow.vue'
import KAlertCards from './KAlertCards.vue'
import KBacktestProgress from './KBacktestProgress.vue'
import KBaselineSheet from './KBaselineSheet.vue'
import KCardLines from './KCardLines.vue'
import KChipGroup from './KChipGroup.vue'
import KChipSections from './KChipSections.vue'
import KColorGrid from './KColorGrid.vue'
import KComboRowList from './KComboRowList.vue'
import KCondCards from './KCondCards.vue'
import KCondOrderList from './KCondOrderList.vue'
import KConfirmBar from './KConfirmBar.vue'
import KCustomRowList from './KCustomRowList.vue'
import KDraftGroups from './KDraftGroups.vue'
import KEditorNav from './KEditorNav.vue'
import KEmptyBlock from './KEmptyBlock.vue'
import KEntryList from './KEntryList.vue'
import KFavoritesView from './KFavoritesView.vue'
import KFormulaInput from './KFormulaInput.vue'
import KFormulaRowList from './KFormulaRowList.vue'
import KHitList from './KHitList.vue'
import KHomeCards from './KHomeCards.vue'
import KHomeEntries from './KHomeEntries.vue'
import KHomeHeader from './KHomeHeader.vue'
import KIndTileGrid from './KIndTileGrid.vue'
import KLabBusy from './KLabBusy.vue'
import KLanConfigure from './KLanConfigure.vue'
import KLanDevices from './KLanDevices.vue'
import KLanRunning from './KLanRunning.vue'
import KMarketView from './KMarketView.vue'
import KMetricGrid from './KMetricGrid.vue'
import KMiniOrderList from './KMiniOrderList.vue'
import KMockColumn from './KMockColumn.vue'
import KMockIndustryCard from './KMockIndustryCard.vue'
import KNavRow from './KNavRow.vue'
import KNetChart from './KNetChart.vue'
import KNoticeCard from './KNoticeCard.vue'
import KOutConsole from './KOutConsole.vue'
import KParamEntry from './KParamEntry.vue'
import KPickProgress from './KPickProgress.vue'
import KProfileHeader from './KProfileHeader.vue'
import KProgressCard from './KProgressCard.vue'
import KQuoteList from './KQuoteList.vue'
import KRefRowList from './KRefRowList.vue'
import KResultRowList from './KResultRowList.vue'
import KRuleRowList from './KRuleRowList.vue'
import KSearchResultList from './KSearchResultList.vue'
import KSecTitle from './KSecTitle.vue'
import KSegTabs from './KSegTabs.vue'
import KSessionRows from './KSessionRows.vue'
import KSimulationView from './KSimulationView.vue'
import KSkipList from './KSkipList.vue'
import KSnapCard from './KSnapCard.vue'
import KStatCards from './KStatCards.vue'
import KSubpage from './KSubpage.vue'
import KTextRow from './KTextRow.vue'
import KTicket from './KTicket.vue'
import KTicketForm from './KTicketForm.vue'
import KToastBar from './KToastBar.vue'
import KToolLink from './KToolLink.vue'
import KTradeTable from './KTradeTable.vue'
import KTrainingTradeTable from './KTrainingTradeTable.vue'

export const kComponents: Record<string, Component> = {
  'k-actions-row': KActionsRow,
  'k-alert-cards': KAlertCards,
  'k-backtest-progress': KBacktestProgress,
  'k-baseline-sheet': KBaselineSheet,
  'k-card-lines': KCardLines,
  'k-chip-group': KChipGroup,
  'k-chip-sections': KChipSections,
  'k-color-grid': KColorGrid,
  'k-combo-row-list': KComboRowList,
  'k-cond-cards': KCondCards,
  'k-cond-order-list': KCondOrderList,
  'k-confirm-bar': KConfirmBar,
  'k-custom-row-list': KCustomRowList,
  'k-draft-groups': KDraftGroups,
  'k-editor-nav': KEditorNav,
  'k-empty-block': KEmptyBlock,
  'k-entry-list': KEntryList,
  'k-favorites-view': KFavoritesView,
  'k-formula-input': KFormulaInput,
  'k-formula-row-list': KFormulaRowList,
  'k-hit-list': KHitList,
  'k-home-cards': KHomeCards,
  'k-home-entries': KHomeEntries,
  'k-home-header': KHomeHeader,
  'k-ind-tile-grid': KIndTileGrid,
  'k-lab-busy': KLabBusy,
  'k-lan-configure': KLanConfigure,
  'k-lan-devices': KLanDevices,
  'k-lan-running': KLanRunning,
  'k-market-view': KMarketView,
  'k-metric-grid': KMetricGrid,
  'k-mini-order-list': KMiniOrderList,
  'k-mock-column': KMockColumn,
  'k-mock-industry-card': KMockIndustryCard,
  'k-nav-row': KNavRow,
  'k-net-chart': KNetChart,
  'k-notice-card': KNoticeCard,
  'k-out-console': KOutConsole,
  'k-param-entry': KParamEntry,
  'k-pick-progress': KPickProgress,
  'k-profile-header': KProfileHeader,
  'k-progress-card': KProgressCard,
  'k-quote-list': KQuoteList,
  'k-ref-row-list': KRefRowList,
  'k-result-row-list': KResultRowList,
  'k-rule-row-list': KRuleRowList,
  'k-search-result-list': KSearchResultList,
  'k-sec-title': KSecTitle,
  'k-seg-tabs': KSegTabs,
  'k-session-rows': KSessionRows,
  'k-simulation-view': KSimulationView,
  'k-skip-list': KSkipList,
  'k-snap-card': KSnapCard,
  'k-stat-cards': KStatCards,
  'k-subpage': KSubpage,
  'k-text-row': KTextRow,
  'k-ticket': KTicket,
  'k-ticket-form': KTicketForm,
  'k-toast-bar': KToastBar,
  'k-tool-link': KToolLink,
  'k-trade-table': KTradeTable,
  'k-training-trade-table': KTrainingTradeTable,
}
