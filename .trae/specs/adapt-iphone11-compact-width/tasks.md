# Tasks

> 执行节奏遵循 `.trae/skills/kline-device-validation-loop`：每个 Task 独立可编译、构建安装到设备（iPhone 11 模拟器验证 + 用户真机验收）、一个领域一次提交。修复阶段每步先跑探针用例取证对比，再改代码。
>
> 现有调查脚手架（`ScreenGeometryProbe` + `DeviceCompatProbeUITests`）保留至 Task 10 统一处置。

- [ ] Task 1: 共享防御与基建——根容器宽/高钳制 + 窄宽判定（W1+W2①）
  - [ ] 1.1 ContentView 根布局：把 mainContentView（含全屏覆盖子页）钳制在可用尺寸内（GeometryReader 定 frame），确保底部 tab 栏任何页面/方向下完整在屏（当前被行情B/自选B/C/模拟A/B/C/编辑器撑爆的共享症状消失）
  - [ ] 1.2 窄宽判定基建：统一"紧凑宽度"判定（可用宽 < ~600pt，随视图层级传递，不硬编码机型），供 Task 3~9 分支
  - [ ] 验证：探针重跑 marketB/favB/simA/simB/simC/editor 竖屏，tab 栏 frame 落在屏内（页面内容溢出此时允许仍存在，由后续 Task 修）
- [ ] Task 2: 通用换行组件 WrappingHStack（W2②，独立先行交付）
  - [ ] 2.1 实现流式换行布局（FlowLayout 语义）：子部件按理想宽横排，放不下自动换到下一行；行距/对齐可配；支持任意子视图
  - [ ] 2.2 Preview 多宽度档演示（414/848/1024）+ 边界用例（超长单项、空态、嵌套）
  - [ ] 验证：Preview 三档宽度换行正确；组件单元验证通过（如子项计数/行数断言）
- [ ] Task 3: 布局编辑器竖屏紧凑态（W4）
  - [ ] 3.1 header 用 WrappingHStack 改为可换行布局（或 Picker 缩窄 + 标题截断），消除"全屏预览竖排文字"
  - [ ] 3.2 页签行 Picker 紧凑态 maxWidth 收紧
  - [ ] 3.3 编辑区紧凑宽改上下结构（树上/检查器下）或树面板收起；树面板不再固定 320 出屏
  - [ ] 验证：探针 editor/editor.selected 竖屏无 OVERFLOW、无文字竖排；iPad 横屏形态不变；既有 test98~102 编辑器用例不回归
- [ ] Task 4: 训练态 K 线竖屏适配（W3，单图 + 联动）
  - [ ] 4.1 trainingBadges 包 InfoPannerCenter（fixedSize 内容 + clipped + 单指横拖；复用/抽取 ChartLegendKit 实现）
  - [ ] 4.2 工具栏按钮组（📌/联/多空/⚙）位置与顺序对齐非训练态（右对齐）；竖屏名称/代码按需截断
  - [ ] 4.3 联动多图同口径验证（信息栏/右格按钮回屏）
  - [ ] 验证：探针 train.single/train.linked 竖屏无 OVERFLOW；`联` 按钮可点（探针用例能点进联动即回归通过）；横屏形态不变
- [ ] Task 5: 自选页 B/C 档适配（W5b+W6）
  - [ ] 5.1 自选 B 紧凑宽：常驻侧栏（216pt）折叠为入口按钮，点开抽屉/下拉选择分组（用户选定方案）；tableWidthInset 同步
  - [ ] 5.2 自选 B 工作区工具条紧凑态收敛（`编辑` 出屏消除）
  - [ ] 5.3 自选 C 工具行用 WrappingHStack 收敛，消除 12pt 溢出
  - [ ] 验证：探针 favB/favC 竖屏无 OVERFLOW（favC tab 栏 frame=[0,414]）；横屏与 iPad 侧栏形态不变
- [ ] Task 6: 行情页 B 档适配（W5a）
  - [ ] 6.1 紧凑宽：常驻侧栏（200pt）折叠为入口按钮，点开抽屉/下拉选择分类（与自选 B 同款交互）；tableWidthInset 同步
  - [ ] 6.2 工作区工具条紧凑态收敛（`搜索` 出屏消除）
  - [ ] 验证：探针 marketB 竖屏无 OVERFLOW；横屏与 iPad 侧栏形态不变
- [ ] Task 7: 模拟页 C 档适配 + 横屏挂死修复（W9，P0）
  - [ ] 7.1 先复现隔离挂死：单开 simC 旋转压测；如行自适应后仍挂，逐组件二分（指标行/模块行/买卖条/搜索框）定位震荡源
  - [ ] 7.2 指标行（7 项）用 WrappingHStack 自动换行两行；模块行横滚；买卖条入屏
  - [ ] 验证：竖/左横/右横旋转 ≥10 次无挂死（主线程无 >1s 阻塞）；探针 simC 三方向无 OVERFLOW
- [ ] Task 8: 模拟页 A 档适配（W7）
  - [ ] 8.1 紧凑态：侧栏（216pt）折叠为抽屉/下拉收纳（与行情B/自选B 同款交互）；资产指标行用 WrappingHStack 换行两行；模块分段横滚
  - [ ] 验证：探针 simA 竖/横无 OVERFLOW；买入/卖出在屏可点；iPad 侧栏形态不变
- [ ] Task 9: 模拟页 B 档适配（W8）
  - [ ] 9.1 竖屏：账户卡行用 WrappingHStack 改 2 列网格（换行），不再延至屏外
  - [ ] 9.2 横屏纵向：整体可滚动或压缩卡高，tab 栏回屏内
  - [ ] 验证：探针 simB 竖/横无 OVERFLOW 且 tab 栏在屏；横屏可切 tab
- [ ] Task 10: 全量回归与脚手架处置（W10）
  - [ ] 10.1 探针用例断言化：六区域三方向"关键交互元素不出屏"转正为 XCTAssert（保留为设备兼容回归）
  - [ ] 10.2 脚手架处置：ScreenGeometryProbe 去留按用户意见（默认保留，-screen-probe 门控零生产影响）
  - [ ] 10.3 回归：既有 KlineUITests 冒烟（test01~03/92/93/95~102）在 iPad mini 5 目的地通过
  - [ ] 10.4 用户真机验收：iPad mini 5 逐页面确认形态不变

# Task Dependencies

- Task 1、Task 2 先行（防御/判定/换行组件基建，其余任务复用）
- Task 7 的挂死复现隔离可与 Task 3~6 并行启动（纯调查）
- Task 3~6、8、9 相互独立，可并行（Task 5/6/8 的抽屉交互建议统一组件实现，由 Task 5 先落地、6/8 复用）
- Task 10 依赖全部完成
