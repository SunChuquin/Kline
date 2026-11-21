# Kline Web 页面规则化：form-create JSON 运行时渲染 + 项目内本地 Vant 设计器

## Summary

把已 Web 化的 **30 个页面/子页面** 全部迁移为「规则 JSON + 逻辑 Adapter」架构，运行时由 form-create 按 JSON 动态渲染，替换现有手写 Vue 模板（旧面板直接删除，git 历史兜底）：

- **UI 结构** → `Web/form-create/pages/*.json`（标准 form-create 规则，`pro.form-create.com/vant/view/` 与本地设计器通用，无文件个数限制）
- **业务逻辑** → `Web/src/fc/adapters/*.ts`（klineBus 快照拉取/写回/changed 订阅从现有 script 平移）
- **数据表格/列表区** → `k-*` 共享自定义组件（行情行、票面、表格等），被规则 JSON 引用，实现 30 页全量 1:1
- **运行时宿主** `FcPageHost` 统一渲染；本地设计器 = clone 官方 form-create-designer（next 分支 vant 版 playground）最小修改部署，提供文件列表管理 + 可视化编辑 + 回写 JSON

## Current State

- Web 层：Vue3 + TS + Vite5 + Vant4，hash 路由（[router/index.ts](file:///Volumes/home/repositories/Kline2/Web/src/router/index.ts)）
- 三类 WebView 容器：
  - Tab 页 5 个：HomePage(792行) / FavoritesPage(449) / MarketPage(1222) / SimulationPage(1158) / ProfilePilotPage(232)
  - 弹层浮层 [SheetPage.vue](file:///Volumes/home/repositories/Kline2/Web/src/pages/SheetPage.vue)（2122 行）内含 8 面板：settings / mainIndicators / subIndicators / search / quick / formulaCenter / presetEditor / training
  - 全屏页壳 [WebPage.vue](file:///Volumes/home/repositories/Kline2/Web/src/pages/WebPage.vue) 按 `page.open` 路由 17 面板（lanSync / localUpdate / pythonLab / backtest / trainingRecords / formulaEditor / strategyEditor / pickerEditor / strategyDetail / pickRun / testPage / cacheManage / ticket / condManage / condEditor / profile / search）
- 页面由 klineBus 快照+动作驱动；**UITest 锚点纪律**：HTML 控件必须保留原生时代 `accessibilityIdentifier` 值为 `aria-label`（XCUI 经 WKWebView 无障碍树匹配），迁移时逐页 grep KlineUITests 锚点
- WebView 常驻复用 + `pageSeq` 强制重挂载拉快照的时序机制需保留

## 决策记录（用户已拍板）

| 决策点 | 结论 |
|---|---|
| 用途 | **运行时接入**：Vue 侧按规则 JSON 动态渲染，非纯设计稿 |
| 范围 | **30 页全量迁移**：数据表格区以自定义组件嵌入规则 JSON |
| 保真度 | 全部尽力 1:1（结构与字段、交互形态对齐；视觉走 Vant 风格 + 视觉令牌） |
| 部署 | **clone 官方开源仓库本地修改部署**（xaboy/form-create-designer next 分支 monorepo，跑 vant 设计器 playground） |
| 回退 | 直接替换删除旧组件，仅靠 git 历史 |

> 注：底部菜单为 4 个 Tab 页（首页/自选/行情/模拟），路由层另有 profile 页，本计划 tab 域按 5 个路由页迁移（tab-home / tab-favorites / tab-market / tab-simulation / tab-profile）。

## Target Architecture

```
设计器闭环：
form-create-designer (clone, vant playground) ──编辑回写──> Web/form-create/pages/*.json
                                                      │ build-time import
                                                      ▼
App WKWebView ──> FcPageHost ──> registry(name) ──> { rule, adapter, shell }
                                  adapter ──klineBus──> Swift 原生（快照/动作/changed）
```

分层职责：
- **JSON（UI）**：布局、字段、文案、aria-label、emit 事件名；不含业务逻辑
- **Adapter（逻辑）**：每页一个 TS 模块——`pull()` 拉快照回填表单、`actions` 处理按钮/自定义组件 emit、`onChange` 字段写回桥、`subscribe` 订阅 changed 刷新
- **k-* 组件（数据区）**：规则 JSON 引用，props 接数组/对象，emit 动作事件回 adapter
- **FcPageHost（宿主）**：加载规则 → `<form-create>` 渲染 → adapter 接线；关闭动作按域分发（page.close / sheet.close）
- **registry（分发）**：`import.meta.glob` 静态导入 30 份 JSON；WebPage/SheetPage 按名字查表命中即规则页

## Proposed Changes

### Part 1：运行时基建（Web/src）

1. `Web/package.json` 新增 `@form-create/vant@^3.3.6`（运行时渲染器，~200KB 级增量，可接受）
2. 新建 `Web/src/fc/`：
   - `formCreate.ts`：formCreate 实例初始化 + `k-*` 组件注册（含 aria-label 透传验证）
   - `FcPageHost.vue`：宿主组件（挂载/回填/事件/关闭/changed 订阅，保留 `:key=pageSeq` 重挂载机制）
   - `registry.ts`：name → `{ rule, adapter, shell }`；shell 配置弹层形态（bottom-panel 75% / center-card / top-layer / fullscreen），SheetPage 保留遮罩壳、内容区交给宿主
   - `format.ts`：从 SheetPage 抽出共享格式化（fmtPrice/fmtPct/fmtAmount/fmtShares/fmtSigned0 等红涨绿跌口径）
   - `adapters/*.ts`：30 个 adapter（逻辑从现有面板 script 平移，不改协议）
   - `components/*.vue`：自定义组件库
3. `[WebPage.vue](file:///Volumes/home/repositories/Kline2/Web/src/pages/WebPage.vue)` / `[SheetPage.vue](file:///Volumes/home/repositories/Kline2/Web/src/pages/SheetPage.vue)` 改造：17+8 个 `<XxxPanel v-else-if>` 分支替换为 `<FcPageHost :name="activeName" :key="pageSeq">` + shell 包装

### Part 2：自定义组件库（k-*，1:1 数据区承载）

| 组件 | 承载形态 | 主要使用页面 |
|---|---|---|
| `k-chip-group` | chip 单/多选组 | sheet-training、page-cacheManage、tab-home |
| `k-quote-row` | 行情行（名称/代码/价/涨幅 pill + 买/卖小按钮） | sheet-quick、tab-favorites |
| `k-mini-order` | 在途委托行 | sheet-quick |
| `k-ticket` | 下单票面（买卖 seg + 委托价/数量 + 仓位 chips + 提交） | sheet-quick、page-ticket |
| `k-combo-row` | 缓存组合占用行（勾选+名称+统计） | page-cacheManage |
| `k-progress-card` | 进度条卡 | page-cacheManage、page-pickRun |
| `k-custom-row` | 自定义指标/公式行（色条+名称+编辑/删除） | sheet-formulaCenter、sheet-mainIndicators、page-pickerEditor |
| `k-ind-tile-grid` | 指标 tile 网格（☑/☐ 四列） | sheet-mainIndicators、sheet-subIndicators |
| `k-row-card` | 行情榜单卡片（紧凑行+冻结表头语义） | tab-market |
| `k-market-table` | 手势双向滚动表格（MarketPage 表格区整体封装，内部手势/冻结逻辑平移不动） | tab-market |
| `k-stat-cards` | 概览统计卡组 | tab-home、tab-simulation、page-backtest |
| `k-pick-row` / `k-result-row` | 搜索结果行 / 选股命中行 | page-search、sheet-training、page-pickRun |

组件视觉沿用 `theme.css` 的 `--k-*` 令牌；官方设计器 playground（clone 仓库）与运行时从同一目录 `Web/src/fc/components/` import，保证编辑所见即运行所得。

### Part 3：规则 JSON 编制规范（30 份）

- 目录 `Web/form-create/pages/`，命名前缀消歧：`tab-*.json`(5) / `sheet-*.json`(8) / `page-*.json`(17)
- 文件为纯 designer 兼容格式 `{rule, config}`；页清单元数据在 `Web/form-create/index.json`
- field 名对齐 klineBus 快照键（`period`、`showGap`、`warmupN`、`capitalText`…），运行时回填零映射成本
- **锚点纪律**：每页迁移前 grep KlineUITests 该页锚点（如 `sim.cond.entry`、`trainingSetup.start`、`cacheManage.generate`、`formulaCenter.editCustom`、`chart.preset.editor`…），以 `props['aria-label']` 写进规则
- 动作按钮/自定义组件用 form-create emit 机制对接 adapter（事件名约定 `act:<name>`）；动态选项（周期/组合/账户列表）由 adapter `pull()` 后经 fapi 注入
- 列表数据：adapter 注入数组 field，`k-*` 组件渲染 + emit 行级动作
- 确认弹窗/ActionSheet 瞬时交互：Vant 原生弹层组件（van-dialog / van-action-sheet / van-picker）进规则，由 adapter 控制 show 字段

### Part 4：本地设计器（clone 官方仓库 + 最小修改部署）

clone `https://github.com/xaboy/form-create-designer`（next 分支，pnpm monorepo，`packages/vant` 即 `@form-create/vant-designer`）到 **Kline2 仓库外**：`/Volumes/home/repositories/form-create-designer`（外部工具仓库，不进 Kline2 版本管理）。

部署与修改（改动集中在 playground，`packages/*` 不动，保持可 pull 上游）：

```bash
git clone -b next https://github.com/xaboy/form-create-designer /Volumes/home/repositories/form-create-designer
cd /Volumes/home/repositories/form-create-designer && pnpm install && pnpm run dev:vant   # vant 设计器 playground
```

1. **k-* 自定义组件挂载**：playground 入口用官方组件注册 API（`FcDesigner.component(name, comp, 配置)` 一类，以 vant-designer 实际 API 为准）注册 `Kline2/Web/src/fc/components/` 的 k-* 组件——通过相对路径 `import` 同一源码目录，设计器与运行时所见即所得；注册后出现在左侧可拖拽面板，可配属性
2. **文件列表管理面板**：playground 增加一个小面板 + dev server 中间件，读写跨仓库绝对路径 `/Volumes/home/repositories/Kline2/Web/form-create/pages/*.json`（GET 列表 / GET 单文件 / PUT 保存，PUT 校验 JSON 可解析）；工具栏沿用官方 JSON 导入导出
3. 主应用 JSON 为 build-time 打包，设计器回写后需 Kline2 `npm run build` 才进设备

### Part 5：执行批次（每批 = JSON + adapter + 旧组件替换删除 + 构建验证门）

| 批次 | 内容 | 验证门 |
|---|---|---|
| **P0 基建** | 依赖安装、`Web/src/fc/` 骨架（formCreate/registry/FcPageHost/format）、k-* 组件、clone 官方设计器仓库跑通 + k-* 注册 + 文件列表面板 | 设计器打开/保存 Kline2 JSON 往返；主应用 `npm run build` 通过 |
| **P1 Pilot** | sheet-settings + page-cacheManage 迁移（两页覆盖：开关/下拉弹层/chip 多选/进度/数字输入全形态） | 浏览器渲染对照 + 模拟器/真机走 kline-device-validation-loop + XCUI 锚点命中验证 |
| **P2 sheet 域** | 其余 7 面板（search/mainIndicators/subIndicators/quick/formulaCenter/presetEditor/training） | 同上 |
| **P3 page 域** | 其余 16 面板分 3 小批：①表单编辑类（ticket/condEditor/condManage/strategyEditor/formulaEditor/pickerEditor）②数据展示类（strategyDetail/backtest/trainingRecords/pickRun/testPage）③系统类（lanSync/localUpdate/pythonLab/profile/search） | 同上 |
| **P4 tab 域** | 5 页由轻到重：tab-profile → tab-home → tab-simulation → tab-favorites → tab-market（k-market-table 最后动） | 同上 + market.rowCard 等关键锚点 |
| **P5 收尾** | 删除 SheetPage/WebPage 冗余样式与死代码；全量构建 + 全量 KlineUITests 回归 | `npm run build`、`xcodebuild test` 全绿 |

## 风险与对策

- **Vant 默认风格 vs 手写 CSS 差异**：接受 Vant 风格为基线，k-* 组件收敛视觉令牌（theme.css 变量沿用）；用户已确认 1:1 尽力口径
- **a11y 锚点经 form-create props 透传**：P1 专项用 XCUI 验证 aria-label 可匹配；不通则调整透传方式（customRender/attrs）
- **弹层时序坑**：`pageSeq` 重挂载、`sheet.ready/page.ready` 就绪拉取机制原样保留在宿主
- **MarketPage 手势表格回归风险**：k-market-table 内部逻辑平移不动、仅外壳化，最后一批迁移单独验证
- **运行时 bundle 增量**：接受（约 200KB 级）

## Verification

1. P0：`/Volumes/home/repositories/form-create-designer` 下 `pnpm run dev:vant` 打开设计器，文件列表 30 项（跨仓库读写 Kline2 JSON）；编辑→保存→文件落盘往返
2. 每批次：主应用 `npm run build` 通过；浏览器 dev 逐页渲染对照源 .vue（结构/字段/文案/锚点齐全）
3. 每批次：模拟器/真机构建安装验证快照回填、写回、changed 刷新（走 kline-device-validation-loop 技能）
4. P5：全量 `xcodebuild test -project Kline.xcodeproj -scheme Kline -destination 'id=00008027-000218960CE3002E' -allowProvisioningUpdates -only-testing:KlineUITests` 绿
5. 互通抽查：任选 3 份纯 Vant 组件页面的 JSON 导入 `pro.form-create.com/vant/view/` 验证格式通用
