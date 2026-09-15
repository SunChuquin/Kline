//
//  MockData.swift
//  Kline
//
//  Created by 孙楚昆 on 2026/6/30.
//

import SwiftUI

// MARK: - 通用横向滚动卡片数据结构
struct HorizontalCardItem: Identifiable {
    let id = UUID()
    let icon: String?           // 图标名称（nil表示无图标）
    let title: String           // 主标题
    let subtitle: String?       // 副标题/数值（如涨跌幅）
    let color: Color            // 图标颜色
    let showBackground: Bool    // 是否显示背景

    // 便捷初始化方法 - 图标类型
    init(icon: String, title: String, color: Color = .blue, showBackground: Bool = true) {
        self.icon = icon
        self.title = title
        self.subtitle = nil
        self.color = color
        self.showBackground = showBackground
    }

    // 便捷初始化方法 - 文字类型
    init(title: String, subtitle: String, isUp: Bool = true, showBackground: Bool = true) {
        self.icon = nil
        self.title = title
        self.subtitle = subtitle
        self.color = isUp ? .red : .green
        self.showBackground = showBackground
    }
}

// MARK: - 横向滚动卡片配置数据
struct HorizontalCardData {
    let title: String
    let showMore: Bool
    let updateTime: String?
    let items: [HorizontalCardItem]
}

// MARK: - 应用推荐数据
let appRecommendData = HorizontalCardData(
    title: "应用推荐",
    showMore: true,
    updateTime: nil,
    items: [
        HorizontalCardItem(icon: "bag.fill", title: "我的持仓", color: .orange),
        HorizontalCardItem(icon: "arrow.up.circle", title: "资金流向", color: .red),
        HorizontalCardItem(icon: "sparkles", title: "技术选股", color: .blue),
        HorizontalCardItem(icon: "building", title: "新股IPO", color: .purple),
        HorizontalCardItem(icon: "arrow.up.arrow.down", title: "强弱分析", color: .green),
        HorizontalCardItem(icon: "trophy", title: "龙虎榜", color: .yellow),
        HorizontalCardItem(icon: "calendar", title: "潜伏日历", color: .cyan),
        HorizontalCardItem(icon: "bubble.left", title: "意见反馈", color: .indigo)
    ]
)

// MARK: - 通用列表卡片数据结构
struct ListCardItem: Identifiable {
    let id = UUID()
    let rank: Int?              // 排名（nil表示不显示）
    let title: String           // 标题
    let subtitle: String?       // 副标题
    let badge: String?          // 徽章文字（如"热"）
    let badgeColor: Color       // 徽章颜色

    // 便捷初始化方法
    init(rank: Int? = nil, title: String, subtitle: String? = nil, badge: String? = nil, badgeColor: Color = .gray) {
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.badgeColor = badgeColor
    }
}

// MARK: - 列表卡片配置数据
struct ListCardData {
    let title: String
    let showMore: Bool
    let updateTime: String?
    let items: [ListCardItem]
}

// MARK: - 今日热点数据（适配为通用格式）
let hotNewsData = ListCardData(
    title: "今日热点",
    showMore: false,
    updateTime: "更新于 19:44",
    items: [
        ListCardItem(rank: 1, title: "第二批公募业绩基准调整全面铺开，最...", badge: "热", badgeColor: .red),
        ListCardItem(rank: 2, title: "史上最重！证监会出手，两家私募合计...", badge: "热", badgeColor: .red),
        ListCardItem(rank: 3, title: "闪电开户，0元领L2>>", badge: nil, badgeColor: .gray),
        ListCardItem(rank: 4, title: "新能源赛道迎来重大利好，机构纷纷加仓", badge: nil, badgeColor: .gray),
        ListCardItem(rank: 5, title: "科技股集体爆发，半导体领涨市场", badge: "热", badgeColor: .red)
    ]
)

// MARK: - 热门行业数据
let industryData = HorizontalCardData(
    title: "热门行业",
    showMore: true,
    updateTime: nil,
    items: [
        HorizontalCardItem(title: "半导体", subtitle: "+5.23%", isUp: true),
        HorizontalCardItem(title: "证券", subtitle: "+3.85%", isUp: true),
        HorizontalCardItem(title: "保险", subtitle: "+2.12%", isUp: true),
        HorizontalCardItem(title: "银行", subtitle: "+1.56%", isUp: true),
        HorizontalCardItem(title: "医药", subtitle: "-1.23%", isUp: false),
        HorizontalCardItem(title: "房地产", subtitle: "-0.85%", isUp: false)
    ]
)

// MARK: - 数据中心数据
let dataCenterData = HorizontalCardData(
    title: "数据中心",
    showMore: true,
    updateTime: nil,
    items: [
        HorizontalCardItem(icon: "calendar", title: "打新日历", color: .blue, showBackground: false),
        HorizontalCardItem(icon: "doc.text", title: "研报", color: .green, showBackground: false),
        HorizontalCardItem(icon: "flame", title: "涨停聚焦", color: .red, showBackground: false),
        HorizontalCardItem(icon: "arrow.up.circle", title: "投资机会", color: .orange, showBackground: false)
    ]
)

// MARK: - 左侧额外数据（用于测试滚动）
let leftExtraData = HorizontalCardData(
    title: "市场动态",
    showMore: true,
    updateTime: "刚刚更新",
    items: [
        HorizontalCardItem(icon: "trending.up", title: "涨幅榜", color: .red),
        HorizontalCardItem(icon: "trending.down", title: "跌幅榜", color: .green),
        HorizontalCardItem(icon: "star", title: "人气榜", color: .orange),
        HorizontalCardItem(icon: "clock", title: "今日复盘", color: .blue),
        HorizontalCardItem(icon: "newspaper", title: "财经资讯", color: .purple),
        HorizontalCardItem(icon: "chart.pie", title: "板块轮动", color: .cyan)
    ]
)

// MARK: - 右侧额外数据（用于测试滚动）
let rightExtraData = HorizontalCardData(
    title: "工具中心",
    showMore: false,
    updateTime: nil,
    items: [
        HorizontalCardItem(icon: "calculator", title: "计算器", color: .blue),
        HorizontalCardItem(icon: "ruler", title: "度量工具", color: .green),
        HorizontalCardItem(icon: "compass", title: "指南针", color: .orange),
        HorizontalCardItem(icon: "timer", title: "倒计时", color: .red),
        HorizontalCardItem(icon: "target", title: "目标设置", color: .purple)
    ]
)

// MARK: - 更多热点数据（用于测试滚动）
let moreHotNewsData = ListCardData(
    title: "财经要闻",
    showMore: true,
    updateTime: "5分钟前更新",
    items: [
        ListCardItem(rank: 1, title: "央行宣布下调存款准备金率0.5个百分点", badge: "重要", badgeColor: .orange),
        ListCardItem(rank: 2, title: "新能源汽车销量创新高，产业链迎机遇", badge: "热", badgeColor: .red),
        ListCardItem(rank: 3, title: "半导体行业迎来政策利好，龙头企业受益", badge: nil, badgeColor: .gray),
        ListCardItem(rank: 4, title: "医药板块持续调整，机构建议关注低估值标的", badge: nil, badgeColor: .gray),
        ListCardItem(rank: 5, title: "消费复苏态势明显，零售板块有望反弹", badge: "新", badgeColor: .green),
        ListCardItem(rank: 6, title: "人工智能应用加速落地，相关概念股走强", badge: "热", badgeColor: .red),
        ListCardItem(rank: 7, title: "光伏产业景气度高企，组件价格企稳回升", badge: nil, badgeColor: .gray),
        ListCardItem(rank: 8, title: "银行板块估值修复，中长期投资价值显现", badge: nil, badgeColor: .gray)
    ]
)