//
//  CommonLayoutWidgets.swift
//  Kline
//
//  通用 JSON 布局引擎 - **页面无关**的通用控件（横滑卡片 / 列表卡片 / 占位块）。
//
//  与首页控件（home.* 前缀）的区别：这几个控件**只读 WidgetParams**，
//  不依赖任何页面的上下文（不读 HomeLayoutContext、不碰页面状态），
//  因此任何页面的注册表都能用 `registerCommonLayoutWidgets(into:)` 把这一组合并进去。
//  视觉规格逐项对齐「测试页面」（ProfileView）里的 HorizontalScrollCard / ListCard / 灰色占位矩形。
//
//  控件名、本文件的注册名、CommonLayoutWidgetSchema 的描述、JSON 里的 widget.name 四处必须一致。
//

import SwiftUI

// MARK: - 控件名（JSON 里的 widget.name）

/// 页面无关通用控件的控件名
enum CommonWidgetName {
    /// 横滑卡片：标题栏 + 横向滚动条目（对齐 ProfileView 的 HorizontalScrollCard）
    static let hscrollCard = "common.hscrollCard"
    /// 列表卡片：标题栏 + 竖向编号列表（对齐 ProfileView 的 ListCard）
    static let listCard = "common.listCard"
    /// 占位块：固定高度的浅灰圆角块（对齐 ProfileView 的占位 Rectangle）
    static let placeholder = "common.placeholder"
}

// MARK: - 注册

/// 把通用控件注册进任意页面的控件注册表。
/// 构建器一律忽略第一个参数（Context），故对任何 Context 类型都成立。
func registerCommonLayoutWidgets<Context>(into registry: inout PageWidgetRegistry<Context>) {
    registry.register(CommonWidgetName.hscrollCard) { _, p in
        AnyView(CommonHScrollCard(title: p.string("title", default: "横滑卡片"),
                                  items: p.strings("items") ?? [],
                                  updateTime: p.optionalString("updateTime"),
                                  showsMore: p.bool("showsMore", default: false)))
    }

    registry.register(CommonWidgetName.listCard) { _, p in
        AnyView(CommonListCard(title: p.string("title", default: "列表卡片"),
                               items: p.strings("items") ?? [],
                               updateTime: p.optionalString("updateTime"),
                               showsMore: p.bool("showsMore", default: false)))
    }

    registry.register(CommonWidgetName.placeholder) { _, p in
        AnyView(CommonPlaceholderBlock(height: CGFloat(p.int("height", default: 150))))
    }
}

// MARK: - 控制台：可编辑参数描述

/// 通用控件的「可编辑参数」描述（与 `registerCommonLayoutWidgets` 注册的三个控件一一对应）
enum CommonLayoutWidgetSchema {
    static let all: [WidgetDescriptor] = [
        WidgetDescriptor(name: CommonWidgetName.hscrollCard,
                         title: "横滑卡片",
                         params: [
                            WidgetParamDescriptor(key: "title",
                                                  title: "卡片标题",
                                                  kind: .text(placeholder: "卡片标题", note: nil)),
                            WidgetParamDescriptor(key: "items",
                                                  title: "条目",
                                                  kind: .textList(placeholder: "条目文字",
                                                                  note: "每行一条，横向滑动查看")),
                            WidgetParamDescriptor(key: "updateTime",
                                                  title: "右上角时间",
                                                  kind: .text(placeholder: "如：刚刚更新（留空则不显示）",
                                                              note: "填了时间就不再显示「更多」图标")),
                            WidgetParamDescriptor(key: "showsMore",
                                                  title: "显示更多图标",
                                                  kind: .toggle(default: false))
                         ]),

        WidgetDescriptor(name: CommonWidgetName.listCard,
                         title: "列表卡片",
                         params: [
                            WidgetParamDescriptor(key: "title",
                                                  title: "卡片标题",
                                                  kind: .text(placeholder: "卡片标题", note: nil)),
                            WidgetParamDescriptor(key: "items",
                                                  title: "条目",
                                                  kind: .textList(placeholder: "条目文字",
                                                                  note: "每行一条，序号自动生成（前 3 条红色）")),
                            WidgetParamDescriptor(key: "updateTime",
                                                  title: "右上角时间",
                                                  kind: .text(placeholder: "如：5分钟前更新（留空则不显示）",
                                                              note: "填了时间就不再显示「更多」")),
                            WidgetParamDescriptor(key: "showsMore",
                                                  title: "显示「更多」",
                                                  kind: .toggle(default: false))
                         ]),

        WidgetDescriptor(name: CommonWidgetName.placeholder,
                         title: "占位块",
                         params: [
                            WidgetParamDescriptor(key: "height",
                                                  title: "高度",
                                                  kind: .stepper(default: 150, range: 40...600,
                                                                 note: "浅灰圆角块，用于预留空间"))
                         ])
    ]
}

// MARK: - 卡片外框（两个卡片控件共用；规格对齐测试页的卡片）

/// 卡片外框：标题栏（标题 + 右上角「时间」或「更多」）+ 内容，白底圆角 + 轻阴影
private struct CommonCardChrome<Content: View>: View {
    let title: String
    /// 右上角时间文案；非空时优先显示时间
    let updateTime: String?
    let showsMore: Bool
    /// 「更多」的文案；nil → 用 chevron.right 图标（横滑卡用图标、列表卡用文字，与测试页一致）
    let moreLabel: String?
    let content: Content

    init(title: String,
         updateTime: String?,
         showsMore: Bool,
         moreLabel: String?,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.updateTime = updateTime
        self.showsMore = showsMore
        self.moreLabel = moreLabel
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()

                if let time = updateTime, !time.isEmpty {
                    Text(time)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                } else if showsMore {
                    if let label = moreLabel {
                        Text(label)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16))
                            .foregroundColor(.gray)
                    }
                }
            }

            content
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - 横滑卡片

/// 横滑卡片：标题栏 + 横向滚动的文字条目（条目文字由参数给定）
struct CommonHScrollCard: View {
    let title: String
    let items: [String]
    let updateTime: String?
    let showsMore: Bool

    var body: some View {
        CommonCardChrome(title: title,
                         updateTime: updateTime,
                         showsMore: showsMore,
                         moreLabel: nil) {
            if items.isEmpty {
                CommonEmptyHint()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(items.indices, id: \.self) { index in
                            Text(items[index])
                                .font(.system(size: 14))
                                .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                                .background(Color(.systemGray5))
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 列表卡片

/// 列表卡片：标题栏 + 竖向编号列表（序号自动生成，前 3 条红色）
struct CommonListCard: View {
    let title: String
    let items: [String]
    let updateTime: String?
    let showsMore: Bool

    var body: some View {
        CommonCardChrome(title: title,
                         updateTime: updateTime,
                         showsMore: showsMore,
                         moreLabel: "更多") {
            if items.isEmpty {
                CommonEmptyHint()
            } else {
                VStack(spacing: 12) {
                    ForEach(items.indices, id: \.self) { index in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 14))
                                .fontWeight(.bold)
                                .foregroundColor(index + 1 <= 3 ? .red : .gray)
                                .frame(width: 24, alignment: .center)

                            Text(items[index])
                                .font(.system(size: 14))
                                .lineLimit(1)

                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 占位块

/// 占位块：固定高度的浅灰圆角块（用于预留空间 / 占位）
struct CommonPlaceholderBlock: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color(.systemGray5))
            .frame(height: height)
            .cornerRadius(12)
    }
}

// MARK: - 未配置条目时的提示

/// 条目为空时的可诊断提示（不静默空白）
private struct CommonEmptyHint: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 13))
            Text("暂无条目：在检查器里填写「条目」（每行一条）")
                .font(.system(size: 12))
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}
