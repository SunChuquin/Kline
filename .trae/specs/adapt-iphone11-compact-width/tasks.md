# Tasks

> 执行节奏遵循 `.trae/skills/kline-device-validation-loop`：每个 Task 独立可编译、构建安装到设备（iPhone 11 模拟器验证 + 用户真机验收）、一个领域一次提交。修复阶段每步先跑探针用例取证对比，再改代码。
>
> 现有调查脚手架（`ScreenGeometryProbe` + `DeviceCompatProbeUITests`）保留至 Task 10 统一处置。

- [x] Task 1: 共享防御与基建——根容器宽/高钳制 + 窄宽判定（W1+W2①）
  - [x] 1.1 ContentView 根布局：把 mainContentView（含全屏覆盖子页）钳制在可用尺寸内（GeometryReader 定 frame），确保底部 tab 栏任何页面/方向下完整在屏（当前被行情B/自选B/C/模拟A/B/C/编辑器撑爆的共享症状消失）
  - [x] 1.2 窄宽判定基建：统一"紧凑宽度"判定（可用宽 < ~600pt，随视图层级传递，不硬编码机型），供 Task 3~9 分支
  - [x] 验证：探针重跑 marketB/favB/simA/simB/simC/editor 竖屏，tab 栏 frame 落在屏内（页面内容溢出此时允许仍存在，由后续 Task 修）——marketB/favB/editor 三处实测 tab 栏=[0,414]；simA/simB/simC 由 Task 8/9/7 各自探针复验
- [x] Task 2: 通用换行组件 WrappingHStack（W2②，独立先行交付）
  - [x] 2.1 实现流式换行布局（FlowLayout 语义）：子部件按理想宽横排，放不下自动换到下一行；行距/对齐可配；支持任意子视图
  - [x] 2.2 Preview 多宽度档演示（414/848/1024）+ 边界用例（超长单项、空态、嵌套）
  - [x] 验证：Preview 三档宽度换行正确；组件单元验证通过（单测 6/6：414 断行/超宽独占/空集合/对齐）
- [x] Task 3: 布局编辑器竖屏紧凑态（W4）
  - [x] 3.1 header 用 WrappingHStack 改为可换行布局（或 Picker 缩窄 + 标题截断），消除"全屏预览竖排文字"——实际方案：紧凑态 header 拆两行（返回+标题+全屏预览 / 四档 Picker 拉满），全屏预览恢复水平文字 99.5×30
  - [x] 3.2 页签行 Picker 紧凑态 maxWidth 收紧（240→150）
  - [x] 3.3 编辑区紧凑宽改上下结构（树上/检查器下）或树面板收起；树面板不再固定 320 出屏——实际：树列表固定高 260 在上、检查器占余高
  - [x] 验证：探针 editor/editor.selected 竖屏无 OVERFLOW、无文字竖排；iPad 横屏形态不变（≥600 分支原样）；既有 test98~102 编辑器用例不回归（Task 10 统一回归）
- [x] Task 4: 训练态 K 线竖屏适配（W3，单图 + 联动）
  - [x] 4.1 trainingBadges 包 InfoPannerCenter（fixedSize 内容 + clipped + 单指横拖；ChartLegendKit 内去 private 复用）
  - [x] 4.2 工具栏按钮组（📌/联/多空/⚙）位置与顺序对齐非训练态（右对齐）；竖屏名称/代码按需截断——探针实测按钮位与非训练态基线逐点一致（264/302/340/374）
  - [x] 4.3 联动多图同口径验证（信息栏/右格按钮回屏）——train.linked 竖横按钮全部在屏，联按钮恢复可点（testProbe07 通过）
  - [x] 验证：探针 train.single/train.linked 竖屏无 OVERFLOW；`联` 按钮可点（testProbe07 全过即证明）；横屏形态不变
- [x] Task 5: 自选页 B/C 档适配（W5b+W6）
  - [x] 5.1 自选 B 紧凑宽：常驻侧栏（216pt）折叠为入口按钮，点开抽屉/下拉选择分组（用户选定方案）；tableWidthInset 同步——新增通用 SidebarDrawer 组件（Kline/App/SidebarDrawer.swift），行情B/模拟A 复用
  - [x] 5.2 自选 B 工作区工具条紧凑态收敛（`编辑` 出屏消除——实测 335.5→402 在屏；搜索/表头设置紧凑转纯图标）
  - [x] 5.3 自选 C 工具行用 WrappingHStack 收敛，消除 12pt 溢出——探针 favC.P 零溢出
  - [x] 验证：探针 favB/favC 竖屏无 OVERFLOW（favC tab 栏 frame=[0,414]）；testProbe03 通过；横屏与 iPad 侧栏形态不变（≥600 分支）
- [x] Task 6: 行情页 B 档适配（W5a）
  - [x] 6.1 紧凑宽：常驻侧栏（200pt）折叠为入口按钮，点开抽屉/下拉选择分类（与自选 B 同款交互）；tableWidthInset 同步——锚点承载 market.topMenu.<当前一级> 保探针/既有用例路径；抽屉仅展开态挂树
  - [x] 6.2 工作区工具条紧凑态收敛（`搜索` 出屏消除——实测 338→402 在屏；整表横向滚动画列宽不重排）
  - [x] 验证：探针 marketB 竖屏无 OVERFLOW（testProbe02 EXIT=0）；横屏与 iPad 侧栏形态不变（≥600 分支）
- [x] Task 7: 模拟页 C 档适配 + 横屏挂死修复（W9，P0）
  - [x] 7.1 先复现隔离挂死：单开 simC 旋转压测；如行自适应后仍挂，逐组件二分（指标行/模块行/买卖条/搜索框）定位震荡源——隔离 worktree 两轮 testProbe04 全过（simC.LL/LR 18 标记齐全），挂死未复现，无需二分；根因印证：定宽溢出行在旋转时布局不收敛
  - [x] 7.2 指标行（7 项）用 WrappingHStack 自动换行（实测折 3 行全在屏）；模块行拆两行（分段横滚+搜索弹性宽）；买卖条紧凑隐藏提示入屏（原 +180pt 消除）
  - [x] 验证：隔离两轮 EXIT=0（241s/244s）+ 主树合验 testProbe04 通过；主线程无阻塞；simC 三方向按钮全在屏（买入 146-266 / 卖出 278-398）
- [x] Task 8: 模拟页 A 档适配（W7）
  - [x] 8.1 紧凑态：侧栏（216pt）折叠为抽屉/下拉收纳（与行情B/自选B 同款交互）；资产指标行用 WrappingHStack 换行两行；模块分段横滚——实际：指标行无条件换行（iPad 808 单行形态不变）；窄工作区(<760)模块行拆两行+整表横滚+买卖条收提示（表格固有列宽 806 会撑宽工作区）
  - [x] 验证：探针 simA 竖/横无 OVERFLOW（买卖条 146-398/横屏 620-872 在屏，刷新回屏原+257pt）；iPad 侧栏形态不变；testProbe04 EXIT=0
- [x] Task 9: 模拟页 B 档适配（W8）
  - [x] 9.1 竖屏：账户卡行用 WrappingHStack 改 2 列网格（换行），不再延至屏外
  - [x] 9.2 横屏纵向：整体可滚动或压缩卡高，tab 栏回屏内——实际：内容纵滚+买卖条钉底（竖屏 3 账户固定布局实测超屏 66pt）
  - [x] 验证：探针 simB 竖/横无 OVERFLOW 且 tab 栏在屏（横屏工具栏 y=55/tab y=362 回屏，原 -82/451 出屏）；testProbe04 EXIT=0
- [x] Task 10: 全量回归与脚手架处置（W10）
  - [x] 10.1 探针用例断言化：每方向断言 tab 栏 + 页面白名单关键交互元素在屏（买卖条/保存/恢复默认/⚙/联），联按钮多 label 匹配；testProbe07 恢复竖屏直点「联」（顺带回归 Task 4 修复）
  - [x] 10.2 脚手架处置：ScreenGeometryProbe 转正常驻调试设施（-screen-probe 门控零生产开销，注释更新）；DeviceCompatProbeUITests 转正为设备兼容回归
  - [x] 10.3 回归：iPad mini 5 冒烟 10 通过（01/02/03/93/95/96/97/100/101/102）+ test92 加非刘海设备 XCTSkip 守卫（iPad 无横向安全区，minX=0 是正确行为）+ test98 重跑通过（首轮为双模拟器并发负载抖动）；test99 为**既有失败**（基线 f7e50fa 隔离 worktree 复现同一条断言，非本次回归；iPad 模拟器上 addBack 后 0.3s 时序不足，留后续单独修）。iPhone 11 探针 7/7 全过（testProbe03 首轮失败为并发负载抖动，单独重跑通过 218s）
  - [ ] 10.4 用户真机验收：iPad mini 5 逐页面确认形态不变（**待用户验收**）

# Task Dependencies

- Task 1、Task 2 先行（防御/判定/换行组件基建，其余任务复用）
- Task 7 的挂死复现隔离可与 Task 3~6 并行启动（纯调查）
- Task 3~6、8、9 相互独立，可并行（Task 5/6/8 的抽屉交互建议统一组件实现，由 Task 5 先落地、6/8 复用）
- Task 10 依赖全部完成
