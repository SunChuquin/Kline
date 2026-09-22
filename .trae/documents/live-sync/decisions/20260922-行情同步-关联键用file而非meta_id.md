# 全程用 file 做关联键，不用 meta_id（2026-09-22 经用户指出后修订）

## 决策

差分生成器、分片/补丁契约、设备增量库、manifest —— **一切跨库/跨端关联都用 `file`**（`SH#600519`），
不用 `meta_id`，也不用 6 位 `code`。

## 为什么（根因）

先澄清一个**容易被误判的点**：`tdx_parser.py` **本身就保证 id 在同一条库谱系里稳定**——
按 `file` 查已有 `meta`，命中就复用 `exist_meta[file]['id']`，只有真正的新文件才取 `next_id`
（`tdx_parser.py:673-680`；`exist_meta` 以 `file` 为键见 `:662`；`--rebuild` 也复用同一套 id）。
**所以「id 会变」不是选 `file` 的理由。**

真正的理由是：

1. **`file` 是端到端契约键**。设备侧增量库（`live_*`）、分片（`bkt_*`）、补丁、manifest 全都以 `file` 为主键，
   从生成端到设备一路不改。选 `meta_id` 就意味着要在设备侧额外维护一层 id 映射。
2. **`file` 唯一且自带语义**：3611/3611 唯一；前缀（`SH#`/`SZ#`/`BJ#`/`27#`/`62#`/`102#`）直接表达市场归属。
3. **`code` 不能用**：主库 `code` 有 55 处重复（如 `62#000995` 与 `SZ#000995` 同为 `000995`）。
4. **`meta_id` 只是 parser 的记账细节，且不可全信**：
   - 跨谱系不可比（不同来源/版本的库 id 分配可以完全不同）；
   - 更隐蔽的是**同一个库文件内部就可能 `meta` 与数据表不同号**：实测 `tdx_project/tdx.db` 的 `meta` 连续
     `1..3611`、数据表 `3..3637`，茅台在 `meta` 里是 732 而真值在 `daily.meta_id=756`。
     详见 [[20260922-基线库meta与数据表id空间不一致产千万行假差异]]。

## 代价 / 现在的规避方式

- `file` 是 TEXT，比 INT 索引略大；3611 只的量级下可忽略。
- 从 `meta_id` 出发的 SQL 需要 JOIN `meta` 才能拿到 `file` —— 差分生成器本来就必须 JOIN `meta`（要取 code/name/type），所以没有额外成本。
- 差分包大小不受影响：实测 **93.9 B/行**。

## 关联代码

- `TrollRestore/diff_live_patch.py`（ATTACH 两库 + 全 SQL 库前缀 + `file` 关联）
- `Kline/src/live_db_builder.py`（`bkt_meta.file PRIMARY KEY`）
- `Kline/Data/LiveDataStore.swift`（`live_meta(file TEXT PRIMARY KEY, …)`）
- `Kline/src/tdx_parser.py:673-680`（id 复用逻辑，本决策的前提澄清）
- 相关篇：[[20260922-行情同步-基线必须是自洽整库拷贝]]、[[复权差分重灌通道]]