# 云端分片生产改走 Gitee Go（境内 CI）方案

> 状态：**方案，未实施**（2026-09-30 出稿；用户选择「先只出方案文档」，「GitHub PAT 稍后再配」）
> 范围：**只解决生产侧** —— 交易日自动抓东财、产出日分片增量库。**设备侧下载源不动**
> （仍是 `raw.githubusercontent.com` 主源 + jsDelivr 备源）。App 侧零改动。
>
> 一句话：Gitee 有对应 GitHub Actions 的产品 **Gitee Go（码云流水线）**，构建机在**境内**，
> 正是冲 [[20260922-境外Actions访问国内行情源被502拒绝]] 那个根因去的。

## 1. 与「云端方案已判死刑」的关系

| | 内容 |
| :--- | :--- |
| pitfalls 篇的结论 | 境外 Actions runner 访问 `push2.eastmoney.com` 被 **502** → 「云端定时路线不采纳」 |
| 根因性质 | **网络位置**，不是代码 —— 同一份 [`live_db_builder.py`](../../src/live_db_builder.py) 在本机 3312/3312 跑通（184 秒） |
| 本方案做了什么 | 换**执行位置**（境内构建机），不动生成端代码 |
| 不冲突于谁 | 知识库当前走通路径是「设备侧直连东财」（[[清单标的盘中自动更新]]）。**两条不互斥**：本方案复活的是「云端产出全市场分片、App 按缺口取片」那条线 |

## 2. Gitee Go 能力核对（已核实官方文档）

| 需要的能力 | Gitee Go 现状 | 来源 |
| :--- | :--- | :--- |
| 定时触发 | 支持，`triggers.schedule[].cron` | [触发事件](https://help.gitee.com/gitee-go/pipeline/trigger) |
| **但一个流水线只允许一个 cron 表达式** | 文档原话：「目前仅支持填写一个定时表达式，暂时还未开放多个」 | 同上 |
| cron 格式 | 6 段 Quartz 风格 `M H D m d y`；**天与星期不能同时为 `*`**，用 `?` 占位 | 同上 |
| 跑 Python | 插件 `build@python`，Python 2.7 / 3.6~3.9，基础镜像 CentOS 8.3 | [云端编译插件](https://help.gitee.com/gitee-go/plugin/ci-build) |
| 跑任意 shell | `build@python` 的 `commands` 在**代码库根目录**执行，可写任意 shell | 同上 |
| 配置文件落点 | 仓库 `.workflow/<name>.yml` | [官方 Python 示例仓库](https://gitee.com/gitee-go/gitee-go-python-example) |
| 并发保护 | `strategy.blocking: true`（上一次未结束则排队） | [高级设置](https://help.gitee.com/gitee-go/pipeline/advantage-options) |
| 变量 | `variables`，Key ≤32 字符、Value ≤256 字符，`GITEE_` / `GO_` 为保留前缀 | [参数设置](https://help.gitee.com/gitee-go/pipeline/parameter) |
| 免费额度 | 每月 1000 核分（2C4G ≈ 500 分钟），**月末清零**；加时包 500 核分 15 元 | [计费规则](https://help.gitee.com/enterprise/pipeline/billing) |

**两个对我们有利的既有事实：**

1. [`live_db_builder.py`](../../src/live_db_builder.py) **零第三方依赖** —— 只用 `urllib` / `sqlite3` / `concurrent.futures`，
   没有 `requests` / `pandas` / `numpy`，也没有 3.10+ 语法。
   → 流水线**不需要 pip install**，也不依赖 PyPI 网络，`build@python` 开箱能跑。
2. 生成端本来就支持 `--prev <上一版目录>` 和 `--check`，与「取 data 分支上一版做基线」的流程天然对齐。

## 3. 改造设计

### 3.1 代码怎么进 Gitee

需求只有两个文件能被 Gitee Go 拉到：`src/live_db_builder.py` + `src/data/universe.txt`。

- **推荐**：Gitee 网页「从 GitHub 导入仓库」（一次性镜像 `SunChuquin/Kline`）。
  以后改生成端逻辑时，本地加一个 `gitee` remote 双推即可（`git remote add gitee git@gitee.com:<user>/Kline.git`）。
- 不推荐只放 `src/` 最小集 —— 分叉两份代码会漂移。

### 3.2 流水线骨架（`.workflow/sync-live-db.yml`）

> 下面是**据此文档字段写的骨架**，字段名已按官方文档核对；标注 ⚠️ 的地方是**实施时必须先实测**的（见 §4）。

```yaml
version: '1.0'
name: sync-live-db
displayName: 日分片增量库（境内生产）

triggers:
  schedule:
    # ⚠️ 只支持一个表达式；且时区待实测（§4.1）。示例按「北京时间 15:05、周一至周五」写
    - cron: '5 15 ? * 2-6'
  push:
    branches:
      precise:
        - main

strategy:
  blocking: true      # 上一次未跑完则排队，避免两次并发互相覆盖 data 分支
  stepTimeout: 30

variables:
  GH_PUSH_TOKEN: ''   # ⚠️ 明文可见（§3.4）

stages:
  - stage:
    name: publish
    displayName: 生成并发布
    strategy: naturally
    trigger: auto
    steps:
      - step: build@python
        name: build_and_publish
        displayName: 生成当天分片 → 自检 → 发布
        pythonVersion: 3.9
        commands: |
          set -euo pipefail

          # ① 取 GitHub data 分支的上一版，作为「保留 30 片」的基线
          git clone --depth=1 --branch data \
            "https://oauth2:${GH_PUSH_TOKEN}@github.com/SunChuquin/Kline.git" /tmp/prev-src || true
          mkdir -p prev
          [ -d /tmp/prev-src ] && cp -r /tmp/prev-src/live prev/live || true

          # ② 生成当天那一片（真实行情接口，境内网络）
          python3 src/live_db_builder.py \
            --universe src/data/universe.txt --out dist --prev prev/live

          # ③ 自检：manifest 必须与所有分片逐项一致
          python3 src/live_db_builder.py --check --out dist

          # ④ 无变化则跳过发布
          [ "$(cat dist/.changed 2>/dev/null || echo 0)" = "1" ] || { echo '无变化，跳过发布'; exit 0; }

          # ⑤ 在隔离目录里做孤儿提交强推（不在 Gitee Go 工作区里动 git 状态）
          rm -rf /tmp/pub && git clone --depth=1 \
            "https://oauth2:${GH_PUSH_TOKEN}@github.com/SunChuquin/Kline.git" /tmp/pub
          cd /tmp/pub
          rm -rf live && mkdir -p live
          cp "${GITEE_GO_WORKSPACE:-$PWD}/../dist"/*.db dist/manifest.json live/ 2>/dev/null || true
          # （实际路径按 §4.6 实测结果填写：Gitee Go 工作区绝对路径）
          git checkout --orphan data-publish
          git rm -rf --cached . >/dev/null
          git add -f live
          git -c user.name=kline-data-bot \
              -c user.email=kline-data-bot@users.noreply.github.com \
              commit -m "data: 日分片增量库 $(date -u '+%Y-%m-%d %H:%M UTC')"
          git push --force origin HEAD:data
```

设计要点（与 GitHub 版逐条对应）：

| GitHub Actions 版 | Gitee Go 版 |
| :--- | :--- |
| `actions/checkout@v4` | Gitee Go 自动拉 Gitee 仓库到工作区；**GitHub 那份另用 `git clone` 取**（因为产物要发回 GitHub） |
| `git fetch origin data` + `git archive` | `git clone --branch data` 取上一版进 `prev/live` |
| `python3 src/live_db_builder.py …` | 原样不变 |
| `git checkout --orphan` + `git push --force origin HEAD:data` | 挪到 `/tmp/pub` 隔离目录里做，避免污染 Gitee Go 工作区的 git 状态 |

### 3.3 「四个时刻」撞上「只支持一个 cron」

现状是 **11:00 / 14:30 / 15:05 / 17:30** 四个时刻。三条路：

| 方案 | 做法 | 代价 |
| :--- | :--- | :--- |
| **A（推荐）** | 建 **4 条流水线**（`.workflow/sync-1100.yml`、`sync-1430.yml` …），各带一个 cron，`commands` 复用同一段脚本（抽成 `src/publish_buckets.sh` 让 4 条都调它） | 4 条流水线要各自维护，但逻辑只有一份 |
| B | 1 条流水线，cron 每 5 分钟触发，脚本首行判断「是否目标时刻，否则秒退」 | 按次计核分：每天 288 次调度 ≈ 远超 1000 核分额度，**基本不可行** |
| C | 收敛时刻，例如只保留 15:05（收盘后完整K线） | 盘中快照能力丢失 |

### 3.4 凭证：GitHub PAT

- 产物要发回 GitHub `data` 分支 → 必须有一个 **fine-grained PAT**（仅 `contents: write`，只授权 `SunChuquin/Kline` 这一个仓库）。
- 存进 `variables.GH_PUSH_TOKEN`。⚠️ **Gitee Go 的 `variables` 是明文字段**（文档只写了长度限制，未见加密类型），
  所以：① 令牌用最小权限并设短有效期、定期轮换；② 不要把令牌回显到日志（脚本里别 `echo $GH_PUSH_TOKEN`）。
- 若实施时发现 Gitee Go 有加密凭证/环境变量入口，优先用那个。

### 3.5 配额核算（决定要不要降规格）

本机实测生成一次 ≈ **184 秒（≈3.1 分钟）**。按 2C4G（每分钟 2 核分）：

| 频次 | 核分/次 | 每月（22 交易日） | 是否在 1000 核分内 |
| :--- | :--- | :--- | :--- |
| 4 次/天 | ≈ 6.2 | ≈ 546 | 是（但只剩一半余量） |
| 4 次/天，规格降到 1C2G | ≈ 3.1 | ≈ 273 | 是，余量充足 |

生成端是**线程池 IO 等待为主**（34 批 HTTP 请求），1C2G 大概率够用 —— 实施时先用 1C2G 试跑一次计时。

## 4. 实施时必须逐条实测的项（**不要照抄 §3.2**）

1. **cron 时区**：文档写「根据国外时间来，周日是 1」，疑似不是北京时间。**先用一个 5 分钟后触发的 cron 验证**，
   看流水线记录的实际触发时刻，再算偏移量。验证前别配 4 条流水线（否则 4 次都偏）。
2. **Gitee Go → github.com 的 git push 可达性**：这是本方案**最大的不确定点**。
   每次孤儿提交要推 ≈ 30 片 × 0.6MB ≈ **18MB**；国内访问 GitHub 的 HTTPS push 可能慢或失败。
   实测一次计时；失败则走 §5 的备选。
3. **工作区路径与 git 状态**：Gitee Go 的 workspace 绝对路径、是否带 `.git`、能否在 `/tmp` 里 clone/push。
4. **基础镜像是否预装 `git`**：CentOS 8.3 已 EOL，`yum install git` 可能因源下线失败（需换 vault 源）。
   若不预装且装不上，改用 `build@nodejs`（文档明说其镜像「包含 git、wget、Python3 等常规工具」，Node 14 + Python3）。
5. **`build@python` 里 `python3` 的实际版本**（模板默认 3.9，实测确认）。
6. **`dist/` 的绝对路径**：脚本第 ⑤ 步要从 `/tmp/pub` 回头取 `dist/`，路径需按实测填死。

## 5. 风险与备选

| 风险 | 备选 |
| :--- | :--- |
| 境内 CI 推 GitHub 不稳（§4.2） | 产物先发到 **Gitee 自己的 `data` 分支**，再由**本机脚本**（网络好）同步到 GitHub；或者顺势把 App 的**备用源**指向 Gitee（`TdxSyncConfig` 支持备用源可配置，App 主源仍不动） |
| 单 cron 限制（§3.3） | 方案 A 多流水线；或与设备侧直连东财（四时刻）配合，云端只做收盘后那一版 |
| 免费额度月末清零、加时包按核分 | 降到 1C2G；减少时刻数 |
| 明文 token | 最小权限 + 短有效期 + 定期轮换；优先找加密凭证入口 |

## 6. 需要你做的事（实施前）

- [ ] 在 Gitee **从 GitHub 导入** `SunChuquin/Kline`（或用现有仓库改名承接），仓库名建议与 GitHub 同名，减少脚本里的路径改动
- [ ] 仓库页**开通 Gitee Go 流水线**（免费版即可，额度见 §3.5）
- [ ] 生成一个 **fine-grained GitHub PAT**：仅 `contents: write`、仅 `SunChuquin/Kline`，有效期尽量短
- [ ] 把 PAT 填进 Gitee Go 的 `variables.GH_PUSH_TOKEN`
- [ ] 拍板「四个时刻怎么收敛」（§3.3 选 A / C）

## 7. 实施步骤（每阶段都能独立验证）

1. **阶段 1 · 连通性验证（不写业务）**：一条最小流水线，只做「cron 触发 → 打印北京时间 → 确认时区偏移」。
   验收：能算出正确的 cron 表达式。
2. **阶段 2 · 生成验证**：跑 `live_db_builder.py` 生成分片 + `--check` 自检通过，**先不发布**。
   验收：日志里覆盖率达标（3312/3312 类）、`dist/.changed` 正确。
3. **阶段 3 · 发布验证**：加发布步骤，推 GitHub `data` 分支。
   验收：GitHub `data` 分支有新孤儿提交；App 手动「立即更新」能拉到。
4. **阶段 4 · 定时打通**：按 §3.3 落到最终时刻表，连续观察 1~2 个交易日。

## 8. 顺带要拍板的遗留项

[[20260922-境外Actions访问国内行情源被502拒绝]] 里记着一条**未决遗留**：GitHub 上的
`Kline/.github/workflows/sync-live-db.yml` **仍在按 cron 跑并继续失败**（Actions 页面一直有失败记录）。

本方案落地后，应该：**删掉它**，或**改成仅 `workflow_dispatch` 手动触发**。这是本方案的收尾动作，不是前置。

## 9. 相关文档

- [[20260922-境外Actions访问国内行情源被502拒绝]] — 本方案要解的根因
- [[行情同步架构总览]] — 路径矩阵（走通 / 走不通 / 已废弃）
- [[清单标的盘中自动更新]] — 设备侧直连东财（当前的走通路径，与本方案不互斥）
- [Kline-增量行情库自动同步.md](../Kline-增量行情库自动同步.md) — 通道 C 的历史说明（正文已过时）