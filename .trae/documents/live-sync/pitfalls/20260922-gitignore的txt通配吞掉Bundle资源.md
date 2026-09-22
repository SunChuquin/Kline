# .gitignore 的 `*.txt` 通配会吞掉 Bundle 资源，云端构建里 App 读不到（2026-09-22）

## 现象

新增扩展指数覆盖表 `Kline/Resources/universe_secids.txt` 后，`git status` 里**根本看不到它**（连 `??` 都没有）；
若这样提交，构建产物（由 GitHub Actions 从仓库拉取）里不会有这个文件 → App 侧读不到覆盖表 →
`27#`/`62#`/`102#` 扩展指数**全部映射失败**。本地一切正常，只有真机/云端才暴露。

## 根因

`.gitignore:22` 是 `*.txt`（用来忽略临时文本），只对 `src/data/symbols.txt`、`src/data/universe.txt`
开了保留例外。放到 `Kline/` 下的新资源没有任何例外规则，于是被静默忽略。

关键点：**构建产物来自仓库，不在仓库 = 不在 App 里**，而本地开发完全无感。

## 现在的规避方式

沿用该文件既有的例外写法，补两条：

```
!src/data/universe_secids.txt
!Kline/Resources/universe_secids.txt
```

同时取数器做了防御：覆盖表读不到时**降级为「只用前缀规则映射」并记一条明确日志**
（不静默、不崩），日志文案直接点明「27#/62#/102# 扩展指数将全部跳过」，
所以即使将来又漏了资源，也能从设备日志一眼看出。

项目用 Xcode 16 的 `PBXFileSystemSynchronizedRootGroup`（同步文件夹），
`Kline/` 下的非源码文件会自动打包成资源，**不需要改 `project.pbxproj`**（`Kline/tdx.db` 是先例）。

## 关联代码

- `.gitignore:26-27`
- `Kline/Infrastructure/EastmoneyQuoteFetcher.swift:164-191`（读表 + 降级日志）
- `Kline/Resources/universe_secids.txt`（278 行，源在 `src/data/universe_secids.txt`）
- 相关篇：[[清单标的盘中自动更新]]