# 云端分片生产改走**境内 CI** 方案（CNB 主 / Gitee Go 备）

> 状态：**方案，未实施**（2026-09-30 首稿；2026-10-01 二稿：纳入 CNB 背景调研与 4000 只规模；
> 2026-10-01 三稿：规模回落到标的库实测口径、调度收敛为**每工作日 18:00 一次**；
> 2026-10-01 四稿：核实 CNB 的 `crontab` 键名与镜像声明键名，§6.2 骨架已去掉 ⚠️；
> 2026-10-01 五稿：**云端只发日线表**（周/月线改由 App 本地聚合，见 §3、§3.3））
>
> 范围：**只解决生产侧** —— 工作日收盘后自动抓东财、产出**只含日线表**的日分片增量库。
> 设备侧下载源不动（仍是 `raw.githubusercontent.com` 主源 + jsDelivr 备源）。
>
> ⚠️ **App 侧不再是"零改动"**：分片只发日线后，**周/月线要由 App 本地从日线聚合**。
> 现有 App 只对**季/年**做当期聚合（`WatchlistSyncManager.currentPeriodBars`），
> 需要把同一套逻辑扩到周/月（详见 §3.3 末尾的现状核对）。
>
> 前提（来自用户更正）：
> 1. 标的数**以标的数据库实测为准**（`src/data/universe.txt`），不是 Round 数估计；
> 2. 云端只需**每工作日 18:00 跑一次**（收盘后完整日K），**不是每天四次**；
> 3. 这与 App 侧「每日四次盘中更新」是**两个互不相干的任务**（见 §2）；
> 4. **云端不需要存日线以外的周期数据** —— App 下载日线后自行生成周/月线（见 §3.3）。
>
> 一句话：把「云端分片生产」的执行位置从境外 Actions 换到**境内 CI**，
> 冲 [[20260922-境外Actions访问国内行情源被502拒绝]] 的根因（网络位置）去。
> 主方案取 **CNB**（腾讯云云原生构建），Gitee Go 为备选 —— 理由不是额度（见 §8，两者都够），
> 而是**环境可控性、密钥保密、长期确定性**（见 §5、§6）。

## 1. 与「云端方案已判死刑」的关系

| | 内容 |
| :--- | :--- |
| pitfalls 篇的结论 | 境外 Actions runner 访问 `push2.eastmoney.com` 被 **502** → 「云端定时路线不采纳」 |
| 根因性质 | **网络位置**，不是代码 —— 同一份 [`live_db_builder.py`](../../src/live_db_builder.py) 在本机 3312/3312 跑通（184 秒） |
| 本方案做了什么 | 换**执行位置**（境内构建机），**不动生成端代码** |
| 不冲突于谁 | 知识库当前走通路径是「设备侧直连东财」（[[清单标的盘中自动更新]]）。**两条不互斥**，见 §2 |

## 2. 先划清任务边界：云端生产 ≠ App 盘中更新

这是**两个独立任务**，别混在一起算账：

| | 任务 A · 云端每日生产（**本方案**） | 任务 B · App 盘中更新（**已存在，不动**） |
| :--- | :--- | :--- |
| 跑在哪 | 境内 CI（CNB / Gitee Go） | 设备本地（iPad 上的 Kline） |
| 数据源 | 东财公开接口（境内网络） | 东财公开接口（设备国内网络直连） |
| 跑的标的 | **全市场** `src/data/universe.txt`（约 3631） | App 内 6 类清单的**并集** |
| 频次 | **每工作日 18:00 一次**（收盘后） | 每交易日 **11:00 / 14:30 / 15:05 / 17:30** |
| 产出 | `data` 分支的日分片增量库（**只含日线表**，供所有设备下载） | 只写设备本地增量库，不对外发布 |
| 依赖 PC | 不要 | 不要 |

**结论**：任务 B 的四时刻不受本方案影响，本方案也**不占用**它的额度（不在同一平台）。
之前文档里"四个时刻撞上单 cron"的问题**在任务 A 的 18:00 单次调度下自然消失**（§7.3）。

## 3. 规模基线（以标的库实测为准）

### 3.1 实测基线（远端 `data` 分支 manifest + 本机清单）

| 项 | 实测值 |
| :--- | :--- |
| `src/data/universe.txt` | **3631 行**（含注释/空行，入册 `universe` 实测 **3611**） |
| `covered` / `coverage` | 3303 / `0.9147`（远端 manifest，2026-09-30） |
| 其中不可映射 | **299 只**扩展行情指数（`27#/62#/102#` 前缀：恒生/行业/主题指数），公开接口无对应 secid |
| 单日片体积 | `bucket_20720.db` = **614,400 B = 600 KiB**（**仅 daily 表**） |
| ~~周首片 921,600 B~~ | 那是**现状**（daily + weekly 两张表）；**改为只发日线后，每片统一回到 600 KiB** |
| 保留上限 | `KEEP_BUCKETS = 30` 片（≈6 周） |
| 批量快照 | `ULIST_BATCH = 100` → 可映射 3312 只 → **34 批** |
| 生成耗时 | 本机实测 34 批 ≈ **184 秒 ≈ 5.4 s/批**。东财批量接口**自身的响应时间**是主因；`MIN_REQUEST_INTERVAL = 0.25s`（≈4 请求/秒）只是**下限保护**（34 × 0.25 = 8.5 s），不是瓶颈 |
| 30 片总产物 | 30 × 600 KiB ≈ **18 MB** |

> **只发日线**是用户 2026-10-01 的更正：周/月线由 App 从日线聚合，云端不必存（§3.3）。
> 生成端现状是 `PERIODS = ("daily", "weekly", "monthly")`（[live_db_builder.py](../../src/live_db_builder.py#L113)），
> 云端调用时需改成只发 `daily`（季/年本来就不在分片里）。

### 3.2 单次运行成本

| 环节 | 耗时 |
| :--- | :--- |
| 取 GitHub `data` 分支上一版（≈18 MB） | 待实测（§9.2） |
| 生成（34 批） | ≈ 184 s ≈ **3.1 分钟** |
| `--check` 自检 | 秒级 |
| 发布（孤儿提交 ≈18 MB 推 GitHub） | 待实测（§9.2） |
| **单次端到端（保守）** | **≈ 6 分钟** |

> `universe.txt` 现在 3631 行即可满足需要，**不需要扩表**。
> 上一稿按 4000 只做的保守换算（40 批 / 单日片 0.65 MB / 30 片 20 MB）作废，本文一律用实测口径。
> 若将来清单真有扩到 4000 的一天，把上表的批次数按 `ceil(N/100)` 线性外推即可。
>
> ⚠️ 门槛提醒：`MIN_COVERAGE = 0.85`，分母含那 299 只**云端结构上永远覆盖不到**的扩展指数
> （有效上限 3312/3611 ≈ 0.917）。扩表后要重新校准，否则可能被门槛拦住误判失败。

### 3.3 设备侧：周/月线由谁生成 + CNB 当下载源的流量与耗时

> 前半段是**方案内的**（"只发日线"带来的 App 侧工作）；后半段是**探索项**（不在本方案范围，
> 但同属 [[20260922-境外Actions访问国内行情源被502拒绝]] 的"网络位置"根因，故先记结论）。

**① 现状核对：App 现在只对"季/年"做本地聚合**

| 周期 | 现状数据来源 | 说明 |
| :--- | :--- | :--- |
| 日线 | 云端分片 `bkt_daily` → `live_daily` | 若改成只发日线，这条不变 |
| **周/月线** | **云端分片** `bkt_weekly` / `bkt_monthly` → `live_weekly` / `live_monthly` | ⚠️ **目前没有本地聚合**，全靠分片喂 |
| 季/年线 | **App 本地聚合**（`WatchlistSyncManager.currentPeriodBars`，主库当期 bar ⊕ 新日线） | 因为季/年**本来就不在分片里**（`PERIODS` 只含三张表） |

所以"云端只发日线"要落地，**必须把 `currentPeriodBars` 从季/年扩到周/月** —— 逻辑现成（同一套
`open` 取首行 / `high-low` 取极值 / `close` 取末行 / `vol-amo` 累加），只需再加"本周一 / 本月首日"两个起始日；
否则周/月线会**停在主库最近一次同步日**，App 盘中的周/月线不再前进。

**② CNB 当设备侧下载源：有没有流量限制**

官方《社区版计费说明》的**计费项里没有"流量 / 带宽"这一条**：

| 计费项 | 免费额度 |
| :--- | :--- |
| 仓库存储（Git 对象） | 100 GiB |
| 对象存储（**制品、LFS 对象**、图片及附件） | 100 GiB |
| 云原生构建-CPU / 开发-CPU | 160 / 1600 核时·月 |
| AI Credits | 500/月 |

即：**下载制品、拉取仓库文件不产生任何计费项**；免费额度用尽的结果也只是"能力受限 / 组织转只读"，
且只针对存储与算力。**"没有流量费"可以确认。**

⚠️ 但**公网侧的并发数 / 带宽 / 限速，官方文档没有给任何公开数字**（"在腾讯云 VPC 内访问 CNB，
自动享有内网访问加速，无需流量费用"这句**只针对 VPC 内**）。所以**"没有流量费"可确认，
"没有速率限制"不能确认**，列为 §9 实测项。

**③ 单日（600 KiB）下载耗时估算**

| 源 | 实测/估算 |
| :--- | :--- |
| 当前主源 `raw.githubusercontent.com` | 实测 108 KiB / **1.79 s** ≈ 62 KB/s → 600 KiB ≈ **10 s** |
| 当前备源 jsDelivr | 实测 108 KiB / **3.83 s** ≈ 29 KB/s → 600 KiB ≈ **21 s** |
| CNB（腾讯云境内） | 600 KiB ÷ 典型境内 1–5 MB/s ≈ **0.2–1 s**（含 TLS/RTT） |

结论：**同一片数据，境内源比 GitHub raw 快约一个数量级**；首次装机的 30 片全量（≈18 MB）也从
GitHub raw 的几分钟降到境内源的几秒~十几秒。现有下载器
（[TdxSyncConfig.swift](../../Kline/Infrastructure/TdxSyncConfig.swift#L39-L42)）本来就是
**可配置的多源列表 + 按序回退**，加一个 CNB 源属**配置级**改动（manifest + sha256 契约、校验与合并逻辑都不用动）。
唯一待核实的是 **CNB 仓库文件的匿名直链格式**（GitHub 形如 `raw.githubusercontent.com/<o>/<r>/<branch>/<path>`，
CNB 的对应形态需实测，§9）。

## 4. 候选方案横向对比

| 方案 | 境内构建机 | 免费额度 | 定时 | 环境自由 | 密钥保密 | 推 GitHub | 结论 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CNB**（cnb.cool，腾讯云云原生构建） | ✅ | **160 核时/月**（构建）+ 1600 核时/月（开发）+ 100 GiB ×2 存储，**月底清零、不叠加** | ✅ `"crontab: <表达式>"`，时区 `Asia/Shanghai`（**已核实**，§6.2） | ✅ **任意 Docker 镜像** | ✅ **密钥仓库** | ✅ 官方 `git-sync` 插件 | **主方案** |
| **Gitee Go**（码云流水线） | ✅ | **1000 核分/月**（2C4G ≈ 500 分钟），月末清零；加时包 500 核分 15 元 | ⚠️ 只允许一个 cron 表达式（18:00 单次，**够用**） | ❌ 固定模板：`build@python` 仅 Python ≤3.9，镜像 CentOS 8.3（**已 EOL**） | ❌ `variables` **明文** | ⚠️ 需自己 `git push`，可达性待实测 | 备选 |
| 阿里云**云效 Flow** | ✅ | 基础版 0 元、不限人数 | ✅ | ✅ | ✅ | ⚠️ | 第三备选 |
| 腾讯云 **CODING**（老版 CI） | ✅ | 仅 10 核时；**已退市**（标准版 2025-09-01 下线） | — | — | — | — | 不可用 |
| **云函数**（腾讯 SCF / 阿里 FC） | ✅ | ⚠️ **不是长期免费**：SCF 自 2024-01-01 起只给**前 3 个月**试用额度；FC 为首次开通 15 万 CU × 3 周期 | ✅ | ✅ | ✅ | ⚠️ 无 git 客户端 | **排除** |
| 轻量应用服务器 | ✅ | ❌ 无长期免费 | ✅ | ✅ | ✅ | ✅ | 要钱，排除 |

> 注：CODING 已被腾讯云公告退市，官方指引用户迁到 CNB，所以"CODING 老版 CI"这条已从候选里划掉。

## 5. CNB 背景调研（回答"限时免费还是有条件 / 为什么免费 / 上线多久"）

### 5.1 免费额度的性质：**基线长期 + 超额按量 + 曾有公测加量**

官方《社区版计费说明》写明计费模式是「**免费额度 + 超额按量计费**」：

| 计费项 | 免费额度 | 超额单价 | 统计范围 |
| :--- | :--- | :--- | :--- |
| 云原生构建-CPU | **160 核时/月** | 0.125 元/核时 | 流水线 CPU |
| 云原生开发-CPU | 1600 核时/月 | 0.125 元/核时 | 开发空间 CPU |
| 仓库存储 | 100 GiB | 1 元/GiB/月 | Git 对象 |
| 对象存储 | 100 GiB | 1 元/GiB/月 | 制品 / LFS / 附件 |
| AI Credits | 500/月 | 0.05 元/credit | NPC 等 AI 能力 |

免费额度**月底清零、不叠加至次月**；用尽后能力受限（欠费则组织转只读：禁止 push、禁止启动新流水线）。

⚠️ **确实存在"限时"成分，但与我们无关**：2024-11 开放公测时，官方在免费配额**之上**追加了「公测限免配额」
（构建 160 → 1600 核时、开发 1600 → 16000 核时），并明确标注「**仅公测期间限时提供**」。
本方案的核算是**只用基线 160 核时**（§8 月耗 ≈ 4.4 核时），**不依赖那份额外加量** ——
所以即便公测加量将来收回，对本方案零影响。

### 5.2 时间线（"上市多久"的正确问法）

**CNB 不是一家公司，没有"上市"**。它是**腾讯云的产品**（主体：腾讯云计算（北京）有限责任公司），
分社区版（cnb.cool，SaaS）与企业版（部署在客户 VPC 内，按注册账号数 × 订阅周期收费）。

| 时间 | 事件 |
| :--- | :--- |
| 2024-11 | 社区版（cnb.cool）**开放公测**，开放注册组织，另加公测限免配额 |
| 2025-02-26 | 上线官网，社区版正式公测 |
| 2025-04-27 | 发布社区版快速入门文档 |
| 2026-08-13 | 计费文档仍在更新（说明产品仍在活跃迭代） |

即**上线至今约 2 年**。（腾讯本身 2004-06-16 于香港联交所上市。）

### 5.3 腾讯为什么愿意免费：四条动机

1. **给 CODING 退市收尾**。腾讯云已发《【CODING DevOps】系列产品退市公告》：
   标准版 2025-09-01 下线；高级版/旗舰版 2025-09-30 停售、2026-03-30 停止续订、**2028-09-30 完全停服**。
   官方给免费用户的出路原话是「切换到新一代产品云原生构建，产品能力更强、**提供更大免费额度**」——
   **免费额度就是迁移诱饵**。
2. **抢 GitHub 的窗口期**。官方宣传文章标题即《GitHub 网页版国内访问受阻，CNB 强势救场攻略来袭》，
   并内置 GitHub / DockerHub 的**腾讯云内网加速**（不额外收流量费）。
3. **做上游漏斗**。CNB 与 TKE（容器服务）/ CVM / COS 无缝衔接，构建产物可直推制品库或云环境；
   免费是入口，**变现靠超额按量（0.125 元/核时）+ 上层云资源 + 企业版授权**。
4. **微信生态锁定**。微信扫码登录注册、PR/Issue 通知推到微信、项目可分享到群聊。

### 5.4 由此得出的风险判断

- 计费文档自带免责："部分产品、服务的内容可能不时有所调整" → 免费口径**未来可能变**。
- 但**这个风险对所有免费 CI 一样成立**（Gitee Go 同为 1000 核分/月 + 月末清零）。
- CNB 的差别在于**有完整商业闭环**（免费额度 + 超额计费 + 企业版授权），比纯活动型免费更可持续；
  且**额度用尽的降级行为是可预期的**（能力受限/只读），不会突然删数据。
- 本方案月耗仅约 2.75% 的基线额度，**在免费层内有巨大缓冲**。

## 6. 主方案：CNB

### 6.1 代码怎么进 CNB

- 在 CNB 建仓库，从 GitHub 导入 `SunChuquin/Kline`（自带迁移工具 `cnb-init-from`）；以后本地加 `cnb` remote 双推。
- 另建**一个密钥仓库**（CNB 仓库创建时可选中「密钥仓库（仅允许页面查看和修改，适用于云原生构建加载密钥）」），
  里面只放一个 `envs.yml`（`GH_PUSH_TOKEN=<fine-grained PAT>`），主仓库用 `imports` 引它。
- 不推荐只放 `src/` 最小集 —— 分叉两份代码会漂移。

### 6.2 流水线骨架（`.cnb.yml`）

官方语法层级已核实：`触发分支 → 触发事件 → Pipeline → Stage → Job`，Job 用 `script` 执行。
定时与镜像两处键名**也已核实**（出处见 §15）：定时任务的事件名就是把表达式写进键里的
`"crontab: <表达式>"`；镜像在 Pipeline 级写 `docker.image`、在 Job 级直接写 `image`。

```yaml
# .cnb.yml
imports:
  - https://cnb.cool/<org>/kline-secrets/-/blob/main/envs.yml   # 注入 GH_PUSH_TOKEN（密钥仓库）

main:                            # 触发分支（定时任务不支持 glob，必须写明确分支名）
  "crontab: 0 18 * * 1-5":       # 事件名 = "crontab: <POSIX 5 段表达式>"
    - name: nightly-publish      # 数组元素即一条 Pipeline
      stages:
        - name: publish
          jobs:
            - name: build-and-publish
              image: python:3.12     # Job 级镜像写法（自带官方示例）
              script: bash src/publish_buckets.sh

  push:                          # 生成端或清单变更时顺带跑一次
    - name: on-push
      ifModify:                  # Pipeline 级：仅下列文件变更时才执行
        - src/live_db_builder.py
        - src/data/universe.txt
        - src/publish_buckets.sh
      stages:
        - name: publish
          jobs:
            - name: build-and-publish
              image: python:3.12
              script: bash src/publish_buckets.sh
```

**两处键名的确切规则（2026-10-01 核实）：**

| | 结论 | 出处 |
| :--- | :--- | :--- |
| 定时任务 | 事件名 = **`"crontab: 0 18 * * 1-5"`**（把表达式写进键名），**不是** `crontab:` 下挂 `cron:` 子键。表达式为**标准 POSIX 5 段**（不像 Gitee Go 是 6 段 Quartz） | [CNB 定时任务](https://docs.cnb.cool/zh/build/crontab.html) |
| 时区 | **系统时区 `Asia/Shanghai`** → `0 18 * * 1-5` 就是北京时间 18:00，**无需换算** | 同上 |
| 其他限制 | 最小调度间隔 **5 分钟**；分支**不支持 glob**，必须单一明确分支名；执行身份 = 最后修改该配置的用户 | 同上 |
| Pipeline 级镜像 | `docker.image`（`docker` 是 Object，子键 `image` / `build` / `devcontainer` / `volumes`）；`image` 可写字符串（等同 `image.name`）或对象（`name` / `dockerUser` / `dockerPassword`） | [CNB 语法](https://docs.cnb.cool/zh/grammar/pipeline.html) |
| Job 级镜像 | 直接写 `image: python:3.12`（官方示例同款写法：`- name: Sync to GitHub` + `image: tencentcom/git-sync`） | 同上 |
| 两者差异 | Job 级指定 `image` 时该 Job 在**独立容器**中执行；不指定则在流水线容器内执行 | 同上 |

> 本骨架用 Job 级 `image`（更贴近官方插件示例）；若想整条 Pipeline 统一环境，
> 换成 Pipeline 级 `docker: {image: python:3.12}` 即可，二选一，不必都写。

### 6.3 发布段（`src/publish_buckets.sh`，CNB / Gitee Go 两条流水线**共用同一份**）

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

# ④ 无变化则跳过发布（非交易日 / 未开盘时正常走到这里）
[ "$(cat dist/.changed 2>/dev/null || echo 0)" = "1" ] || { echo '无变化，跳过发布'; exit 0; }
```

发布回 GitHub 有两条路，**优先 ①**：

| | 做法 | 说明 |
| :--- | :--- | :--- |
| **① git-sync 插件（推荐）** | 官方 `git-sync`（`image: tencentcom/git-sync`，settings：`target_url` / `auth_type` / `username` / `password` / `force: true`）把 `dist/` 以**孤儿提交**强推 GitHub `data` 分支 | 不用自己写 git 逻辑，官方维护 |
| ② 手写 git（兜底） | 在 `/tmp/pub` 里 clone → `git checkout --orphan` → `git rm -rf --cached .` → `git add -f live` → 强推 `HEAD:data` | 与现有 GitHub Actions 版同款逻辑 |

> 关键点：**在隔离目录（`/tmp/pub`）里做孤儿提交**，不要在 CI 工作区里动 git 状态。

## 7. 备选方案：Gitee Go

### 7.1 能力核对（已核实官方文档）

| 需要的能力 | Gitee Go 现状 | 来源 |
| :--- | :--- | :--- |
| 定时触发 | 支持，`triggers.schedule[].cron` | [触发事件](https://help.gitee.com/gitee-go/pipeline/trigger) |
| 单 cron 限制 | 文档原话：「目前仅支持填写一个定时表达式，暂时还未开放多个」→ **18:00 单次够用，不再是障碍** | 同上 |
| cron 格式 | 6 段 Quartz 风格 `M H D m d y`；**天与星期不能同时为 `*`**，用 `?` 占位；时区疑似非北京时间 | 同上 |
| 跑 Python | 插件 `build@python`，Python 2.7 / 3.6~3.9，基础镜像 CentOS 8.3（**已 EOL**） | [云端编译插件](https://help.gitee.com/gitee-go/plugin/ci-build) |
| 跑任意 shell | `build@python` 的 `commands` 在**代码库根目录**执行 | 同上 |
| 配置文件落点 | 仓库 `.workflow/<name>.yml` | [官方示例仓库](https://gitee.com/gitee-go/gitee-go-python-example) |
| 并发保护 | `strategy.blocking: true`（上一次未结束则排队） | [高级设置](https://help.gitee.com/gitee-go/pipeline/advantage-options) |
| 变量 | `variables`，**明文**，Key ≤32 / Value ≤256 字符 | [参数设置](https://help.gitee.com/gitee-go/pipeline/parameter) |
| 免费额度 | 每月 1000 核分（2C4G ≈ 500 分钟），**月末清零**；加时包 500 核分 15 元 | [计费规则](https://help.gitee.com/enterprise/pipeline/billing) |

**两个对我们有利的既有事实：**

1. [`live_db_builder.py`](../../src/live_db_builder.py) **零第三方依赖** —— 只用 `urllib` / `sqlite3` / `concurrent.futures`，
   没有 `requests` / `pandas` / `numpy`，也没有 3.10+ 语法 → **不需要 pip install**，不依赖 PyPI 网络。
2. 生成端本来就有 `--prev <上一版目录>` 与 `--check`，与「取 data 分支上一版做基线」天然对齐。

### 7.2 流水线骨架（`.workflow/sync-live-db.yml`）

```yaml
version: '1.0'
name: sync-live-db
displayName: 日分片增量库（境内生产）

triggers:
  schedule:
    # ⚠️ 只支持一个表达式；时区待实测（§9.1）。按「北京时间 18:00、周一至周五」写
    - cron: '0 18 ? * 2-6'
  push:
    branches:
      precise:
        - main

strategy:
  blocking: true      # 上一次未跑完则排队，避免两次并发互相覆盖 data 分支
  stepTimeout: 30

variables:
  GH_PUSH_TOKEN: ''   # ⚠️ 明文可见（§7.3）

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
          # ①②③④ 与 §6.3 的 src/publish_buckets.sh 完全一致（CNB / Gitee Go 共用一份）
          bash src/publish_buckets.sh
          # ⑤ 发布：走 §6.3 的手写 git 兜底路径（Gitee Go 无 git-sync 插件）
```

### 7.3 两条已消失的顾虑（相对上一稿）

| 上一稿的顾虑 | 现状 |
| :--- | :--- |
| 「四个时刻撞上单 cron」→ 要拆 4 条流水线 | **不存在了**：任务 A 只需 18:00 一个表达式（§2） |
| 「4000 只规模下 1000 核分不够」 | **不存在了**：3631 只 × 1 次/天 = 264 核分，只占 26%（§8） |

仍存在的顾虑只有两个：**`variables` 明文** 与 **CentOS 8.3 EOL / Python ≤3.9**。

### 7.4 凭证：GitHub PAT

- 产物要发回 GitHub `data` 分支 → 需要一个 **fine-grained PAT**（仅 `contents: write`，只授权 `SunChuquin/Kline`）。
- ⚠️ Gitee Go 的 `variables` 是**明文字段** → 最小权限 + 短有效期 + 定期轮换，且脚本里别 `echo` 它。
- **这正是主方案选 CNB 的理由之一**：CNB 走密钥仓库，配置文件里没有明文令牌。

## 8. 配额核算（3631 只 · 每工作日 18:00 一次）

单次端到端保守 **6 分钟**（§3.2）。计费公式：Gitee Go `消耗 = 分钟 × 核数`（核分）；CNB `1 核时 = 60 核分`。
交易日按 **22 天/月**，**1 次/天** → **22 次/月**。

| 平台 / 规格 | 单次消耗 | **月消耗（22 次）** | 免费额度 | 占用 | 结论 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Gitee Go · 2C4G | 12 核分 | **264 核分** | 1000 核分 | 26% | ✅ 宽裕 |
| Gitee Go · 1C2G | 6 核分 | 132 核分 | 1000 核分 | 13% | ✅ 更宽裕 |
| **CNB · 2 核** | 0.2 核时 | **4.4 核时** | 160 核时 | **2.75%** | ✅ 极宽裕 |
| CNB · 4 核 | 0.4 核时 | 8.8 核时 | 160 核时 | 5.5% | ✅ 极宽裕 |

**重要修正**：上一稿按「4000 只 × 4 时刻/天」算出 Gitee Go 月耗 1056 核分**超支**，
据此把它降为备选。按你更正后的口径（3631 只 × 1 次/天），Gitee Go 只用 26%，**超支论据不成立**。

**那主方案为什么还是 CNB？** 理由从"额度"换成下面三条（额度已不是区分项）：

1. **环境可控**：CNB 可用任意 Docker 镜像（`python:3.12`），绕开 Gitee Go 的 CentOS 8.3（已 EOL，
   `yum` 源可能下线）与 Python ≤3.9 两个坑。
2. **密钥保密**：CNB 密钥仓库 vs Gitee Go 明文 `variables`。
3. **长期确定性**：CNB 是腾讯云 CODING 的继任产品，有明确商业闭环（§5.3）；Gitee Go 有单 cron 等历史限制。

> 生成端以**网络等待**为主（34 批 HTTP + 全局限速），CPU 不是瓶颈；
> 选规格时优先保内存（sqlite 落盘 + 30 片比对），`1C2G`~`2C4G` 都够。

## 9. 实施时必须逐条实测/确认的项（**§7.2 的 Gitee Go YAML 不要照抄**；§6.2 的 CNB 语法已核实）

1. **cron 时区（Gitee Go）**：官方文档写「根据国外时间来，周日是 1」，疑似不是北京时间。
   先用一个 5 分钟后触发的 cron 验证，看流水线记录的实际触发时刻，再算偏移量。
2. **境内 CI → github.com 的 git push 可达性**：这是本方案**最大的不确定点**。
   每次孤儿提交要推 **≈ 18 MB**（30 片）。实测一次计时；若太慢或失败，走 §10 备选。
3. ~~CNB 的两处语法~~ —— **已在官方文档核实，无需再试**（§6.2 表）：
   ① 定时任务的事件名是 `"crontab: <POSIX 5 段表达式>"`，时区为 `Asia/Shanghai`，
   最小间隔 5 分钟，分支不支持 glob；
   ② 镜像 Pipeline 级用 `docker.image`、Job 级直接用 `image`，两种写法官方都给了示例。
   **仅剩一条需在平台上实跑确认**：表达式写 `0 18 * * 1-5` 后，流水线记录里的实际触发时刻
   是否就是北京时间 18:00（做法同第 1 条）。
4. **CNB 免费额度的口径**：确认「云原生构建-160 核时」是自然月累积、定时任务计入同一池、跨月任务计入结束月。
5. **Gitee Go 基础镜像是否预装 `git`**：CentOS 8.3 已 EOL，`yum install git` 可能因源下线失败（需换 vault 源）。
   若不预装且装不上，改用 `build@nodejs`（文档称其镜像含 git、wget、Python3）。
6. **`build@python` 里 `python3` 的实际版本**（模板默认 3.9，实测确认）。
7. **工作区路径**：CNB / Gitee Go 的工作区绝对路径，以及能否在 `/tmp` 里 clone / push。
8. **若采纳 §3.3 的"CNB 当设备侧下载源"**：① 仓库文件的**匿名直链格式**；
   ② 公网的**并发 / 带宽 / 限速**（官方无公开数字）；③ 实测一片 600 KiB 的下载耗时。

## 10. 风险与备选

| 风险 | 备选 |
| :--- | :--- |
| 境内 CI 推 GitHub 不稳（§9.2） | 产物先发到 **CNB/Gitee 自己的 `data` 分支**，再由本机脚本（网络好）同步到 GitHub；或顺势把 App 的**备用源**指向境内（`TdxSyncConfig` 支持备用源可配置，App 主源仍不动） |
| 免费额度口径未来调整 | CNB 占用 2.75%、Gitee Go 占用 26%，都有缓冲；且 CNB 额度用尽后是**能力受限**而非删数据 |
| 明文 token（仅 Gitee Go） | 主方案走 CNB 密钥仓库；若退回 Gitee Go 则最小权限 + 短有效期 + 定期轮换 |
| 那 299 只扩展行情指数覆盖不到 | 由电脑侧 `build_live_buckets_pc.py` 出片补（本来就存在，与 CI 选择无关） |
| 非交易日被 cron 触发 | 已有防护：交易日取行情源时间戳而非本机日期，且 `dist/.changed = 0` 时跳过发布 |

## 11. 需要你做的事（实施前）

- [ ] **拍板平台**：CNB（推荐）还是 Gitee Go
- [ ] 注册并实名：CNB 需**微信扫码 + 实名认证**（未实名禁止写行为）；Gitee 你已有账号
- [ ] 建仓库：从 GitHub 导入 `SunChuquin/Kline`，仓库名与 GitHub 同名（减少脚本路径改动）
- [ ] 建密钥仓库（仅走 CNB 时需要），生成 **fine-grained GitHub PAT** 放进去
      （仅 `contents: write` + 仅 `SunChuquin/Kline` + 短有效期）
- [ ] **确认调度时刻**：暂定**每工作日 18:00**（收盘后完整日K）；是否要留 push 触发
- [ ] 开通流水线（CNB 免费额度 / Gitee Go 免费版）

## 12. 实施步骤（每阶段都能独立验证）

1. **阶段 1 · 连通性验证（不写业务）**：一条最小流水线，只做「cron 触发 → 打印北京时间 → 确认时区偏移」。
   验收：能算出正确的 cron 表达式（CNB 与 Gitee Go 各验一次）。
2. **阶段 2 · 生成验证**：跑 `live_db_builder.py` 生成分片 + `--check` 自检通过，**先不发布**。
   验收：日志里覆盖率达标（约 3303/3611）、`dist/.changed` 正确、耗时与 §3.2 相符。
3. **阶段 3 · 发布验证**：加发布步骤，推 GitHub `data` 分支。
   验收：GitHub `data` 分支有新孤儿提交（≈18 MB）；App 手动「立即更新」能拉到。
4. **阶段 4 · 定时打通**：落到 18:00 单次调度，连续观察 1~2 个交易日，核对实际扣减的核分/核时。

## 13. 顺带要拍板的遗留项

[[20260922-境外Actions访问国内行情源被502拒绝]] 里记着一条**未决遗留**：GitHub 上的
`.github/workflows/sync-live-db.yml` **仍在按 cron 跑并继续失败**（Actions 页面一直有失败记录）。

本方案落地后，应该：**删掉它**，或**改成仅 `workflow_dispatch` 手动触发**。这是本方案的收尾动作，不是前置。

## 14. 相关文档

- [[20260922-境外Actions访问国内行情源被502拒绝]] — 本方案要解的根因
- [[行情同步架构总览]] — 路径矩阵（走通 / 走不通 / 已废弃）
- [[清单标的盘中自动更新]] — 任务 B：设备侧直连东财（与本方案不互斥，见 §2）
- [Kline-增量行情库自动同步.md](../Kline-增量行情库自动同步.md) — 通道 C 的历史说明（正文已过时）

## 15. 外部依据（2026-10-01 核实）

- [CNB 社区版计费说明](https://docs.cnb.cool/zh/saas/pricing.html) — 计费项全表
  （**无"流量 / 带宽"项** → §3.3 ② 的依据）、免费额度、月底清零规则
- [腾讯云 · 社区版计费说明](https://cloud.tencent.com/document/product/1785/116265) — 免费额度与超额单价
- [腾讯云 · 开通使用（社区版/企业版）](https://cloud.tencent.com/document/product/1785/116262) — cnb.cool 微信扫码注册
- [腾讯云 · 云原生构建动态与公告](https://main.qcloudimg.com/raw/document/product/pdf/1785_116257_cn.pdf) — 2024-11 公测限免配额「仅公测期间限时提供」
- [腾讯云 · 【CODING DevOps】系列产品退市公告](https://cloud.tencent.com/announce/detail/2057) — 迁移到 CNB
- [CNB 语法文档](https://docs.cnb.cool/zh/grammar/pipeline.html) — `.cnb.yml` 层级结构、
  Pipeline / Stage / Job 三级的镜像键名（`docker.image`、Stage.image、Job.image）
- [CNB 触发规则](https://docs.cnb.cool/zh/build/trigger-rule.html) — 事件类型表（含「定时任务事件」）
- [CNB 定时任务](https://docs.cnb.cool/zh/build/crontab.html) — 键名 `"crontab: <表达式>"`、
  时区 `Asia/Shanghai`、最小间隔 5 分钟、分支不支持 glob（**本方案两处待实测项之一据此关闭**）
- [Gitee Go 触发事件](https://help.gitee.com/gitee-go/pipeline/trigger) / [云端编译插件](https://help.gitee.com/gitee-go/plugin/ci-build) / [计费规则](https://help.gitee.com/enterprise/pipeline/billing)