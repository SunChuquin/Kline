# 固定高度贴底面板直接 ignoresSafeArea 无效（2026-09-19）

## 现象

贴底面板底部留一条灰缝，露出后面的深色遮罩。

## 根因

固定高度的面板，在安全区扩展后的容器里**默认居中**放置，只下移半个 inset，底部仍差半个 inset。

## 现在的规避方式

外墙用**贪婪 frame 钉底**：

```swift
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
.ignoresSafeArea(edges: .bottom)
```

面板先被钉在容器底边，扩展后容器底边 = 物理屏幕底边，面板才真正贴底。
另配 `TopRoundedCornerRect` 只圆顶部两角 —— 底边贴紧物理屏幕底边后，底部若保留圆角，两角同样会露出遮罩。

**这不是新发现的坑**：本模块沿用了 `bottomSheet`（`Kline/Chart/ChartSheetKit.swift:15-37`）的既有处理，
抄写这类贴底面板时照搬即可，不要简化掉那层贪婪 frame。

## 关联代码位置

- `Kline/App/FloatingAccessory.swift:262-270`
- 参照实现：`Kline/Chart/ChartSheetKit.swift:15-37`（`bottomSheet`）