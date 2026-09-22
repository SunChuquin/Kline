# Kline 增量行情库自动同步（三通道）

> 目标：交易日自动在 **11:00 / 14:30 / 15:05**（北京时间）更新 Kline 内被监控标的的行情数据，
> 让委托 / 条件单 / 预警能基于接近当日的新价触发，从而把训练用的自动化逻辑用到实盘盯盘上。
>
> 规格来源：`.trae/specs/add-live-data-auto-sync/`（spec / tasks / checklist）。
> 实现日期：2026-09-22。
>
> 电脑侧脚本位置：`c:\Users\sunck\home\projects\ios\TrollRestore\`（与 `build_and_deploy.py`、`sandbox_cli.py` 同处，
> **在 Kline 仓库之外**，因此不随仓库提交）。下列命令均可在任意目录执行，路径按绝对路径给出。

## 目录

- [1. 一句话原理](#1-一句话原理)
- [2. 三通道怎么选](#2-三通道怎么选)
- [3. 通道 C：云端自动（无需电脑）](#3-通道-c云端自动无需电脑)
- [4. 通道 A：USB 一键直推](#4-通道 Ausb-一键直推)
- [5. 通道 B：局域网 WiFi 直推](#5-通道-b局域网-wifi-直推)
- [6. 改关注标的清单](#6-改关注标的清单)
- [7. 状态核对与故障排查](#7-状态核对与故障排查)
- [8. 硬边界](#8-硬边界)

---

## 1. 一句话原理

设备上**不动**原来那个 1GB+ 的整库 `Documents/tdx.db`（全市场历史，仍按老办法偶尔手动替换），
另外维护一个**增量库** `Documents/tdx_live.db`：只装"关注标的并集"的最近 30 根日/周/月/季/年线，约 100KB~1MB。

App 查询时按 **「同一 date 以增量库为准，其余由主库补齐」** 合并两个库，所以：

- 行情列表、自选、K线图、条件单/预警**上层代码零改动**就能看到新数据；
- 增量库文件一变，App **自动热刷新**（指纹变化 → 重载 → 广播数据版本），**不需要杀进程重启**。

实测结论（2026-09-22）：单根K线约 111 字节，17 只标的 × 30 根全量约 110KB；
`POST /sync/reload` 后设备侧立即变为 `available=true / 覆盖 17 只 / 最新 20260922`。

## 2. 三通道怎么选

| 通道 | 何时用 | 需要电脑开机 | 需要数据线 | 需要 App 前台 | 数据来源 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **C 云端自动** | 默认方案；人不在电脑前、用 iPhone/iPad 盯盘 | 不要 | 不要 | 要 | 公开行情接口（GitHub Actions 定时产出） |
| **A USB 一键** | 设备没外网、或用本地通达信数据兜底 | 要 | 要 | 要 | 本机通达信/本机生成 |
| **B 局域网直推** | 人在电脑前但不想插线 | 要（且与设备同 Wi-Fi） | 不要 | 要 | 同上 |

三者可并存，互不冲突：谁先写进去，App 都会热刷新。

## 3. 通道 C：云端自动（无需电脑）

**流水线**：`.github/workflows/sync-live-db.yml`

- 触发：`cron`（UTC `03:00` / `06:30` / `07:05` = 北京 11:00 / 14:30 / 15:05，周一至周五）；
  另外 `src/data/symbols.txt` / `src/live_db_builder.py` / 该 workflow 自身变更 push 时也会跑一次
  （改完关注标的不用等下一个定时点）；Actions 页面可手动 `Run workflow`。
- 产出：`tdx_live.db` + `tdx_live.manifest.json`，**强制覆盖式发布到 `data` 分支**（孤儿提交，仓库体积恒定）。
- 下载地址（匿名可访问）：
  - 主源：`https://raw.githubusercontent.com/SunChuquin/Kline/data/tdx_live.db`（实测 110KB / 1.8s）
  - 备源：`https://cdn.jsdelivr.net/gh/SunChuquin/Kline@data/tdx_live.db`（实测 3.8s）
  - manifest 同目录换文件名即可。
- 生成失败 / 自检不通过 → job 失败，**不覆盖**上一版产物。

**设备侧**（设置 → 本地更新 → 「数据同步」）：

1. 「启用自动更新」**默认已开启**（随时可关）；
2. 数据源地址默认就是上面两条（按顺序回退），可改成自建镜像；
3. 更新时刻默认 `11:00, 14:30, 15:05`，可编辑；
4. 到点后 App 自动：取 manifest → 版本/哈希与本地一致则**跳过下载** → 下载到临时文件 → **sha256 校验** → 原子替换 → 立即热刷新；
5. 也可点「立即更新」手动跑一次（同样受启用开关约束）。

> 语义提醒：**11:00 / 14:30 是盘中快照**（当日K线可能未完成），**15:05 是当日完整K线**。
> 面板上的「数据版本」会显示 `vN（YYYYMMDD）`，`YYYYMMDD` 是行情源给出的**真实交易日**，不是本机日期。

## 4. 通道 A：USB 一键直推

```powershell
# 一步到位：本机联网生成 → 经数据线推入设备 → 通知热刷新 → 回读设备状态
& "c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\python.exe" `
  "c:\Users\sunck\home\projects\ios\TrollRestore\push_live_usb.py" --build
```

- 前置：数据线已连接（首次需在设备上点「信任此电脑」）；**Kline 前台未锁屏**。
- 原理：`pymobiledevice3 usbmux forward 5051` → `PUT http://127.0.0.1:5051/sandbox/tdx_live.db`
  → `POST /sync/reload` → `GET /sync/status`。
- 也可推本机已有的文件：`--db <path> [--manifest <path>]`；只推不通知：`--no-reload`。
- 这条通道**不依赖设备外网**，是"全量/兜底"最可靠的一条。

## 5. 通道 B：局域网 WiFi 直推

```powershell
& "c:\Users\sunck\home\projects\ios\.venv-ios\Scripts\python.exe" `
  "c:\Users\sunck\home\projects\ios\TrollRestore\push_live_lan.py" --host 192.168.1.23 --build
```

- `--host` 填设备 IP：在设备「设置 → 本地更新 → 数据同步」的**「局域网地址」**行直接抄（形如 `http://192.168.1.23:5051`）。
- 前置：电脑与设备**同一 Wi-Fi**（不是访客网络）；Kline 前台未锁屏。
- 脚本会先探活再推，失败时按「IP 是否变了 / 是否同一 Wi-Fi / App 是否在前台」逐项提示。

## 6. 改关注标的清单

清单是仓库内唯一来源：`src/data/symbols.txt`

```
600519            # 贵州茅台（纯代码行；# 开头整行注释）
000001
999999            # 通达信口径的上证指数
600519 secid=1.600519   # 也支持显式指定行情源 secid
```

改完 `git push` → 流水线的 push 触发会立刻重新生成并发布（也可等下一个定时点）。
清单放的是**代码**，不放备注以外的东西（仓库是 Public）。

## 7. 状态核对与故障排查

**设备侧状态**（Kline 前台时）：

```powershell
# 经 USB 转发后直接查（或把 127.0.0.1 换成设备局域网 IP）
Invoke-WebRequest http://127.0.0.1:5051/sync/status -UseBasicParsing
# → {"available":true,...,"metaCount":17,"dailyCount":510,"latestDate":20260922,"reloadCount":1}
```

| 现象 | 原因与处理 |
| :--- | :--- |
| `available:false` | 增量库还没写进去（首次）→ 跑通道 C 的「立即更新」，或通道 A/B 推一次 |
| 推完状态不变 | App 不在前台/被锁屏（5051 无响应）；或忘了通知热刷新 → 通道脚本会自动 `POST /sync/reload` |
| 云端拉取一直失败 | 看面板「失败原因」：多为网络不通/镜像地址错；主源超时会自动换备源 |
| 版本一直是同一个 | manifest 的 `version` + `sha256` 与本地一致时会**主动跳过下载**（正常省流量行为） |
| 刷新后K线没变化 | 该标的可能不在清单里；或本次生成的数据与上一版相同（非交易日/未开盘） |
| 假期会不会多一根K线 | 不会：当日K线的日期来自行情源时间戳，非交易日不会新增（已用 `--now-date 20261001` 模拟验证） |

**查设备日志**：热刷新链路会打 `[Live]` / `[DB] dataVersion → n` / `[TdxSync]` 三组日志，
经 USB 用 `deploy_kline_to_ipad.py --pull-logs` 拉公共日志查看。

## 8. 硬边界

- **必须前台未锁屏**：iOS 无后台能力（TrollStore 版同样），所有通道的生效前提都是 App 在前台；
  这也是本方案能接受的前提——盯盘时 App 本来就开着。
- **主库不动**：1GB+ 的 `tdx.db` 仍按老办法手动整库替换（替换后需重启）；本机制只自动化"增量"这一层。
- **并发安全**：设备侧同一时刻只允许一个同步在跑；失败一律保留上一版、不留半成品文件。