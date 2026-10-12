# 引擎部署全自动通道（PC 部署助手引擎分发）Spec

## Why

引擎更新当前是三段式手动流程：下载 .tipa → 手动点 TrollStore 安装 → 手动回 App 刷新。PC 部署助手只覆盖 App IPA 分发，引擎要人肉。用户要求全自动闭环：**下引擎 → opener 自动把 Kline 带回前台 → 部署助手确认引擎更新成功 → 若 Kline 自身有新版则自动推送 → opener 自动打开新版 Kline**。

## What Changes

- **opener.m 新增 `--engine` 模式**：轮询 Engine.app（`com.sunck.KlineEngine`）的 Info.plist CFBundleVersion，与 argv 传入的当前构建号不同且**连续两轮确认**后，经 LSApplicationWorkspace 打开 `com.sunck.Kline`（不是 Engine）；超时自退（默认 600s，与现有模式一致）。复用现有 loadLSFrameworks/logmsg/双轮确认基建。
- **PythonEngineHost.installViaTrollStore 切换 opener --engine**：spawn 参数从默认模式（盯 App 版本）改为 `--engine <当前引擎构建号>`——引擎安装不会改 App 版本，现状下默认模式 opener 空转 600s 后超时（无人把 Kline 带回前台）。LocalUpdateView「更新引擎」行与新增路由同享此修复。
- **KlineHTTPServer GET / statusJSON 增加 `engineBuild` 字段**：已装 Engine.app 的 CFBundleVersion（复用 PythonEngineHost.installedEngineBuildNumber），部署助手据此判定「引擎更新成功」。
- **KlineHTTPServer 新增 `POST /install-engine` 路由**：body `{"url": "<.tipa 直链>"}` → 复用 PythonEngineHost.downloadTipa（sidecar + Release digest 双 sha256 校验 + 时间戳穿透）→ opener `--engine` 守护 → TrollStore 安装（apple-magnifier URL + keepServingForInstall 后台时间）。响应 `{"ok":true,"engineBuild":N}`；校验失败返回 4xx/5xx + error。
- **部署助手编排契约**（Windows 侧代码不在本仓库，只定义 HTTP 契约并落文档）：轮询 `GET /` 取 `engineBuild` → 变化即引擎成功 → 对比 GitHub App release build number → 有新版则 `POST /install-local {"url":"…Kline.ipa"}`（既有链路自动 opener 打开新版 App）。
- **明确不做**：App 侧 one-shot 自动推 App（编排职责归部署助手，引擎装完后 App 只被动回前台）；App 内手动更新行为零改动。

## Impact

- Affected code: `opener.m`、`Kline/Debug/PythonEngineHost.swift`、`Kline/Infrastructure/KlineHTTPServer.swift`、`.github/workflows/build.yml`（无改动——opener 编译已覆盖）、新文档（部署助手契约）
- Affected specs: `.trae/documents/python-engine/Python引擎下沉可行性分析.md` §5.6（引擎获取顺序，回填本次双通道扩展）
- 风险边界：opener --engine 打开的是 com.sunck.Kline（不是 Engine）；引擎安装不终止 Kline 进程，HTTP 服务全程在线；双轮确认防安装中间态误触发。

## ADDED Requirements

### Requirement: opener --engine 模式
opener SHALL 支持 `--engine <curBuild> <maxWait> [extraLog]`：glob `/private/var/containers/Bundle/Application/*/Engine.app/Info.plist`，比对 CFBundleIdentifier == com.sunck.KlineEngine 且 CFBundleVersion != curBuild，连续两轮确认后以 LSApplicationWorkspace 打开 com.sunck.Kline 并退出；超时（maxWait 秒）自退返回非 0。

#### Scenario: 引擎装完自动回前台
- **WHEN** TrollStore 完成 Engine.app 安装（CFBundleVersion 由 #7 变 #9）
- **THEN** opener --engine 在 2s 内检测并打开 Kline 到前台，日志写 `engine version confirmed (v=9 cur=7) -> open Kline` → `open ret=0`

#### Scenario: 超时自退
- **WHEN** maxWait 秒内 Engine.app 版本无变化（用户取消安装）
- **THEN** opener 写 `engine timeout after Ns (cur=X)` 后退出（退出码 1），绝无常驻进程

### Requirement: POST /install-engine 路由
KlineHTTPServer SHALL 提供 `POST /install-engine`：接受 `{"url": "<https://…/KlineEngine-<ver>.tipa>"}`，复用 downloadTipa 链路（.tipa + .sha256 sidecar 下载、时间戳穿透、CryptoKit sha256 校验）+ Release digest 复核，通过后以 root spawn `opener --engine <curEngineBuild> 600 <log>` 并打开 apple-magnifier URL；downloadTipa busy 时返回 409。

#### Scenario: 部署助手一键触发
- **WHEN** 部署助手 POST /install-engine 带 GitHub engine Release 的 .tipa 直链
- **THEN** App 侧完成下载+双校验（约 20-30s）→ 自动拉起 TrollStore → 装完 opener 自动把 Kline 带回前台；响应 `{"ok":true,"engineBuild":<下载前构建号>}`

#### Scenario: 校验失败不安装
- **WHEN** sha256 或 digest 校验失败（CDN 缓存旧包）
- **THEN** 返回 `{"error":"sha256 不匹配…"}` 状态 502，不 spawn opener、不拉 TrollStore，已下载文件删除

### Requirement: statusJSON 暴露 engineBuild
GET / 的状态 JSON SHALL 增加 `engineBuild` 字段（Int，取已装 Engine.app CFBundleVersion；未安装/内嵌引擎时为 null）。

#### Scenario: 部署助手判定引擎更新成功
- **WHEN** 部署助手轮询 GET / 且 engineBuild 从 7 变 9
- **THEN** 部署助手确认引擎更新完成，进入「App 是否有新版」分支

## MODIFIED Requirements

### Requirement: installViaTrollStore 的 opener 守护
PythonEngineHost.installViaTrollStore SHALL 以 `--engine <installedEngineBuildNumber>` 参数 spawn opener（原：默认模式盯 App 版本）；引擎构建号不可得（bundle 缺 Info.plist）时退回默认模式并记日志。

#### Scenario: App 内「更新引擎」行同享自动回前台
- **WHEN** 用户在本地更新面板点「更新引擎」行完成安装
- **THEN** 装完 Kline 自动回前台（原：停在 TrollStore 等用户手动切回）
