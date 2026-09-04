# Kline

iOS K线图表应用（SwiftUI + Xcode）

## 快速导航

- [构建流程](TRAE-Windows-Build-Workflow.md) — Windows + GitHub Actions 自动构建 IPA

- [更新方案](Kline-Update-Plans.md) — TrollStore 永久安装后的远程/本地更新方案

- [页面布局设计](Kline-页面布局设计.md) — UI 布局规范

- [设置面板设计规范](Kline-设置面板设计规范.md) — 设置面板 UI 规范

## 部署形态与文档路由

Kline 当前处于部署形态切换期。**后续 agent 默认按现行形态执行**，只有用户明确要求回退到签名形态，才参考 archive 归档。

| 形态 | 状态 | 用哪套文档 |
|------|------|-----------|
| **TrollStore + 未签名/ad-hoc + AFC push**（现行） | 切换中，🥇 方案待验证 | 过渡期见 [Kline-Update-Plans.md](Kline-Update-Plans.md)（含验证优先级 + 待办事项）；新形态跑通后 [TRAE-Windows-Build-Workflow.md](TRAE-Windows-Build-Workflow.md) 会更新为 v3.0 TrollStore 版 |
| 签名 IPA + `apps install`（旧） | 已归档 | [archive/legacy-signed-install/](archive/legacy-signed-install/) — 仅回退/对照时参考 |

**关键区别速记**：

- 旧形态：免费证书签名 IPA（7 天有效）→ `pymobiledevice3 apps install` → `apps pull` 读沙盒日志（HouseArrest）
- 现行形态：未签名构建 + ad-hoc 签名 + entitlements 注入（永久）→ AFC push 到 `/var/mobile/Media/Downloads/` + TrollStore 手动安装 → 日志读取消 AFC pull（A1 方案，待实现）

> ⚠️ 对 TrollStore 版 IPA 跑 `apps install` 会失败（ad-hoc 签名不被 iOS 接受）；TrollStore 版的 `apps pull`/`house_arrest` 会报 `AppNotInstalledError`。别按旧形态文档执行。

## 开发环境

- **Windows + GitHub Actions**（无需 Mac，无需 Xcode IDE）

- 外部工具链位置（在仓库外的 `ios/` 父目录，不入库）：

| 目录              | 用途                                                    |
| --------------- | ----------------------------------------------------- |
| `TrollRestore/` | USB 推送 + TrollStore 安装工具（Python 脚本 + pymobiledevice3） |
| `.venv-ios/`    | pymobiledevice3 Python 虚拟环境                           |
| `artifacts/`    | CI 构建的 IPA 产物落地目录                                     |

## 构建

push 到 `main` 分支 → GitHub Actions 自动构建（未签名 + ad-hoc 签名 + entitlements 注入）→ 下载 IPA → TrollStore 安装

详见 [构建流程文档](TRAE-Windows-Build-Workflow.md)。

## 技术栈

- SwiftUI + Xcode 项目（无 CocoaPods）

- Bundle ID: `com.sunck.Kline`

- 构建命令：`xcodebuild -project Kline.xcodeproj -scheme Kline -configuration Release`

- CI 配置：`.github/workflows/build.yml`

## 项目结构

```
Kline/
├── .github/workflows/build.yml    # CI 构建配置
├── Kline/                         # Swift 源码
│   ├── KlineApp.swift             # App 入口
│   ├── ContentView.swift          # 主视图
│   ├── KlineChartView.swift       # K 线图表
│   ├── LocalUpdateView.swift      # 本地更新面板
│   ├── DebugLogger.swift          # 调试日志
│   ├── Indicators/                # 内置指标模板 (.tdx)
│   └── ...
├── Kline.entitlements             # TrollStore 权限声明
├── ExportOptions.plist            # Xcode 导出配置
├── Info.plist
└── tdx.db                         # 股票数据（演示用）
```
