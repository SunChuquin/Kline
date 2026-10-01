# 云端分片生产改走**境内 CI** 方案（CNB 主 / Gitee Go 备）

> 状态：**实施中**（2026-09-30 首稿；2026-10-01 二稿：纳入 CNB 背景调研与 4000 只规模；
> 2026-10-01 三稿：规模回落到标的库实测口径、调度收敛为**每工作日 18:00 一次**；
> 2026-10-01 四稿：核实 CNB 的 `crontab` 键名与镜像声明键名，§6.2 骨架已去掉 ⚠️；
> 2026-10-01 五稿：**云端只发日线表**（周/月线改由 App 本地聚合，见 §3、§3.3）；
> 2026-10-01 六稿：**平台定稿 CNB + 仓库形态定稿**（独立公开仓库 `sunchuquin/kline-data`，
> 作为 Kline2 的子模块 `cloud/`），**产物推 CNB 自己的 `data` 分支**（GitHub 退出这条链路、
> 无需密钥仓库与外部 PAT），并**实测结清匿名直链格式与吞吐**；阶段 0 已完成；
> 2026-10-01 七稿：**云端取数改腾讯为主源、东财仅兜底**（东财 push2 接口实测间歇性拒连，
> 见 §9.9），**阶段 1~3 全部跑通并验收**：CNB 流水线 `status=success`、`data` 分支已产出，
> 匿名直链拉到 `manifest.json` 与 `bucket_20726.db` 且 sha256 一致；
> 2026-10-01 八稿：**东财从快照链摘除，改「腾讯 → 新浪 → 同花顺」有序源链**（§9.9 补实测）；
> **通达信官方整包方案经用户否决并撤销** —— 525 MB 体积吃 CNB 免费额度、且该包不复权）
>
> 范围：**只解决生产侧** —— 工作日收盘后自动抓批量行情快照（源链 腾讯 → 新浪 → 同花顺，§9.9）、
> 产出**只含日线表**的日分片增量库。
> 设备侧下载源**要改**：主源改为
> `https://cnb.cool/sunchuquin/kline-data/-/git/raw/data`（实测 1 MB/s，比 GitHub raw 快约 16 倍）。
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
| 数据源 | 公开行情接口，源链 **腾讯 → 新浪 → 同花顺**（§9.9） | 东财公开接口（设备国内网络直连） |
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
> 生成端现状是 `PERIODS = ("daily", "weekly", "monthly")`（`cloud/scripts/live_db_builder.py`，原在 `src/` 下），
> 云端调用时需改成只发 `daily`（季/年本来就不在分片里）。

### 3.2 单次运行成本

| 环节 | 耗时 |
| :--- | :--- |
| 取 `data` 分支上一版（≈18 MB） | CNB 同平台匿名 clone，秒级（已实测可行，§3.3 ③） |
| 生成（34 批） | ≈ 184 s ≈ **3.1 分钟** |
| `--check` 自检 | 秒级 |
| 发布（孤儿提交 ≈18 MB 强推**本仓库** `data`） | 境内同平台，秒级~十几秒 |
| **单次端到端（保守）** | **≈ 6 分钟**（原"推 GitHub"的不确定项已消除，估算不变） |

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

**③ 单日（600 KiB）下载耗时（CNB 已实测）**

| 源 | 实测值 | 换算 600 KiB |
| :--- | :--- | :--- |
| 当前主源 `raw.githubusercontent.com` | 108 KiB / **1.79 s** ≈ 62 KB/s | ≈ **10 s** |
| 当前备源 jsDelivr | 108 KiB / **3.83 s** ≈ 29 KB/s | ≈ **21 s** |
| **CNB（`/-/git/raw/`，2026-10-01 实测）** | 120 KB / 0.12 s、112 KB / 0.10 s ≈ **1 MB/s**；小文件延迟 0.07–0.2 s | ≈ **0.6 s** |

**CNB 匿名直链格式（实测确认，非 GitLab 形态）：**

```
https://cnb.cool/<org>/<repo>/-/git/raw/<branch>/<path>
实测：https://cnb.cool/sunchuquin/kline-data/-/git/raw/main/README.md
     → 200  text/plain  21 B  0.074 s  （不带任何凭据）
```

| 附带结论 | 实测值 |
| :--- | :--- |
| 匿名可下载 | ✅ 200 且内容逐字节一致；**带 `Authorization` 反而 400 `Invalid argument`** → 纯公开路由 |
| 单文件上限 | `raw_file_limit_in_byte = 104857600`（**100 MiB**）；600 KiB 分片远低于它 |
| 首次全量（30 片 ≈18 MB） | ≈ **18 s** |
| 每日增量（1 片） | ≈ **0.6 s** |

结论：**同一片数据，CNB 比 GitHub raw 快约 16 倍**；首次装机的 30 片全量（≈18 MB）从
GitHub raw 的几分钟降到**十几秒**。现有下载器
（[TdxSyncConfig.swift](../../Kline/Infrastructure/TdxSyncConfig.swift#L39-L42)）本来就是
**可配置的多源列表 + 按序回退**，加一个 CNB 源属**配置级**改动（manifest + sha256 契约、校验与合并逻辑都不用动）：
把源从 `raw.githubusercontent.com/<o>/<r>/data` 换成
`cnb.cool/sunchuquin/kline-data/-/git/raw/data` 即可，**拼路径规则完全对应**。

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

### 6.1 仓库形态（2026-10-01 定稿）

**已落地**：CNB 独立仓库 [`cnb.cool/sunchuquin/kline-data`](https://cnb.cool/sunchuquin/kline-data)，
**公开**、归属组织 `sunchuquin`，作为 Kline2 的 **git 子模块 `cloud/`** 挂载。

```
Kline2/                     # 父仓库（GitHub SunChuquin/Kline）
  Kline/                    # iOS 源码
  cloud/                    # ← submodule → cnb.cool/sunchuquin/kline-data
    .cnb.yml                #    定时 + push 触发
    scripts/live_db_builder.py
    scripts/publish_buckets.sh
    data/universe.txt
  src/                      # 只留电脑侧工具（tdx_parser.py / tdx_gui.py …）
```

| 与原计划的差异 | 原因 |
| :--- | :--- |
| ❌ 不再"从 GitHub 导入整个 Kline" | 生成端与 iOS 工程解耦；CNB 仓库只装生成脚本 + 清单，**与 Kline 无任何关系** |
| ❌ 不再需要**密钥仓库** | 产物推的是 **CNB 自己的 `data` 分支**，用平台内置凭据，不需要外部 PAT |
| ❌ 不再需要 **GitHub fine-grained PAT** | 同上。GitHub 只保留"构建 ipa"一条职责 |
| ✅ 用**子模块**而不是"两份代码手动同步" | 在一个工作区里就能改生成端，且不会漂移 |

> **子模块两个坑**：① `git submodule update --init` 后处于 **detached HEAD**，进目录先 `git checkout main`
> 再改，否则提交的是游离 commit；② 推代码是**两段** —— 子模块目录 push 到 cnb.cool，
> Kline2 根再 push 到 GitHub（带上新的 submodule hash 指针），少推一段就会出现"CI 跑的是旧代码"。

**推送通道（实测）**：SSH **三个入口全不通**（`cnb.cool:22` No route to host、`cnb.cool:443` Connection closed、
`ssh.cnb.cool:22` No route to host）→ 本地推送只能走 **HTTPS + 访问令牌**
（`git push https://cnb:<token>@cnb.cool/sunchuquin/kline-data.git main`，已实测成功）。
CNB 流水线内部推自己仓库用平台内置凭据，不需要这个令牌。

### 6.2 流水线骨架（`.cnb.yml`）

官方语法层级已核实：`触发分支 → 触发事件 → Pipeline → Stage → Job`，Job 用 `script` 执行。
定时与镜像两处键名**也已核实**（出处见 §15）：定时任务的事件名就是把表达式写进键里的
`"crontab: <表达式>"`；镜像在 Pipeline 级写 `docker.image`、在 Job 级直接写 `image`。

```yaml
# .cnb.yml —— 放在 CNB 仓库根（= 子模块 cloud/ 的根，**不是** Kline2 根目录）
main:                            # 触发分支（定时任务不支持 glob，必须写明确分支名）
  "crontab: 0 18 * * 1-5":       # 事件名 = "crontab: <POSIX 5 段表达式>"；时区 Asia/Shanghai
    - name: nightly-publish      # 数组元素即一条 Pipeline
      stages:
        - name: publish
          jobs:
            - name: build-and-publish
              image: python:3.12     # Job 级镜像写法（自带官方示例）
              script: bash scripts/publish_buckets.sh

  push:                          # 生成端或清单变更时顺带跑一次
    - name: on-push
      ifModify:                  # Pipeline 级：仅下列文件变更时才执行
        - scripts/live_db_builder.py
        - data/universe.txt
        - scripts/publish_buckets.sh
      stages:
        - name: publish
          jobs:
            - name: build-and-publish
              image: python:3.12
              script: bash scripts/publish_buckets.sh
```

> **不再有 `imports:`** —— 产物推的是本仓库的 `data` 分支，用平台内置凭据，无需密钥仓库。
> **`.cnb.yml` 必须在 CNB 仓库根**：放在 Kline2 根目录**不生效**（CNB 只读自己仓库的配置）。

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

### 6.3 发布段（`scripts/publish_buckets.sh`）

**产物推本仓库自己的 `data` 分支**（不再推 GitHub），五步：

```bash
set -euo pipefail

# ① 取 data 分支上一版，作为「保留 30 片」的基线（匿名 clone 本仓库即可，已实测可行）
git clone --depth=1 --branch data "$REPO_URL" /tmp/prev-src
mkdir -p prev && cp -r /tmp/prev-src/live prev/live

# ② 生成当天那一片（真实行情接口，境内网络）
python3 scripts/live_db_builder.py \
  --universe data/universe.txt --out dist --prev prev/live

# ③ 自检：manifest 必须与所有分片逐项一致
python3 scripts/live_db_builder.py --check --out dist

# ④ 无变化则跳过发布（非交易日 / 未开盘时正常走到这里）
[ "$(cat dist/.changed 2>/dev/null || echo 0)" = "1" ] || { echo '无变化，跳过发布'; exit 0; }

# ⑤ 孤儿提交强推 data 分支（在隔离目录里做，不动 CI 工作区的 git 状态）
```

| | 做法 | 说明 |
| :--- | :--- | :--- |
| **① 手写 git（本方案采用）** | 在 `/tmp/pub` 里 `git init` → `git checkout --orphan data` → `git add -f live` → `git push -f origin HEAD:data` | 目标是**本仓库**，无需外部凭据；与现有 GitHub Actions 版同款逻辑 |
| ② git-sync 插件 | 官方 `git-sync`（`image: tencentcom/git-sync`，`target_url` / `auth_type` / `username` / `password` / `force: true`） | 推外部仓库时更省事；推本仓库不需要 |

> **关键点 ①**：在隔离目录（`/tmp/pub`）里做孤儿提交，不要在 CI 工作区里动 git 状态。
> **关键点 ②**：孤儿提交**不需要**改增量提交 —— Git 按内容寻址，29 片内容和昨天一字不差
> → 同一个对象只存一份，每天真实存储增量 ≈ **600 KiB**（只有新片是新的）。
> 且孤儿提交让旧提交成为不可达对象 → **clone 恒定 18 MB**，不随时间增长（增量提交反而会让 clone 逐年变大）。

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

> **平台已拍板 CNB**（2026-10-01），§7 的 Gitee Go 降为**未启用备选** →
> 第 1 / 5 / 6 条**仅在将来真的启用备选时才需要**，当前不必实测。

1. **cron 时区（Gitee Go）**：官方文档写「根据国外时间来，周日是 1」，疑似不是北京时间。
   先用一个 5 分钟后触发的 cron 验证，看流水线记录的实际触发时刻，再算偏移量。
2. ~~境内 CI → github.com 的 git push 可达性~~ —— **已作废**：方案定稿为产物推
   **CNB 自己的 `data` 分支**（§6.1），GitHub 完全退出这条链路。
   原先的"最大不确定点"随之消失。
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
8. ~~CNB 当设备侧下载源~~ —— **已实测确认**（2026-10-01）：
   ① 匿名直链格式 = **`https://cnb.cool/<org>/<repo>/-/git/raw/<branch>/<path>`**
      （不是 GitLab 形态的 `/-/raw/`，从页面 JS 的 `"/{repo}/-/git/raw/{ref_with_path}"` 挖出）；
   ② **匿名可下载** —— 200 `text/plain`，内容逐字节一致；带 `Authorization` 反而 400
      → 确为纯公开路由；单文件上限 `raw_file_limit_in_byte = 104857600`（100 MiB）；
   ③ 吞吐实测 **≈ 1 MB/s**（120 KB/0.12 s）→ 600 KiB 单片 ≈ **0.6 s**，30 片全量 ≈ 18 s。
   ④ 公网**并发 / 带宽上限**官方仍无公开数字（实测未触及限速，但不构成承诺）。
   详见 §3.3 ③。
9. **~~行情源可达性~~ —— 已实测，并据此换了主源**（2026-10-01）：
   东财 `push2.eastmoney.com` 的 `ulist.np/get` 在 **CNB 构建出口与本机出口都呈间歇性拒连**
   （`RemoteDisconnected` / `SSL unexpected eof`），不是 CNB 专有、也不是 DNS/UA/Referer 问题：
   - CNB 构建节点（出口 `159.75.12.57`）诊断：34 批全灭、命中 0/3312、耗时 287 s；
     退化成 **1 只**的小请求同样 000；对照出口 baidu / github / cnb 全通。
   - 本机复现：同一脚本 34 批 **0 命中 / 287.6 s**；十分钟前同样 6 只的小请求却是 200
     → 典型的**时间维度间歇封锁**，与批量大小无关。
   - 同一时刻腾讯 `qt.gtimg.cn`：**3312 只全命中 / 8.3 s**（100 只一批，GBK 文本，0.2 s/批）。
   结论：**腾讯设为主源**；两源口径已逐字段对拍：6 只样本（浦发/工行/平安/万科/茅台/宁德）的
   开/高/低/收/量/额 **全部相等**，3312 只全量结构自检通过（唯 182 条 `额÷量÷点位` 比值异常
   全是**指数**，指数本就如此，非数据错误）。交易日判定改用腾讯返回的 `YYYYMMDDHHMMSS`
   （北京时间），与原 f124 同口径。

   **八稿补充（2026-10-01）：东财从快照链摘除，改「腾讯 → 新浪 → 同花顺」有序源链**

   （b）**新源链双出口实测**（本机出口 + CNB 构建节点出口，同日）：

   | 源 | 端点 | 批量能力 | 本机 | CNB 出口 |
   | :--- | :--- | :--- | :--- | :--- |
   | 腾讯 | `qt.gtimg.cn/q=` | 100/次 | 3312 只 **8.3 s 全命中** | 200 |
   | 新浪 | `hq.sinajs.cn/list=` | 批量 | 3312 只 6.0 s 全命中 | **403（固定被拒）** |
   | 同花顺 | `d.10jqka.com.cn/v6/line/...` | 逐只（并发 8） | 0.14~0.24 s/只 | 200 |
   | 百度股市通 | `finance.pae.baidu.com` | — | 403 `hit risk` | 200 |
   | 通达信官方整包 | `data.tdx.com.cn/vipdoc/hsjday.zip` | 525 MB 整包 | 200 / 31.8 MB/s | **方案已否决，未采** |

   即云端实际生效的是「**腾讯 + 同花顺**」；新浪在 CNB 出口 403 属**预期降级**（本机/设备侧正常），
   这正是源链存在的意义。东财的 kline 接口只在 `--backfill-days` 回补里用，与快照是两条独立路径。

   （c）**成交量口径**（三源对拍，统一到腾讯口径）：

   - 腾讯 `[6]`：沪深主板/创业板 = **手**，且用**四舍五入**而非截断
     （300750 新浪 29699471/100 = 296994.71 → 腾讯 **296995**；600519 3833098/100 = 38330.98
     → **38331**；600000 147484820/100 = 1474848.20 → 1474848）；
     ⚠ **科创板 688xxx 直接以"股"报量**（688318 腾讯 = 新浪 = 同花顺 = 3918568）。
   - 新浪：股票与**深市**指数 = 股（÷100），**沪市**指数 = 手（上交所口径，不除）
     （sh000001 新浪 = 腾讯 = 414560247；sz399001 新浪 ≈ 100 × 腾讯）。
   - 同花顺：**一律股**（÷100）；且指数是另一套代码（上证指数 `hs_1A0001`，而 `hs_000009`
     会被解析成深市"中国宝安"）→ **指数一律不走向同花顺**，由腾讯/新浪负责。
   - 因此换算规则收敛成一个函数 `_vol_keep_raw(secid, index_secids)`：**沪市指数** 与
     **科创板 688xxx** 保持原值，其余按"股→手"÷100 四舍五入。

   （d）**通达信方案被否决并撤销**：官方 `hsjday.zip` 是 525 MB / 12449 只 `.day` 整包，
   每天 15:58 更新，实测与本机腾讯逐字段一致 —— 但（1）体积会吃掉 CNB 免费额度，
   （2）该包**不复权**。故不采用，**代码内无任何 TDX 路径**。

   （e）**本机端到端复跑核对**：覆盖率 `3312/3611 = 0.9172`、单片 `593920 B`、`--check` 全通过；
   且 `bkt_daily` 3312 行与线上已发布分片**逐行数值全等**（`bkt_daily`/`bkt_meta` 零差异，
   仅 SQLite 头部 change counter 使字节 sha 必然不同）。另注：`universe.txt` 当前
   **不含科创板 688xxx / 创业板 300xxx**（SH 仅 600/601/603/605/000/999，SZ 仅 002/000/001/003/399），
   故 688 量纲分支当前不触发，属"清单将来纳入科创板时不被静默差 100 倍"的护栏。

## 10. 风险与备选

| 风险 | 备选 |
| :--- | :--- |
| ~~境内 CI 推 GitHub 不稳~~ | **风险已消除**：方案定稿为产物推 CNB 自己的 `data` 分支（§6.1），不再推 GitHub |
| 公开仓库 = 日线数据对所有人可见 | 数据源自腾讯/新浪/同花顺的公开行情，非私有数据；已与用户确认 |
| 东财行情接口间歇性拒连 | **已实测并消化**：东财从快照链摘除，改「腾讯 → 新浪 → 同花顺」有序源链（§9.9）。腾讯 3312 只 / 8.3 s 全命中 |
| 单一行情源将来不可用 | **已有三级有序源链**（腾讯 → 新浪 → 同花顺），逐级只补缺口；云端实际可用「腾讯 + 同花顺」两条独立链路 |
| CNB 明文令牌（本地推送用） | 仅用于**初始推送**，完成后**立即吊销重建**；不写入任何仓库文件。CI 内部用平台内置凭据 |
| 免费额度口径未来调整 | CNB 占用 2.75%、Gitee Go 占用 26%，都有缓冲；且 CNB 额度用尽后是**能力受限**而非删数据 |
| 明文 token（若退回 Gitee Go） | CNB 主方案不需要外部 PAT；退回 Gitee Go 才需最小权限 + 短有效期 + 定期轮换 |
| 那 299 只扩展行情指数覆盖不到 | 由电脑侧 `build_live_buckets_pc.py` 出片补（本来就存在，与 CI 选择无关） |
| 非交易日被 cron 触发 | 已有防护：交易日取行情源时间戳而非本机日期，且 `dist/.changed = 0` 时跳过发布 |

## 11. 需要你做的事（实施前）

- [x] ~~**拍板平台**~~ → **CNB**（2026-10-01）
- [x] ~~注册并实名~~ → 已完成
- [x] ~~建仓库 / 建密钥仓库 / 生成 GitHub PAT~~ → **三步全部作废**：
      改为建独立仓库 `sunchuquin/kline-data`（**公开**，已建），无需密钥仓库、无需外部 PAT
- [x] ~~确认调度时刻~~ → 暂定 `0 18 * * 1-5`（北京时间，无需换算）；push 触发保留
- [ ] **令牌提醒**：初始推送用的 CNB 访问令牌（明文出现在会话里）**用完立即吊销重建**
- [ ] 首次跑通后：确认 `cron` 实际触发时刻（§9.3）与 GitHub Action → CNB 推 ipa 的认证方式

## 12. 实施步骤（每阶段都能独立验证）

0. **阶段 0 · 仓库与通道（✅ 已完成 2026-10-01）**
   - 建仓库 `sunchuquin/kline-data`（公开）；`git push` over HTTPS 打通（SSH 三个入口全不通）
   - **匿名直链 + 吞吐实测**：`/-/git/raw/` 格式确认、1 MB/s、100 MiB 上限（§3.3 ③）
   - 验收：`curl` 匿名拉到占位文件，内容逐字节一致 ✅
1. **阶段 1 · 仓库内容落地（✅ 已完成 2026-10-01，commit `385def8`）**：写入 `.cnb.yml`、
   `scripts/publish_buckets.sh`、`scripts/live_db_builder.py`（`PERIODS` 改**只发日线**）、
   `data/universe.txt`、`.gitignore`；在 Kline2 挂子模块 `cloud/`。
   验收：匿名可读 `.cnb.yml` / `publish_buckets.sh` ✅；Kline2 `git submodule status` 正常 ✅。
2. **阶段 2 · 生成验证（✅ 已完成，本机 + CNB 各一次）**：
   本机 `--universe data/universe.txt --out /tmp/dist-test` → 3312/3312 命中 / 8.3 s、
   `trade_date=20260930`、覆盖率 **0.9172**、`bucket_20726.db = 593,920 B`、`.changed=1`；
   `--check` → **全部校验通过**；以 `--prev` 指向刚生成的版本空跑 → `.changed=0`（未变不重写）✅。
   注：实测单片 593,920 B 而非预估的 614,400 B，差异来自停牌/字段缺失，属正常。
3. **阶段 3 · 发布验证（✅ 已完成 2026-10-01）**：`POST /{repo}/-/build/start`
   （`event=api_trigger`）触发 → `sn = cnb-ed5-1k3rva2rl`，**`status=success`**，业务 stage 9.4 s；
   日志确认腾讯 3312/3312、自检通过、孤儿提交强推 `data` 分支成功。
   验收：匿名 `curl` 拉到 `live/manifest.json`（200 / 908 B / 0.149 s）与
   `live/bucket_20726.db`（200 / 593,920 B / 0.157 s），**下载件 sha256 与 manifest 声明逐字节一致** ✅。
4. **阶段 4 · 定时打通**：落到 `0 18 * * 1-5`，连续观察 1~2 个交易日。
   验收：流水线记录里的实际触发时刻就是北京时间 18:00；核对扣减的核时（预期 ≈0.2 核时/次）。

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