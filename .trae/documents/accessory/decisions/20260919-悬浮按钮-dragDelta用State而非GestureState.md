# dragDelta 用 @State 而非 @GestureState（2026-09-19）

## 决策

拖动位移 `dragDelta` 用 `@State` 手动维护，不用 `@GestureState` 的自动归零。

## 为什么

它必须与**吸附目标**在同一个动画事务里一起归零：

```swift
withAnimation(.easeOut(duration: 0.2)) {
    center = target      // 吸附到最近边缘
    dragDelta = .zero    // 同事务归零 → 从松手点平滑过渡到贴边位置
}
```

`@GestureState` 在手势结束时由框架自动归零，**不参与该动画事务**，松手会先看到位置跳一下再吸附。

## 代价

需要在 `onEnded` 的两个分支（点击 / 拖动）各自手动归零；漏写就会出现「按钮停在偏移处」。

## 关联代码

- `Kline/App/FloatingAccessory.swift:82-84`（定义）
- `Kline/App/FloatingAccessory.swift:172-186`（两个分支的归零点）