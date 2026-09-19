# @Published 同值赋值也会发布（2026-09-19）

## 现象

把 `onChanged` 每帧调用的方法写成直接给 `@Published` 属性赋值后出现**发布风暴**：
每个触摸事件都触发一次对象变更通知，所有订阅者被高频唤起，界面卡顿。

## 根因

`@Published` 在**每次赋值时都会发布**，**不比较新旧值是否相等** —— 值类型（枚举、Bool 等）
即使赋的是同一个值也会发布。而 SwiftUI 的 `onChanged` 是每个触摸事件回调一次
（每秒可达 60~120 次），把「每帧调用」的入口直接接到 `@Published` 上必然形成风暴。

## 现在的规避方式

1. 所有可能被高频调用的写入口都加「值未变不写」守卫：
   `if activeOwner != owner { activeOwner = owner }`；
2. 高频读写的状态**不要**放 `@Published`，放普通内存属性
   （本模块的 `knownSides` 就是刻意不发布的）；
3. 消费方不要用 `@ObservedObject` 观察这类对象（每次发布都会重算整棵视图树），
   改用 `.onReceive(obj.$x)` 做事件式处理、必要时主动读普通属性。

## 关联代码位置

- `Kline/App/FloatingAccessoryCoordinator.swift`：`beginGesture` / `reportSide` / `requestSnap` 三处守卫
- 提出该问题的场景：[[20260919-两按钮同侧互斥实时反向吸附]]