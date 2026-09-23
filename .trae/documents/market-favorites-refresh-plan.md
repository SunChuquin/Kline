# 行情页面自选逻辑优化 + 自选页面刷新按钮计划

## 需求概述

### 需求1：行情页面表格自选逻辑优化
- **当前状态**：添加自选会把名称标记为红色，还会置顶
- **期望状态**：只有持仓中的标的才会红色，是否置顶则取决于是否长按设置过"固定"

### 需求2：自选页面添加刷新按钮
- **位置**：搜索按钮左边插入一个"刷新"按钮
- **效果**：点击后跟个人中心里点击"本地更新监控标的列表"相同

## 当前实现分析

### 行情页面表格自选逻辑（MarketTableRow.swift）
- **自选高亮**：`isFaved` 参数控制，显示浅灰背景 + 红色文字
- **置顶逻辑**：通过 `fav.isFavorited(meta.id)` 判断是否自选，自选股票优先显示

### 自选页面结构（FavoritesView.swift）
- 四档布局（A/B/C/D）共用同一套搜索功能
- 搜索按钮在各布局中位置不同，但功能一致
- 目前没有刷新按钮

### 个人中心本地更新功能（LocalUpdateView.swift）
- **核心功能**：`WatchlistSyncManager.shared.sync(reason: "手动")`
- **效果**：设备侧直连东财获取当日K线，更新6类清单标的

## 实现计划

### 阶段1：持仓状态判断机制

#### 1.1 新增持仓状态判断逻辑
**文件**：`c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesStore.swift`
- 新增 `isPositioned(_ metaID: Int) -> Bool` 方法
- 查询 `SimStore.shared` 中是否存在该标的的持仓记录
- 持仓判断逻辑：`SimStore.shared.positions` 中是否有对应 `metaID` 的持仓

#### 1.2 新增"固定"状态管理
**文件**：`c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesStore.swift`
- 新增 `pinnedMetaIDs: Set<Int>` 属性，存储被长按固定的标的
- 新增 `pin(_ metaID: Int)` 和 `unpin(_ metaID: Int)` 方法
- 在长按操作面板中添加"固定/取消固定"选项

### 阶段2：行情页面表格逻辑重构

#### 2.1 修改 MarketTableRow.swift
**文件**：`c:\Users\sunck\home\projects\ios\Kline\Kline\Market\MarketTableRow.swift`
- 将 `isFaved` 参数重命名为 `isPositioned`，语义更准确
- 修改自选高亮逻辑：只有持仓中的标的才显示红色背景和文字
- 新增 `isPinned` 参数，控制是否置顶显示

#### 2.2 修改 MarketPageKit.swift
**文件**：`c:\Users\sunck\home\projects\ios\Kline\Kline\Market\MarketPageKit.swift`
- 修改置顶逻辑：从 `fav.isFavorited()` 改为 `fav.isPinned()`
- 在 `rowCard` 方法中传递 `isPinned` 参数给 `MarketTableRow`
- 调整排序逻辑：固定的标的优先显示，非固定的自选标的按原逻辑排序

### 阶段3：自选页面刷新按钮实现

#### 3.1 添加刷新按钮到搜索栏
**文件**：根据布局选择对应的文件
- `c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesLayoutAView.swift`（A布局）
- `c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesLayoutBView.swift`（B布局）
- `c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesLayoutCView.swift`（C布局）
- `c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesLayoutDView.swift`（D布局）

**实现方式**：
- 在搜索按钮左边添加一个刷新按钮
- 使用 `arrow.clockwise` 图标
- 点击时调用 `WatchlistSyncManager.shared.sync(reason: "手动")`

#### 3.2 统一刷新按钮样式
- 所有布局使用相同的刷新按钮样式
- 刷新中显示 `ProgressView()`，禁用按钮
- 使用 `disabled(!watchlistTappable)` 控制按钮可用状态

### 阶段4：长按操作面板扩展

#### 4.1 修改 FavoritesRowMenu.swift
**文件**：`c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesRowMenu.swift`
- 在长按操作面板中添加"固定/取消固定"选项
- 使用 "pin" 和 "pin.fill" 图标
- 调用 `fav.pin()` 和 `fav.unpin()` 方法

#### 4.2 更新 MetaRowMenuKit
**文件**：`c:\Users\sunck\home\projects\ios\Kline\Kline\Favorites\FavoritesRowMenu.swift`
- 在 `MetaRowMenuKit` 枚举中添加固定相关逻辑
- 确保行情页和搜索页都能使用相同的固定功能

## 技术要点

### 持仓状态判断
```swift
// 新增方法
func isPositioned(_ metaID: Int) -> Bool {
    return positions.contains { $0.metaID == metaID }
}
```

### 固定状态管理
```swift
// 新增属性和方法
private(set) var pinnedMetaIDs: Set<Int> = []

func pin(_ metaID: Int) {
    pinnedMetaIDs.insert(metaID)
    saveToDisk()
}

func unpin(_ metaID: Int) {
    pinnedMetaIDs.remove(metaID)
    saveToDisk()
}

func isPinned(_ metaID: Int) -> Bool {
    return pinnedMetaIDs.contains(metaID)
}
```

### 刷新按钮集成
```swift
Button(action: {
    watchlistSync.sync(reason: "手动")
}) {
    Image(systemName: "arrow.clockwise")
        .font(.system(size: 18))
        .foregroundColor(watchlistTappable ? Color.blue : Color.gray)
}
.disabled(!watchlistTappable)
```

## 验收清单

### 功能验证
1. ✅ 行情页面：只有持仓中的标的显示红色，非持仓自选标的不显示红色
2. ✅ 行情页面：长按"固定"的标的置顶显示，非固定的自选标的不置顶
3. ✅ 自选页面：搜索按钮左边添加了刷新按钮
4. ✅ 自选页面：刷新按钮点击后触发监控标的列表更新
5. ✅ 长按操作：自选页面长按操作面板包含"固定/取消固定"选项

### 兼容性验证
1. ✅ 现有自选功能不受影响
2. ✅ 现有持仓功能不受影响
3. ✅ 四档布局都支持刷新按钮
4. ✅ 个人中心本地更新功能保持不变

### 用户体验验证
1. ✅ 刷新按钮在刷新中显示进度圈并禁用
2. ✅ 固定状态持久化，重启应用后保持
3. ✅ 持仓状态实时反映在颜色显示上
4. ✅ 操作反馈清晰，状态变化明显

## 实施优先级

### 高优先级（核心功能）
1. 持仓状态判断机制
2. 行情页面表格逻辑重构
3. 自选页面刷新按钮

### 中优先级（功能完善）
1. 长按操作面板扩展
2. 固定状态持久化

### 低优先级（优化）
1. 统一刷新按钮样式
2. 错误处理和用户提示

## 风险评估

### 技术风险
- **低风险**：主要是逻辑调整，不涉及底层架构变更
- **风险点**：持仓判断逻辑可能需要根据实际业务调整

### 兼容性风险
- **低风险**：向后兼容，不影响现有功能
- **风险点**：如果用户依赖现有的自选高亮逻辑，可能需要适应期

### 性能风险
- **低风险**：新增的持仓查询和固定状态查询都是内存操作
- **风险点**：如果持仓数据量大，可能需要优化查询性能

## 总结

这个计划通过分阶段的实施，实现了用户需求的两个核心功能：
1. 行情页面表格自选逻辑优化：区分持仓和自选，支持固定置顶
2. 自选页面刷新按钮：方便用户手动更新监控标的列表

同时保持了现有功能的兼容性，提供了良好的用户体验。