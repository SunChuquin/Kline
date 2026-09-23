# SQLite 的 `wal_autocheckpoint` 会在 COMMIT 语句内部吃掉十几秒（2026-09-23）

## 现象

「会话式单事务落主库」的 `POST /sync/patch-session/commit` 真机实测 **13.8s**，是端到端最大的一块。
插桩后的分解（**证据，不是猜测**）：

```
commit 分解：队列排队=7ms · UPDATE meta.last_date=62ms · COMMIT=13829ms
            · sqlite3_close=8ms · 会话队列合计=13906ms
            · COMMIT 后 WAL=214.6MB
commit 分段（主线程）：loadMetaList 入队=0ms · notifyMainDBChanged=0ms · 拼+写响应=0ms
```

**12s 全在 `COMMIT` 这一句里**。

## 根因

SQLite 的 **`wal_autocheckpoint` 默认 = 1000 页**（约 4 MB）。
本流程一个大事务往 WAL 里追加了 **214.6 MB**，于是 **SQLite 在 `COMMIT` 语句内部**先做了一次
**全量 PASSIVE 回写**（把 WAL 帧写回主库文件），才有那 13.8s。

由此**推翻了两个看上去很合理的假设**（都已被实测否定，记录下来避免后人重走）：

| 假设 | 实测 | 结论 |
| :--- | :--- | :--- |
| 热刷新（`loadMetaList` + `notifyMainDBChanged`，会触发 3611 只全量重取）阻塞了响应 | 三项均 **0 ms**；`[Cache] dataVersion 变化 → 重取行 n=3611` 出现在**响应之后 40ms** | ❌ 否 |
| `sqlite3_close` 触发 WAL checkpoint | close 仅 **8 ms** | ❌ 否 |

## 现在的规避方式

1. **会话连接上设 `PRAGMA wal_autocheckpoint=0`**（在 `PatchSessionManager.begin`）→ COMMIT 只追加提交记录。
   **13,829ms → 633ms**（第二跑 1591ms；残留的 0.6~1.6s 是 WAL 尾段刷盘，属固有开销）
2. **响应之后再做延迟回写**：`deferredWALCheckpoint()` 用**独立短连接**执行 `wal_checkpoint(PASSIVE)`。
   - 为什么要独立连接：走 App 的 `dbQueue` 会把 3611 行的热刷新堵十几秒
   - 为什么可以延后：**WAL 语义下其它连接能立刻看到已提交的数据** ——
     这一点做过**决定性验证**：把 `SH#600519` 末日 close 临时改成 `1200.00`，commit 响应后 **0.9s**
     用 **App 自身连接**读回，得到 `quarterlyLastClose=1200.0000`（此时 WAL=322MB、延迟回写尚未结束、
     主库文件里还没有它）→ **证明 App 不会读到旧值**。随后还原数据重跑，读回 `1253.8000`。

## 三条必须记住的副作用

1. **`verify_main_db.py` 现在必须等延迟回写完成（约 13s）后再拉** —— 它拉的是**主库文件**，
   而延迟回写尚未完成时文件里还没有新数据（App 侧不受影响，因为 App 读 WAL）。工具语义变了，需知悉。
2. `wal_checkpoint(PASSIVE)` 在有并发读时**可能只回写一部分**。实测本次 `rc=0` 且下轮 WAL 回落
   （322MB → 107MB，帧被复用，未无限增长）。若长期不完整，WAL 会缓慢膨胀 →
   可后续加「循环回写至 `log == checkpointed`」兜底。
3. 不要为了省这点时间去动 `PRAGMA synchronous=OFF`（未采纳，无必要）。

## 回写必须**有界循环**，且 `busy_timeout` 绝对不能设

`wal_checkpoint(PASSIVE)` 在有并发读时**可能只回写一部分**（甚至一次都不推进），所以必须有兜底：

**实现（`deferredWALCheckpoint()`）**：
- 主循环 `PASSIVE` → 直到 `log == checkpointed`，再做 `TRUNCATE` 截断 WAL 文件；
  **上限 30 次 / 总预算 60s / 间隔 2s**
- **延迟段**：实测那 60s 窗口几乎全程与 App 提交后的 3611 行热刷新重叠（25/25 次 TRUNCATE 全 `busy=1`），
  故当「已回写、只差截断」时，**等 60s 再试最多 3 次**（间隔 20s）。合计 ≤33 次、≤~160s，**全程后台 sleep**
- `PRAGMA journal_size_limit=64MB`（**连接级、不随库持久化**，所以会话连接与回写连接都要设）
- 每轮都打日志：`log` / `checkpointed` / `rc` / `busy` / WAL 字节数；结束时打「完成 or 未完成」+ 最终 WAL

**实测收敛证据**（背靠背 3 次流水线）：
`begin 0.0MB → commit 时 107.2 / 214.3 / 322.0MB → 回写后 0.0 / 0.0 / 0.0MB`，
落盘 `tdx.db-wal = 0.0KB`，**无单调增长**（修正前是 321.9 → 429.2 → 536.8 递增）。

### 两个踩过的坑（都已被实测否掉，别重走）

1. **`busy_timeout` 有害**：给回写连接设 `busy_timeout=15s` 后，等待中的 `TRUNCATE` 会让**下一轮
   `BEGIN IMMEDIATE` 立即报 `database is locked`** → 连跑第 3 次时 `begin` 失败、流水线中断。
   **结论：回写一律「立即失败 + 有界重试」，绝不设 `busy_timeout`。**
2. **别把 SQLite 返回的 `(-1, -1)` 当成「已回写」**：连 CKPT 锁都没拿到时 `log`/`checkpointed` 返回 -1
   （乘法后表现为 `log=-4096`），曾被误判为完成。判据要写成 **`log >= 0 && log <= checkpointed`**。

## 关联代码

- `Kline/Infrastructure/KlineHTTPServer.swift`（`PatchSessionManager.begin` 的 `wal_autocheckpoint=0`、
  `deferredWALCheckpoint`、`GET /sync/probe?file=` 只读核对端点）
- `TrollRestore/verify_main_db.py`（需等待延迟回写）
- 相关篇：[[20260923-活跃事务内DETACH必失败]]、[[20260923-行情同步-五张周期表全路径一致性]]