//
//  SimulationLayoutDefaults.swift
//  Kline
//
//  模拟页内置默认布局配置（JSON 文本）。
//  首启由 SimulationView 种入沙盒 Documents/Layouts/simulation.json；
//  把沙盒删掉后会重新种回这份内容。
//  内容等价搬迁现行 SimulationLayoutA/B/CView 三档（行为口径一致），
//  仅有的微小差别：紧凑态 A 的账户抽屉由容器 overlay 呈现（遮罩范围 = 页面内容区）；
//  B 的「高度不足才滚动」在配置里统一为纵向滚动（不满一屏时视觉完全一致）；
//  C 顶栏「资金」入口统一为「资金管理」（弹窗资产概览，信息量比轻提示更多）。
//

let simulationLayoutDefaultsJSON = """
{
  "schemaVersion": 1,
  "page": "simulation",
  "default": "A",
  "layouts": {
    "A": {
      "title": "A · 账户侧栏 + 工作区",
      "shortTitle": "A",
      "root": {
        "type": "hstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "sim.accountSidebar" },
          { "type": "divider" },
          {
            "type": "vstack", "spacing": 0, "alignment": "leading",
            "children": [
              { "type": "widget", "name": "sim.summaryBand" },
              { "type": "widget", "name": "sim.moduleToolbar",
                "params": { "sidebarOffset": 216, "logActions": true } },
              { "type": "widget", "name": "sim.logFilterBar" },
              { "type": "widget", "name": "sim.moduleTable",
                "params": { "sidebarOffset": 216 } },
              { "type": "widget", "name": "sim.bottomActionBar" }
            ]
          }
        ]
      }
    },
    "B": {
      "title": "B · 账户卡片 + 模块宫格",
      "shortTitle": "B",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "sim.topBar",
            "params": { "title": "模拟交易",
                        "hint": "点账户卡进入该账户，点模块卡进入明细",
                        "entries": ["condOrder", "strategyFormula", "trainingRecord", "wallet"] } },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": false, "spacing": 0,
            "children": [
              { "type": "widget", "name": "sim.accountCards" },
              { "type": "widget", "name": "sim.moduleGrid" }
            ]
          },
          { "type": "widget", "name": "sim.bottomActionBar",
            "params": { "hint": "模块卡只放摘要与快捷动作，明细进入全屏列表" } }
        ]
      }
    },
    "C": {
      "title": "C · 券商经典顶栏式",
      "shortTitle": "C",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "sim.topBar",
            "params": { "title": "模拟交易", "chip": true,
                        "entries": ["wallet", "settings"] } },
          { "type": "widget", "name": "sim.assetMetrics" },
          { "type": "widget", "name": "sim.moduleToolbar" },
          { "type": "widget", "name": "sim.logFilterBar" },
          { "type": "widget", "name": "sim.moduleTable" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": false, "spacing": 0,
            "padding": { "top": 6, "leading": 14, "trailing": 14 },
            "children": [
              { "type": "hstack", "spacing": 10,
                "children": [
                  { "type": "widget", "name": "sim.pendingCard" },
                  { "type": "widget", "name": "sim.fillsCard" }
                ] }
            ]
          },
          { "type": "widget", "name": "sim.bottomActionBar",
            "params": { "hint": "最接近通达信 / 同花顺 iPad 的经典布局，表格最宽；多账户收进顶部下拉" } }
        ]
      }
    }
  }
}
"""
