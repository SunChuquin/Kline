# 悬浮按钮显示范围改为 detailItem 判定 + 弹窗自动隐藏（2026-09-23）

> 取代 [[20260919-悬浮按钮-显示范围判定]]（selectedTab 判定）。

## 两条决策

### 决策 1：按钮显示条件改为 `detailItem != nil`

按钮只在 **K 线详情页全屏 overlay 打开时** 才挂载（`detailItem != nil`）。自选/行情/首页/模拟**列表页**不再显示按钮。

### 决策 2：K 线详情页任一弹窗打开时，两个按钮通过 coordinator 统一隐藏

KlineDetailView 聚合自身全部弹窗 state（设置面板 / 搜索栏 / 公式编辑器 / 3 个 confirmationDialog / 重置确认 / 钻取）成一个 Bool，通过 `.onChange` 推送到 `FloatingAccessoryCoordinator.isDetailViewPopupActive`。ContentView 的 overlay 通过 `@ObservedObject` 订阅 coordinator，统一处理 opacity + hitTest。

## 架构图

```mermaid
flowchart LR
    A[KlineDetailView<br/>9 个弹窗 state] -->|isAnyPopupActive| B[onChange → coordinator.setDetailViewPopupActive]
    B -->|@Published| C[FloatingAccessoryCoordinator<br/>.isDetailViewPopupActive]
    C -->|@ObservedObject| D[ContentView overlay]
    D -->|opacity + hitTest| E[两个按钮一起隐藏/恢复]
```

## 为什么这样写（三条非显然的设计）

1. **按钮仍留在 ContentView overlay 层，不搬进 KlineDetailView**。
   之前 buggy commit 曾把按钮搬进 Wheel 的 body 里，导致 `invalid redeclaration of 'body'` 和跨视图访问不存在的静态属性。按钮与面板是配对的，分离会让状态管理更复杂。

2. **弹窗状态不在 ViewBuilder 闭包里写赋值语句**。
   之前 buggy commit 在 KlineDetailView 的 `.overlay { ... }` 闭包里写 `shouldShowFloatingButtons = false`，SwiftUI ViewBuilder 不允许直接赋值（`type '() -> ()' cannot conform to 'ShapeStyle'`）。正确做法是 `.onChange` 在渲染循环外安全推送 coordinator。

3. **弹窗隐藏由 coordinator 中转，ContentView 只看一个 Bool**。
   ContentView 不该知道 KlineDetailView 有 9 个弹窗 state —— 它只负责根视图 overlay 的可见性。KlineDetailView 聚合、coordinator 广播、ContentView 消费，三者各司其职。

## 放弃了什么

- 放弃了「自选/行情列表页也显示按钮」这个旧行为。按钮现在严格绑定 K 线详情页，列表页用户看不到、也不会误触。
- 不在每个按钮上各加一个 modifier 处理弹窗隐藏（像 `hidesDuringCursorAutoMove()` 那样）。弹窗隐藏同时影响两个按钮，放在 ContentView overlay 层统一处理更干净。

## 代价

- coordinator 新增一个 `@Published` 属性 + setter，但 KlineDetailView 只在弹窗 state 变化时推送（不是高频），不会引入发布风暴。
- ContentView 现在 @ObservedObject coordinator 单例。这个对象之前已经被 wheel 等引用，不是新引入的依赖，但根视图观察一个单例理论上会让整树跟随发布重算。实测 `.isDetailViewPopupActive` 变化频率极低（用户开关设置面板时触发一次），可以接受。

## 改动前提

- `DetailRouter.item` 的值语义：非 nil = 详情页打开，nil = 详情页关闭。一旦详情页不再用根 overlay 呈现（改成 NavigationStack push 或 fullScreenCover），判定即失效。
- KlineDetailView 里任何新增弹窗 state，都必须同步加到 `isAnyPopupActive` 的 OR 列表里。忘记加 = 按钮会压在弹窗之上。

## 关联代码

| 角色 | 文件 | 关键行 |
| --- | --- | --- |
| 协调对象新增状态 | `Kline/App/FloatingAccessoryCoordinator.swift` | `isDetailViewPopupActive` / `setDetailViewPopupActive(_:)` |
| 详情页聚合弹窗 | `Kline/Chart/KlineDetailView.swift` | `isAnyPopupActive` computed + `.onChange` 推送 |
| 根视图消费 + 显示条件 | `Kline/App/ContentView.swift` | `accessoryCoordinator` @ObservedObject / `isButtonVisible` / overlay 层 |
