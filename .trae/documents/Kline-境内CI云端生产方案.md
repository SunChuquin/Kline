# 云端分片生产改走**境内 CI** 方案（CNB 主 / Gitee Go 备）

> 状态：**方案，未实施**（2026-09-30 首稿 Gitee Go 版；2026-10-01 改版：主方案换 **CNB**，纳入 4000 只规模）
> 范围：**只解决生产侧** —— 交易日自动抓东财、产出日分片增量库。**设备侧下载源不动**
> （仍是 `raw.githubusercontent.com` 主源 + jsDelivr 备源）。**App 侧零改动**。
>
> 规模前提（本次新增，来自用户）：**每个工作日自动加载标的 = 4000 只**。
> 这个数字改变了配额结论 —— 见 §6，Gitee Go 免费版在 4000 只 × 4 时刻下**会超支**。
>
> 一句话：Gitee 有对应 GitHub Actions 的产品 **Gitee Go（码云流水线）**，构建机在**境内**；
> 但把它和 CNB（腾讯云云原生构建）放一起比，**CNB 额度约为 Gitee Go 的 10 倍、环境是任意 Docker 镜像、
> 密钥可放密钥仓库、且有官方插件直推 GitHub** —— 所以主方案取 CNB。
> 两者都冲 [[20260922-境外Actions访问国内行情源被502拒绝]] 那个根因（网络位置）去。

## 1. 与「云端方案已判死刑」的关系

| | 内容 |
| :--- | :--- |
| pitfalls 篇的结论 | 境外 Actions runner 访问 `push2.eastmoney.com` 被 **502** → 「云端定时路线不采纳」 |
| 根因性质 | **网络位置**，不是代码 —— 同一份 [`live_db_builder.py`](../../src/live_db_builder.py) 在本机 3312/3312 跑通（184 秒） |
| 本方案做了什么 | 换**执行位置**（境内构建机），**不动生成端代码** |
| 不冲突于谁 | 知识库当前走通路径是「设备侧直连东财」（[[清单标的盘中自动更新]]）。**两条不互斥**：本方案复活的是「云端产出全市场分片、App 按缺口取片」那条线 |

## 2. 4000 只规模基线（先算清成本，再选平台）

### 2.1 实测基线（来自远端 `data` 分支 manifest，2026-09-30）

| 项 | 实测值 |
| :--- | :--- |
| `universe` | **3611**（`src/data/universe.txt` 3631 行，扣注释/空行后入册 3611） |
| `covered` | 3303，`coverage = 0.9147` |
| 单日片体积 | `bucket_20720.db` = **614,400 B ≈ 0.59 MB**（仅 daily） |
| 周首片体积 | `bucket_20726.db` = **921,600 B ≈ 0.88 MB**（daily + weekly） |
| 月首片 | 还会多一张 monthly → 约 1.2 MB（同口径推算，未单独实测） |
| 保留上限 | `KEEP_BUCKETS = 30` 片（≈6 周） |
| 批量快照 | `ULIST_BATCH = 100` → 3611 只里可映射 3312 只 → **34 批** |
| 生成耗时 | 本机实测 34 批 ≈ **184 秒**（受 `MIN_REQUEST_INTERVAL = 0.25s` 全局限速） |

### 2.2 换算到 4000 只

| 项 | 3611 只（实测） | **4000 只（推算）** |
| :--- | :--- | :--- |
| 可映射 secid 数 | 3312（比率 0.917） | 3668（按同比率）～ **4000（保守，假设全可映射）** |
| 批量快照批次数 | 34 | **37（按比率）～ 40（保守）→ 核算一律取 40** |
| 单日片体积 | 0.59 MB | **≈ 0.65 MB** |
| 周首片体积 | 0.88 MB | **≈ 0.98 MB**（保守按 1.0 MB/片上界） |
| 30 片总产物 | ≈ 18 MB | **≈ 20 MB** |
| 生成耗时 | 184 s | **≈ 216 s ≈ 3.6 分钟**（40 批线性外推 + 限速下限 40×0.25 = 10 s） |
| 单次端到端（含取上一版 + 自检 + 推送） | — | **保守按 6 分钟**（拉/推 GitHub 的 20 MB 耗时待实测，§7.2） |

> ⚠️ **前提缺口**：`universe.txt` 现在是 3631 行、入册 3611，**离 4000 还差约 390 条**。
> 若目标清单真的扩到 4000，**先扩 `src/data/universe.txt`**（这是本方案的第 0 步），
> 否则 4000 只是保守上限估算。另外，云端**结构上永远覆盖不到**那 299 只扩展行情指数
> （`27#/62#/102#` 前缀：恒生/行业/主题指数，公开接口无对应 secid），这部分只能由电脑侧
> `build_live_buckets_pc.py` 出片补。所以 4000 里的**有效覆盖上限 ≈ 3700**，
> `MIN_COVERAGE = 0.85` 的门槛在扩表后需要重新校准（否则可能被门槛拦住而误判失败）。

## 3. 候选方案横向对比（回答「除了 Gitee 还有没有更好更免费的」）

| 方案 | 境内构建机 | 免费额度 | 定时 | 环境自由 | 密钥保密 | 推 GitHub | 结论 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CNB**（cnb.cool，腾讯云云原生构建） | ✅ | **160 核时/月**（构建）+ 1600 核时/月（开发）+ 100 GB 对象存储，月末清零、**不叠加**、不限并发 | ✅ crontab（单/多表达式**待实测**） | ✅ **任意 Docker 镜像**（`image: python:3.12`） | ✅ **密钥仓库**（私有 repo + `imports`） | ✅ 官方 `git-sync` 插件 | **主方案** |
| **Gitee Go**（码云流水线） | ✅ | **1000 核分/月**（2C4G ≈ 500 分钟），月末清零；加时包 500 核分 15 元 | ⚠️ **只允许一个 cron 表达式** | ❌ 固定模板：`build@python` 仅 Python ≤3.9，镜像 CentOS 8.3（**已 EOL**） | ❌ `variables` **明文** | ⚠️ 需自己 `git push`，可达性待实测 | 备选 |
| 阿里云**云效 Flow** | ✅ | 基础版 0 元、不限人数 | ✅ | ✅ | ✅ | ⚠️ | 第三备选 |
| 腾讯云 **CODING**（老版 CI） | ✅ | 仅 **10 核时**，官方已引导迁 CNB | ✅ | ⚠️ | ✅ | ⚠️ | 额度太小，不用 |
| **云函数**（腾讯 SCF / 阿里 FC） | ✅ | ⚠️ **不是长期免费**：SCF 自 2024-01-01 起只给**前 3 个月**试用额度；FC 为首次开通 15 万 CU × 3 周期 | ✅ 定时触发器 | ✅ | ✅ | ⚠️ 无 git 客户端，需走 API | **排除**（第 4 个月起计费，且 FC 有 0.01 元最低计费坑） |
| 轻量应用服务器 | ✅ | ❌ **无长期免费** | ✅ | ✅ | ✅ | ✅ | 要钱，排除 |

**CNB 胜出的四条**：

1. **额度 ≈ 10 倍**：160 核时 = 9600 核分，vs Gitee Go 1000 核分。
2. **Docker 即环境**：直接 `image: python:3.12`，绕开 Gitee Go 的 CentOS 8.3（EOL，`yum` 源可能已下线）与 Python ≤3.9 两个坑。
3. **密钥不明文**：`imports` 从私有密钥仓库注入，不像 Gitee Go 的 `variables` 是明文。
4. **官方 `git-sync` 插件**：推 GitHub `data` 分支不用自己写 git 逻辑。

**必须说清的三个坑**：

- 云函数的「免费」是**试用**性质，**第 4 个月起就没有了**（详见上表），不适合长期跑。
- CNB 需**微信扫码注册 + 实名认证**；`crontab` 是否也像 Gitee Go 一样只允许一个表达式，**官方文档未明确，实施前实测**（§7.3）。
- CNB 的免费额度**月末清零、不叠加**，但 4000 只规模下月耗仅约 18 核时（§6），远够。

## 4. 主方案：CNB

### 4.1 代码怎么进 CNB

- 在 CNB 建仓库，从 GitHub 导入 `SunChuquin/Kline`（一次性镜像）；以后本地加 `cnb` remote 双推。
- 另建**一个私有密钥仓库**，只放一个 `envs.yml`（`GH_PUSH_TOKEN=<fine-grained PAT>`），主仓库用 `imports` 引它。
- 不推荐只放 `src/` 最小集 —— 分叉两份代码会漂移。

### 4.2 流水线骨架（`.cnb.yml`）

> ⚠️ 下面是**示意骨架**：`image` / `imports` / `git-sync` 的 settings 字段已核实，
> **`crontab` 与 `stages` 的具体键名以官方文档为准，实施前先按 §7.3 实测**。

```yaml
# .cnb.yml
imports:
  - https://cnb.cool/<org>/kline-secrets/-/blob/main/envs.yml   # 注入 GH_PUSH_TOKEN

main:
  crontab:
    # 4 个时刻各一条（是否允许多条待实测；若只允许一条 → 走 §5.3 方案 A 的思路：多流水线）
    - cron: '0 11 * * 1-5'
      stages:
        - name: publish
          image: python:3.12          # Docker 即环境：绕开 Gitee Go 的 CentOS 8.3 / Python ≤3.9
          script: bash src/publish_buckets.sh
    - cron: '30 14 * * 1-5'
      stages:
        - name: publish
          image: python:3.12
          script: bash src/publish_buckets.sh

  push:
    paths:
      - src/live_db_builder.py
      - src/data/universe.txt
      - src/publish_buckets.sh
    stages:
      - name: publish
        image: python:3.12
        script: bash src/publish_buckets.sh
```

### 4.3 发布段（`src/publish_buckets.sh`，CNB / Gitee Go 两条流水线**共用同一份**）

```bash
set -euo pipefail

# ① 取 GitHub data 分支上一版，作为「保留 30 片」的基线
git clone --depth=1 --branch data \
  "https://oauth2:${GH_PUSH_TOKEN}@github.com/SunChuquin/Kline.git" /tmp/prev-src
mkdir -p prev && cp -r /tmp/prev-src/live prev/live

# ② 生成当天那一片（真实行情接口，境内网络）
python3 src/live_db_builder.py \
  --universe src/data/universe.txt --out dist --prev prev/live

# ③ 自检：manifest 必须与所有分片逐项一致
python3 src/live_db_builder.py --check --out dist

# ④ 无变化则跳过发布
[ "$(cat dist/.changed 2>/dev/null || echo 0)" = "1" ] || { echo '无变化，跳过发布'; exit 0; }
```

发布回 GitHub 有两条路，**优先 ①**：

| | 做法 | 说明 |
| :--- | :--- | :--- |
| **① git-sync 插件（推荐）** | 用官方 `git-sync`（`image: tencentcom/git-sync`，settings：`target_url` / `auth_type` / `username` / `password` / `force: true`）把 `dist/` 以**孤儿提交**强推到 GitHub `data` 分支 | 不用自己写 git 逻辑，CNB 官方维护 |
| ② 手写 git（兜底） | 在 `/tmp/pub` 里 clone → `git checkout --orphan` → `git rm -rf --cached .` → `git add -f live` → 强推 `HEAD:data` | 与现在 GitHub Actions 版同款逻辑 |

> 关键点：**在隔离目录（`/tmp/pub`）里做孤儿提交**，不要在 CI 工作区里动 git 状态，免得污染后续步骤。

## 5. 备选方案：Gitee Go

### 5.1 能力核对（已核实官方文档）

| 需要的能力 | Gitee Go 现状 | 来源 |
| :--- | :--- | :--- |
| 定时触发 | 支持，`triggers.schedule[].cron` | [触发事件](https://help.gitee.com/gitee-go/pipeline/trigger) |
| **但一个流水线只允许一个 cron 表达式** | 文档原话：「目前仅支持填写一个定时表达式，暂时还未开放多个」 | 同上 |
| cron 格式 | 6 段 Quartz 风格 `M H D m d y`；**天与星期不能同时为 `*`**，用 `?` 占位；时区疑似非北京时间 | 同上 |
| 跑 Python | 插件 `build@python`，Python 2.7 / 3.6~3.9，基础镜像 CentOS 8.3 | [云端编译插件](https://help.gitee.com/gitee-go/plugin/ci-build) |
| 跑任意 shell | `build@python` 的 `commands` 在**代码库根目录**执行 | 同上 |
| 配置文件落点 | 仓库 `.workflow/<name>.yml` | [官方示例仓库](https://gitee.com/gitee-go/gitee-go-python-example) |
| 并发保护 | `strategy.blocking: true`（上一次未结束则排队） | [高级设置](https://help.gitee.com/gitee-go/pipeline/advantage-options) |
| 变量 | `variables`，Key ≤32 字符、Value ≤256 字符，`GITEE_` / `GO_` 为保留前缀，**明文** | [参数设置](https://help.gitee.com/gitee-go/pipeline/parameter) |
| 免费额度 | 每月 1000 核分（2C4G ≈ 500 分钟），**月末清零**；加时包 500 核分 15 元 | [计费规则](https://help.gitee.com/enterprise/pipeline/billing) |

**两个对我们有利的既有事实：**

1. [`live_db_builder.py`](../../src/live_db_builder.py) **零第三方依赖** —— 只用 `urllib` / `sqlite3` / `concurrent.futures`，
   没有 `requests` / `pandas` / `numpy`，也没有 3.10+ 语法 → 流水线**不需要 pip install**，不依赖 PyPI 网络。
2. 生成端本来就有 `--prev <上一版目录>` 与 `--check`，与「取 data 分支上一版做基线」天然对齐。

### 5.2 流水线骨架（`.workflow/sync-live-db.yml`）

```yaml
version: '1.0'
name: sync-live-db
displayName: 日分片增量库（境内生产）

triggers:
  schedule:
    # ⚠️ 只支持一个表达式；时区待实测（§7.1）。示例按「北京时间 15:05、周一至周五」写
    - cron: '5 15 ? * 2-6'
  push:
    branches:
      precise:
        - main

strategy:
  blocking: true      # 上一次未跑完则排队，避免两次并发互相覆盖 data 分支
  stepTimeout: 30

variables:
  GH_PUSH_TOKEN: ''   # ⚠️ 明文可见（§5.4）

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
          # ①②③④ 与 §4.3 的 src/publish_buckets.sh 完全一致（CNB / Gitee Go 共用一份脚本）
          bash src/publish_buckets.sh
          # ⑤ 发布：优先用 §4.3 的手写 git 兜底路径（Gitee Go 无 git-sync 插件）
```

### 5.3 「四个时刻」撞上「只支持一个 cron」

现状是 **11:00 / 14:30 / 15:05 / 17:30** 四个时刻。三条路：

| 方案 | 做法 | 代价 |
| :--- | :--- | :--- |
| **A（推荐）** | 建 **4 条流水线**（`sync-1100.yml`、`sync-1430.yml` …），各带一个 cron，`commands` 都调 `src/publish_buckets.sh` | 4 条流水线要各自维护，但逻辑只有一份 |
| B | 1 条流水线，cron 每 5 分钟触发，脚本首行判断「是否目标时刻，否则秒退」 | 每天 288 次调度，**远超 1000 核分额度**，不可行 |
| C | 收敛时刻，例如只保留 15:05（收盘后完整K线） | 盘中快照能力丢失 |

> 注意：4000 只规模下走方案 A 的 4 时刻，**Gitee Go 免费额度会超支**（§6），
> 所以 Gitee Go 这条备选实际上只能配 1C2G 或方案 C。

### 5.4 凭证：GitHub PAT

- 产物要发回 GitHub `data` 分支 → 必须有一个 **fine-grained PAT**（仅 `contents: write`，只授权 `SunChuquin/Kline`）。
- ⚠️ **Gitee Go 的 `variables` 是明文字段**，所以：① 令牌用最小权限 + 短有效期、定期轮换；
  ② 不要把令牌回显到日志（别 `echo $GH_PUSH_TOKEN`）。
- **这正是改用 CNB 的理由之一** —— CNB 走 `imports` 密钥仓库，配置文件里没有明文令牌。

## 6. 配额核算（**按 4000 只重算**）

单次端到端保守取 **6 分钟**（生成 3.6 min + 取上一版/自检/推送 2.4 min）。
计费公式：`消耗 = 运行分钟数 × CPU 核数`（Gitee Go 核分）；`1 核时 = 60 核分`（CNB）。

交易日按 **22 天/月**，每天 **4 个时刻** → **88 次/月**。

| 平台 / 规格 | 单次消耗 | 月消耗 | 免费额度 | 结论 |
| :--- | :--- | :--- | :--- | :--- |
| Gitee Go · 2C4G（默认） | 12 核分 | **1056 核分** | 1000 核分 | ❌ **超支** |
| Gitee Go · 1C2G | 6 核分 | 528 核分 | 1000 核分 | ✅ 余 47% |
| Gitee Go · 2C4G，仅 1 次/天 | 12 核分 | 264 核分 | 1000 核分 | ✅ 但丢了盘中快照 |
| **CNB · 2 核** | 12 核分 = 0.2 核时 | **17.6 核时** | 160 核时 | ✅ **仅占 11%** |
| CNB · 4 核 | 0.4 核时 | 35.2 核时 | 160 核时 | ✅ 占 22% |

**这就是把主方案从 Gitee Go 换成 CNB 的决定性一条**：
4000 只规模下，Gitee Go 免费版按默认规格 4 时刻跑**会超**（1056 > 1000），必须降规格或砍时刻；
而 CNB 只用掉约 1/10 额度，规格还能往上升。

> 生成端以**线程池 + 全局限速的网络等待**为主（40 批 HTTP），CPU 不是瓶颈；
> 选规格时优先保内存（sqlite 落盘 + 30 片比对），`1C2G`~`2C4G` 都够。

## 7. 实施时必须逐条实测的项（**不要照抄上面的 YAML**）

1. **cron 时区（Gitee Go）**：官方文档写「根据国外时间来，周日是 1」，疑似不是北京时间。
   先用一个 5 分钟后触发的 cron 验证，看流水线记录的实际触发时刻，再算偏移量。验证前别配 4 条流水线。
2. **境内 CI → github.com 的 git push 可达性**：这是本方案**最大的不确定点**。
   每次孤儿提交要推 **≈ 20 MB**（30 片）。实测一次计时；若太慢或失败，走 §8 备选。
3. **CNB 的 crontab 是否允许多个表达式**：若与 Gitee Go 一样只能一条，把 §4.2 的 4 条 cron 拆成 4 个流水线。
4. **CNB 免费额度的口径**：160 核时是「构建」额度，确认定时任务是否计入同一池、是否真不限并发。
5. **Gitee Go 基础镜像是否预装 `git`**：CentOS 8.3 已 EOL，`yum install git` 可能因源下线失败（需换 vault 源）。
   若不预装且装不上，改用 `build@nodejs`（文档明说其镜像「包含 git、wget、Python3 等常规工具」）。
6. **`build@python` 里 `python3` 的实际版本**（模板默认 3.9，实测确认）。
7. **工作区路径**：CNB / Gitee Go 的工作区绝对路径，以及能否在 `/tmp` 里 clone / push。
8. **扩表后的覆盖率门槛**：`universe.txt` 扩到 4000 后，`MIN_COVERAGE = 0.85` 是否仍合适
   （云端有效覆盖上限 ≈ 3700，比率 ≈ 0.925，理论上仍高于 0.85，但要跑一次看实际值）。

## 8. 风险与备选

| 风险 | 备选 |
| :--- | :--- |
| 境内 CI 推 GitHub 不稳（§7.2） | 产物先发到 **CNB/Gitee 自己的 `data` 分支**，再由本机脚本（网络好）同步到 GitHub；或顺势把 App 的**备用源**指向境内（`TdxSyncConfig` 支持备用源可配置，App 主源仍不动） |
| 单 cron 限制（§5.3 / §7.3） | 方案 A 多流水线；或与设备侧直连东财（四时刻）配合，云端只做收盘后那一版 |
| 免费额度月末清零、不叠加 | CNB 已留 10 倍余量；Gitee Go 需降到 1C2G |
| 明文 token（仅 Gitee Go） | 主方案走 CNB 密钥仓库；若退回 Gitee Go 则最小权限 + 短有效期 + 定期轮换 |
| 4000 只里 299 只扩展行情指数覆盖不到 | 由电脑侧 `build_live_buckets_pc.py` 出片补（这条本来就存在，与 CI 选择无关） |

## 9. 需要你做的事（实施前）

- [ ] **拍板平台**：CNB（推荐）还是 Gitee Go（备选）
- [ ] 注册并实名：CNB 需**微信扫码 + 实名认证**（若选 CNB）；Gitee 你已有账号
- [ ] 建仓库：从 GitHub 导入 `SunChuquin/Kline`，仓库名与 GitHub 同名（减少脚本路径改动）
- [ ] **扩清单**：把 `src/data/universe.txt` 从 3631 行补到 **4000 只**（本方案的第 0 步）
- [ ] 生成 **fine-grained GitHub PAT**：仅 `contents: write`、仅 `SunChuquin/Kline`，有效期尽量短
      （CNB → 存密钥仓库；Gitee Go → 存 `variables`）
- [ ] 拍板「四个时刻怎么收敛」（§5.3 选 A / C；4000 只规模下 Gitee Go 只能选 C 或上 1C2G）
- [ ] 开通流水线（CNB 免费额度 / Gitee Go 免费版）

## 10. 实施步骤（每阶段都能独立验证）

1. **阶段 0 · 扩清单**：`universe.txt` 补到 4000 只，本机跑一次 `--out dist --prev prev/live` 确认覆盖率与耗时。
   验收：实际耗时、批次数、覆盖率记录下来，回填本文件 §2.2。
2. **阶段 1 · 连通性验证（不写业务）**：一条最小流水线，只做「cron 触发 → 打印北京时间 → 确认时区偏移」。
   验收：能算出正确的 cron 表达式（CNB 与 Gitee Go 各验一次）。
3. **阶段 2 · 生成验证**：跑 `live_db_builder.py` 生成分片 + `--check` 自检通过，**先不发布**。
   验收：日志里覆盖率达标（4000 口径）、`dist/.changed` 正确、耗时与 §2.2 推算相符。
4. **阶段 3 · 发布验证**：加发布步骤，推 GitHub `data` 分支。
   验收：GitHub `data` 分支有新孤儿提交（≈20 MB）；App 手动「立即更新」能拉到。
5. **阶段 4 · 定时打通**：按 §5.3 落到最终时刻表，连续观察 1~2 个交易日，核对实际扣减的核分/核时。

## 11. 顺带要拍板的遗留项

[[20260922-境外Actions访问国内行情源被502拒绝]] 里记着一条**未决遗留**：GitHub 上的
`.github/workflows/sync-live-db.yml` **仍在按 cron 跑并继续失败**（Actions 页面一直有失败记录）。

本方案落地后，应该：**删掉它**，或**改成仅 `workflow_dispatch` 手动触发**。这是本方案的收尾动作，不是前置。

## 12. 相关文档

- [[20260922-境外Actions访问国内行情源被502拒绝]] — 本方案要解的根因
- [[行情同步架构总览]] — 路径矩阵（走通 / 走不通 / 已废弃）
- [[清单标的盘中自动更新]] — 设备侧直连东财（当前的走通路径，与本方案不互斥）
- [Kline-增量行情库自动同步.md](../Kline-增量行情库自动同步.md) — 通道 C 的历史说明（正文已过时）