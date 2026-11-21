// fc/components/index.ts：k-* 自定义组件注册表（运行时与设计器共用同一源码）。
// 组件名即规则 JSON 中的 type（form-create 自定义组件）。
import type { Component } from 'vue'
import KChipGroup from './KChipGroup.vue'
import KComboRowList from './KComboRowList.vue'
import KProgressCard from './KProgressCard.vue'
import KQuoteList from './KQuoteList.vue'
import KMiniOrderList from './KMiniOrderList.vue'
import KTicket from './KTicket.vue'
import KCustomRowList from './KCustomRowList.vue'
import KIndTileGrid from './KIndTileGrid.vue'
import KResultRowList from './KResultRowList.vue'
import KStatCards from './KStatCards.vue'
import KSecTitle from './KSecTitle.vue'
import KNavRow from './KNavRow.vue'
import KParamEntry from './KParamEntry.vue'
import KFormulaRowList from './KFormulaRowList.vue'
import KChipSections from './KChipSections.vue'
import KTextRow from './KTextRow.vue'
import KActionsRow from './KActionsRow.vue'

export const kComponents: Record<string, Component> = {
  'k-chip-group': KChipGroup,
  'k-combo-row-list': KComboRowList,
  'k-progress-card': KProgressCard,
  'k-quote-list': KQuoteList,
  'k-mini-order-list': KMiniOrderList,
  'k-ticket': KTicket,
  'k-custom-row-list': KCustomRowList,
  'k-ind-tile-grid': KIndTileGrid,
  'k-result-row-list': KResultRowList,
  'k-stat-cards': KStatCards,
  'k-sec-title': KSecTitle,
  'k-nav-row': KNavRow,
  'k-param-entry': KParamEntry,
  'k-formula-row-list': KFormulaRowList,
  'k-chip-sections': KChipSections,
  'k-text-row': KTextRow,
  'k-actions-row': KActionsRow,
}
