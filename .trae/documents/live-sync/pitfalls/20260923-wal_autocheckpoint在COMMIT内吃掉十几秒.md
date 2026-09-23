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

## 关联代码

- `Kline/Infrastructure/KlineHTTPServer.swift`（`PatchSessionManager.begin` 的 `wal_autocheckpoint=0`、
  `deferredWALCheckpoint`、`GET /sync/probe?file=` 只读核对端点）
- `TrollRestore/verify_main_db.py`（需等待延迟回写）
- 相关篇：[[20260923-活跃事务内DETACH必失败]]、[[20260923-行情同步-五张周期表全路径一致性]]