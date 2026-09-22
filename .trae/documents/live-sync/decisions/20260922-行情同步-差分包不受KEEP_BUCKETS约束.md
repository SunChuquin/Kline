# 差分包不受 KEEP_BUCKETS 约束，另立一种包类型（2026-09-22）

## 决策

新增 `patch_<seq>.db` 作为「历史重灌包」：表结构与分片完全一致，但**可含任意多个历史日期**，
且**不受分片 30 片滚动上限约束**；manifest 增加 `patches` 数组与 `buckets` 并列。

## 为什么（根因）

分片契约的前提是「**一片 = 一个交易日**」：分片 id 就是日期换算的 UTC 日序，一片内所有行的 `date` 都等于该片日期，
且只保留最近 30 片（≈6 周）。

而复权改写会让某标的**回填到上市首日**的全部价格变化（实测补丁跨 1990-01-02 ~ 2026-09-22，横跨 36 年）。
若硬用分片承载，就得为每个受影响日期各出一片——动辄上千片，远超 30 片上限。

## 代价 / 现在的规避方式

- 代价：多一种包类型要维护。规避方式是**不新增合并逻辑**：设备侧 `_mergeBucketLocked` 本来就不校验包内日期，
  只做 `ATTACH` + `INSERT OR REPLACE ... SELECT ... FROM bkt.*`，所以补丁包直接复用同一条合并入口，零改动。
- 代价：`KlineHTTPServer` 的文件名白名单要与时俱进。已放行 `patch_` 前缀，同时保留
  `lastPathComponent` 剥目录 + `.db` 后缀 + `resolveSandboxPath` 越界校验三道防护。
- 清理策略独立：补丁与分片一样「合并成功即删」，所以「最近 N 个」上限只作用于
  **幂等记录长度**（`maxMergedPatchRecords = 10`），与分片 30 片滚动互不影响。
- 已知不入包的周期：契约里没有 `bkt_quarterly` / `bkt_yearly`，这两张表只统计不打进包。

## 关联代码

- `TrollRestore/diff_live_patch.py`（出包）
- `Kline/Data/LiveDataStore.swift:720` `_mergeBucketLocked`（不校验日期的合并）
- `Kline/Infrastructure/TdxSyncManager.swift:80-82`（manifest `patches`）、`:849`（`maxMergedPatchRecords`）
- `Kline/Infrastructure/KlineHTTPServer.swift:358`（前缀白名单）
- 相关篇：[[复权差分重灌通道]]、[[20260922-行情同步-基线必须是自洽整库拷贝]]