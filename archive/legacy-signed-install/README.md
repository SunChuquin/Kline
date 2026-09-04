# 归档：签名 IPA 部署形态（Legacy）

> ⚠️ 这是**历史归档**，记录 2026-08-27 ~ 2026-09-03 期间跑通的旧部署形态。
> **当前 Kline 已切换到 TrollStore 部署形态，请勿把这里的文档当现行手册使用。**
> 现行工作流文档：见仓库根 [README.md](../../README.md) 的「部署形态与文档路由」章节。

## 这是什么

Kline 最初用「签名 IPA + `pymobiledevice3 apps install`」部署到 iPad mini 4。这套依赖 Apple 免费开发者证书 + 描述文件，IPA 有效期仅 7 天，过期需重新构建安装。2026-09-04 起，项目切换到 TrollStore 永久安装形态（未签名构建 + ad-hoc 签名 + AFC push），旧形态的相关文档归档至此，便于：

- 需要回退到签名形态时快速恢复
- 对照新旧形态差异
- 历史复盘

## 归档文件

| 文件 | 原位置 | 用途 |
|------|--------|------|
| [TRAE-Windows-Build-Workflow.md](./TRAE-Windows-Build-Workflow.md) | 仓库根（2026-09-04 前版本） | 旧签名形态的 Windows 自动构建 IPA 工作流（含 `apps install` 安装闭环、`apps pull` 读沙盒日志） |
| [iOS-GitHub-Actions-CI.md](./iOS-GitHub-Actions-CI.md) | `ios/` 父目录（不入库） | 旧签名形态的 GitHub Actions CI 初始搭建指南（Appuploader 生成证书 + 描述文件 + 3 个 Secrets） |

## 旧形态概要

| 维度 | 旧形态（本归档） | 现行形态（TrollStore） |
|------|----------------|----------------------|
| 签名方式 | Apple 免费证书签名（development） | ad-hoc 签名（`codesign -f -s -`） |
| CI 产物 | 已签名 IPA（含描述文件） | 未签名 .app + ad-hoc 签名 + entitlements 注入 |
| 安装方式 | `pymobiledevice3 apps install <ipa>` | AFC push 到 `/var/mobile/Media/Downloads/` + TrollStore 手动安装 |
| 有效期 | 7 天 | 永久（TrollStore CoreTrust） |
| 证书 Secrets | 需要 `CERTIFICATE_BASE64` / `CERTIFICATE_PASSWORD` / `PROVISION_PROFILE_BASE64` | 不需要 |
| 权限 | 沙盒内 | `no-sandbox` + `container-required`（突破沙盒） |
| 沙盒日志读取 | `apps pull com.sunck.Kline Documents/debug_log.txt`（HouseArrest） | 待切换为 AFC pull（A1 日志双写方案，见 [Kline-Update-Plans.md](../../Kline-Update-Plans.md)） |
| CI build.yml | import cert → install prof → archive → exportArchive | build (unsigned) → ad-hoc sign + entitlements → package ipa |

## 什么时候参考这里

- 想回退到签名形态（如 TrollStore 失效、需对比测试）
- 排查 `apps install` / 证书 / 描述文件相关历史问题
- 理解项目记忆里「TRAE Windows 自动构建工作流（已验证）」段落的上下文

> 即便回退到签名形态，也建议用新形态的 CI 配置（仓库根的 `build.yml` 已改为未签名构建 + ad-hoc 签名）。如需完整旧 CI，参考这里的 iOS-GitHub-Actions-CI.md 重建 Secrets 与 build.yml。

## 项目记忆快照

项目记忆（`project_memory.md`，位于 `c:\Users\sunck\.trae-cn\memory\`，不在仓库内）当前仍记录旧形态的多个条目，已摘录为 [project_memory-snapshot.md](./project_memory-snapshot.md) 静态快照（含过时点标注 + 新旧命令对照表 + 通用约定备查）。这些过时点已列入 [Kline-Update-Plans.md](../../Kline-Update-Plans.md) 的「待办事项：同步更新其他文档」章节（A1~A7、B1~B8），等 TrollStore 新形态验证完成后按清单统一更新项目记忆。快照仅历史留底，跨会话检索仍以 `.trae-cn/memory/` 现行项目记忆为准。

---

归档时间：2026-09-04
对应现行文档：[../../README.md](../../README.md) · [../../Kline-Update-Plans.md](../../Kline-Update-Plans.md)
