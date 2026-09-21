//
//  HomeLayoutDefaults.swift
//  Kline
//
//  首页内置默认布局配置（JSON 文本）。
//  首启由 PageLayoutConfigStore 种入沙盒 Documents/Layouts/home.json；
//  把沙盒删掉后会重新种回这份内容。
//  内容等价搬迁现行 HomeLayoutA/B/C/DView 四档（行为零变化）。
//

let homeLayoutDefaultsJSON = """
{
  "schemaVersion": 1,
  "page": "home",
  "default": "B",
  "layouts": {
    "A": {
      "title": "A · 现有首页（保留）",
      "shortTitle": "A",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.placeholder" }
        ]
      }
    },
    "B": {
      "title": "B · 横滑入口 + 卡片网格（默认）",
      "shortTitle": "B",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.quickEntryRow" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": true,
            "padding": { "top": 16, "leading": 16, "bottom": 16, "trailing": 16 },
            "spacing": 12,
            "children": [
              { "type": "card", "title": "大盘概览",
                "child": { "type": "widget", "name": "home.marketOverview",
                           "params": { "compact": false } } },
              { "type": "hstack", "alignment": "top", "spacing": 12,
                "children": [
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "我的自选",
                               "child": { "type": "widget", "name": "home.favorites",
                                          "params": { "compact": false, "showsSparkline": true } } } },
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "模拟账户",
                               "child": { "type": "widget", "name": "home.simSummary",
                                          "params": { "compact": false } } } }
                ] },
              { "type": "card", "title": "涨幅榜",
                "child": { "type": "widget", "name": "home.topGainers",
                           "params": { "style": "list", "compact": false } } }
            ]
          }
        ]
      }
    },
    "C": {
      "title": "C · 横滑入口 + 分区列表",
      "shortTitle": "C",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.quickEntryRow" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": true,
            "padding": { "top": 16, "leading": 16, "bottom": 16, "trailing": 16 },
            "spacing": 12,
            "children": [
              { "type": "card", "title": "大盘概览", "compact": true,
                "child": { "type": "widget", "name": "home.marketOverview",
                           "params": { "compact": true } } },
              { "type": "card", "title": "我的自选", "compact": true,
                "child": { "type": "widget", "name": "home.favorites",
                           "params": { "compact": true, "showsSparkline": false } } },
              { "type": "card", "title": "模拟账户", "compact": true,
                "child": { "type": "widget", "name": "home.simSummary",
                           "params": { "compact": true } } },
              { "type": "card", "title": "涨幅榜", "compact": true,
                "child": { "type": "widget", "name": "home.topGainers",
                           "params": { "style": "list", "compact": true } } }
            ]
          }
        ]
      }
    },
    "D": {
      "title": "D · 横滑入口 + 工作台混排",
      "shortTitle": "D",
      "root": {
        "type": "vstack", "spacing": 0,
        "children": [
          { "type": "widget", "name": "home.header" },
          { "type": "divider" },
          { "type": "widget", "name": "home.quickEntryRow" },
          {
            "type": "scroll", "axis": "vertical", "showsIndicators": true,
            "padding": { "top": 16, "leading": 16, "bottom": 16, "trailing": 16 },
            "spacing": 12,
            "children": [
              { "type": "card", "title": "大盘概览",
                "child": { "type": "widget", "name": "home.marketOverview",
                           "params": { "compact": false } } },
              { "type": "hstack", "alignment": "top", "spacing": 12,
                "children": [
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "模拟账户", "compact": true,
                               "child": { "type": "widget", "name": "home.simSummary",
                                          "params": { "compact": true } } } },
                  { "type": "frame", "maxWidth": "infinity", "alignment": "top",
                    "child": { "type": "card", "title": "我的自选", "compact": true,
                               "child": { "type": "widget", "name": "home.favorites",
                                          "params": { "compact": true, "showsSparkline": false, "limit": 3 } } } }
                ] },
              { "type": "card", "title": "涨幅榜",
                "child": { "type": "widget", "name": "home.topGainers",
                           "params": { "style": "chips", "compact": false } } }
            ]
          }
        ]
      }
    }
  }
}
"""