# -*- coding: utf-8 -*-
"""sim_state.py — 交易状态持久层（阶段 B：状态所有权反转）。

职责：读取 / 写入 / 增量应用 `Documents/Simulation/sim.json`，由 Python 引擎
独占持有状态文件的读写权，Swift 侧退化为「投影缓存 + 桥接客户端」。

契约（与 KlinePythonBridge 一致）：
  - 桥接注入模块全局 dict `kline_input`；产出模块级 dict `kline_result`，
    `kline_result["ok"]` 为 bool。
  - 输入 `filePath`：sim.json 绝对路径（Swift 侧传入，避免 Python 硬编码沙盒路径）。
  - 日期一律 ISO8601 字符串（UTC 带 Z），与 SimStore 落盘口径一致。
  - UUID 与 Date 通过字符串在 JSON 层面传递，Python 不做类型转换。

op 一览（阶段 B）：
  sim_state_load      —— 读取 sim.json，返回完整状态（含 revision）
  sim_state_save      —— 写入完整状态到 sim.json
  sim_state_apply     —— 增量应用状态变更（accounts/positions/orders/fills/ledger/
                      logs/conditionalOrders/alertRecords/selectedAccountID），
                      返回更新后的完整状态 + 新 revision
  sim_state_get_revision —— 轻量获取当前 revision（用于同步前检查）
  sim_state_sync      —— 基于 revision 的差分同步（客户端 revision 旧时返回完整状态）
  sim_state_deposit   —— 入金：修改账户 cash，添加 ledger/log 条目
  sim_state_withdraw  —— 出金：修改账户 cash（受可用资金限制），添加 ledger/log 条目
  sim_state_create_account —— 新建账户：Python 生成 UUID，创建账户 + ledger/log 条目
"""

import json
import os
import threading

# --- 全局锁：防止并发写入 sim.json 导致损坏 -------------------------------
_lock = threading.Lock()

# --- 信任链版本（与 sim_rules.py 独立，sim_state 契约变更时 +1） ---------
SIM_STATE_SCRIPT_VERSION = 1
SIM_STATE_REQUIRED_API_VERSION = 1


def _err(msg):
    return {"ok": False, "error": msg}


def _ok(result=None):
    """出参信封：**平铺**顶层。

    ⚠️ 2026-10-19 修复：此前把状态嵌在 `result` 下（`{"ok": true, "result": {...}}`），
    但 Swift 侧 `SimStateBridge.payload` 直接把**整个信封**交给调用方，
    `SimStore` 于是① 读不到顶层 `revision`（revision 同步协议失效）、
    ② 读档时按顶层解码 `SimRoot` → 得到**空账户/空持仓**（静默丢档）。
    与本仓 `sim_rules.py` 等脚本的出参口径对齐（`{"ok": True, **payload}`）。
    """
    r = {"ok": True}
    if isinstance(result, dict):
        r.update(result)
    return r


def _load_file(filePath):
    """读取 sim.json，缺失或损坏返回空骨架。"""
    if not filePath or not os.path.exists(filePath):
        return _empty_state()
    try:
        with open(filePath, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return _empty_state()
        # 保证必备键存在
        state = _empty_state()
        for k in state:
            if k in data:
                state[k] = data[k]
        return state
    except Exception:
        return _empty_state()


def _empty_state():
    return {
        "schemaVersion": 3,
        "accounts": [],
        "positions": [],
        "orders": [],
        "fills": [],
        "ledger": [],
        "logs": [],
        "conditionalOrders": [],
        "selectedAccountID": None,
        "alertRecords": [],
        "revision": 0,
    }


def _save_file(filePath, state):
    """原子写入 sim.json（写临时文件后 rename，避免崩溃时损坏原文件）。"""
    if not filePath:
        return False, "filePath 缺失"
    dirPath = os.path.dirname(filePath)
    if dirPath and not os.path.exists(dirPath):
        os.makedirs(dirPath, exist_ok=True)
    tmpPath = filePath + ".tmp"
    try:
        with open(tmpPath, "w", encoding="utf-8") as f:
            json.dump(state, f, ensure_ascii=False, indent=2, sort_keys=True)
        os.replace(tmpPath, filePath)
        return True, ""
    except Exception as e:
        try:
            if os.path.exists(tmpPath):
                os.remove(tmpPath)
        except Exception:
            pass
        return False, str(e)


# =========================================================================
# op 实现
# =========================================================================

def _op_sim_state_load(inp):
    filePath = inp.get("filePath")
    state = _load_file(filePath)
    return _ok(state)


def _op_sim_state_save(inp):
    filePath = inp.get("filePath")
    state = inp.get("state")
    if not isinstance(state, dict):
        return _err("state 缺失或非对象")
    ok, err = _save_file(filePath, state)
    if not ok:
        return _err(err)
    return _ok()


def _op_sim_state_apply(inp):
    """增量应用状态变更。

    输入：
      {
        "filePath": "...",
        "changes": {
          "accounts": [...],          # 可选，全部替换
          "positions": [...],
          "orders": [...],
          "fills": [...],
          "ledger": [...],
          "logs": [...],
          "conditionalOrders": [...],
          "alertRecords": [...],
          "selectedAccountID": "...",
          "schemaVersion": 3,
        },
        "merge": {                    # 可选，数组类型字段的合并模式
          "orders": "append",         # append / replace （默认 replace）
          "fills": "append",
          "ledger": "append",
          "logs": "append",
          "conditionalOrders": "replace",
          "alertRecords": "append",
        }
      }
    返回：更新后的完整状态 + 新 revision
    """
    filePath = inp.get("filePath")
    changes = inp.get("changes") or {}
    merge = inp.get("merge") or {}

    with _lock:
        state = _load_file(filePath)

        # 逐字段应用变更
        for key in ("accounts", "positions", "orders", "fills", "ledger", "logs",
                    "conditionalOrders", "alertRecords"):
            if key in changes:
                val = changes[key]
                if not isinstance(val, list):
                    return _err("changes.%s 须为数组" % key)
                mode = merge.get(key, "replace")
                if mode == "append" and isinstance(state.get(key), list):
                    state[key] = state[key] + val
                else:
                    state[key] = val

        if "selectedAccountID" in changes:
            state["selectedAccountID"] = changes["selectedAccountID"]
        if "schemaVersion" in changes:
            state["schemaVersion"] = changes["schemaVersion"]

        # revision 自增
        state["revision"] = int(state.get("revision", 0)) + 1

        ok, err = _save_file(filePath, state)
        if not ok:
            return _err(err)

    return _ok(state)


def _op_sim_state_get_revision(inp):
    """轻量获取当前 revision，用于同步前检查是否需要同步。"""
    filePath = inp.get("filePath")
    state = _load_file(filePath)
    return _ok({"revision": int(state.get("revision", 0))})


def _op_sim_state_sync(inp):
    """基于 revision 的差分同步。

    输入：
      {
        "filePath": "...",
        "clientRevision": <int>  # 客户端当前已知的 revision
      }
    返回：
      {
        "revision": <int>,       # 服务端当前 revision
        "state": { ... }         # 若客户端 revision < 服务端 revision，返回完整状态；
                                 # 否则 state 为空 dict（无变更，无需同步）
      }
    """
    filePath = inp.get("filePath")
    clientRev = int(inp.get("clientRevision", 0) or 0)
    state = _load_file(filePath)
    serverRev = int(state.get("revision", 0))

    if clientRev < serverRev:
        return _ok({"revision": serverRev, "state": state})
    else:
        return _ok({"revision": serverRev, "state": {}})


def _find_account_index(accounts, accountID):
    """按 accountID 查找账户索引，未找到返回 None。"""
    for i, acc in enumerate(accounts):
        if acc.get("id") == accountID:
            return i
    return None


def _op_sim_state_deposit(inp):
    """入金：修改账户 cash，添加 ledger 条目和 log 条目。

    输入：
      {
        "filePath": "...",
        "accountID": "...",
        "amount": <float>,
        "note": "<str>",
        "ledgerEntry": { ... },   # 完整 ledger 条目（可选）
        "logEntry": { ... }       # 完整 log 条目（可选）
      }
    返回：更新后的完整状态 + 新 revision
    """
    filePath = inp.get("filePath")
    accountID = inp.get("accountID")
    amount = float(inp.get("amount", 0) or 0)
    note = inp.get("note", "")
    ledgerEntry = inp.get("ledgerEntry")
    logEntry = inp.get("logEntry")

    with _lock:
        state = _load_file(filePath)
        accounts = state.get("accounts", [])
        idx = _find_account_index(accounts, accountID)
        if idx is None:
            return _err("账户不存在：%s" % accountID)
        if amount <= 0:
            return _err("入金金额必须大于 0")

        accounts[idx]["cash"] = accounts[idx].get("cash", 0) + amount
        state["accounts"] = accounts

        if isinstance(ledgerEntry, dict):
            ledger = state.get("ledger", [])
            ledger.append(ledgerEntry)
            state["ledger"] = ledger

        if isinstance(logEntry, dict):
            logs = state.get("logs", [])
            logs.append(logEntry)
            state["logs"] = logs

        state["revision"] = int(state.get("revision", 0)) + 1

        ok, err = _save_file(filePath, state)
        if not ok:
            return _err(err)

    return _ok(state)


def _op_sim_state_withdraw(inp):
    """出金：修改账户 cash（受可用资金限制），添加 ledger 条目和 log 条目。

    输入：
      {
        "filePath": "...",
        "accountID": "...",
        "amount": <float>,
        "note": "<str>",
        "ledgerEntry": { ... },   # 完整 ledger 条目（可选）
        "logEntry": { ... }       # 完整 log 条目（可选）
      }
    返回：更新后的完整状态 + 新 revision
    """
    filePath = inp.get("filePath")
    accountID = inp.get("accountID")
    amount = float(inp.get("amount", 0) or 0)
    note = inp.get("note", "")
    ledgerEntry = inp.get("ledgerEntry")
    logEntry = inp.get("logEntry")

    with _lock:
        state = _load_file(filePath)
        accounts = state.get("accounts", [])
        idx = _find_account_index(accounts, accountID)
        if idx is None:
            return _err("账户不存在：%s" % accountID)
        if amount <= 0:
            return _err("出金金额必须大于 0")

        currentCash = accounts[idx].get("cash", 0)
        real = min(amount, currentCash)
        if real <= 0:
            return _err("账户余额不足，无法出金")

        accounts[idx]["cash"] = currentCash - real
        state["accounts"] = accounts

        if isinstance(ledgerEntry, dict):
            ledger = state.get("ledger", [])
            ledger.append(ledgerEntry)
            state["ledger"] = ledger

        if isinstance(logEntry, dict):
            logs = state.get("logs", [])
            logs.append(logEntry)
            state["logs"] = logs

        state["revision"] = int(state.get("revision", 0)) + 1

        ok, err = _save_file(filePath, state)
        if not ok:
            return _err(err)

    return _ok(state)


def _op_sim_state_create_account(inp):
    """新建账户：Python 侧生成 UUID，创建账户并添加 ledger/log 条目。

    输入：
      {
        "filePath": "...",
        "name": "<str>",
        "badge": "<str>",
        "colorHex": "<str>",
        "initialCapital": <float>,
        "cash": <float>,
        "createdAt": "<ISO8601>",
        "ledgerEntry": { ... },   # 完整 ledger 条目（可选）
        "logEntry": { ... }       # 完整 log 条目（可选）
      }
    返回：更新后的完整状态 + 新 revision + 新账户对象（含生成的 id）
    """
    import uuid

    filePath = inp.get("filePath")
    name = inp.get("name", "")
    badge = inp.get("badge", "")
    colorHex = inp.get("colorHex", "")
    initialCapital = float(inp.get("initialCapital", 0) or 0)
    cash = float(inp.get("cash", 0) or 0)
    createdAt = inp.get("createdAt")
    ledgerEntry = inp.get("ledgerEntry")
    logEntry = inp.get("logEntry")

    with _lock:
        state = _load_file(filePath)

        newID = str(uuid.uuid4())
        account = {
            "id": newID,
            "name": name,
            "badge": badge,
            "colorHex": colorHex,
            "initialCapital": initialCapital,
            "cash": cash,
            "createdAt": createdAt,
            "isArchived": False,
        }
        accounts = state.get("accounts", [])
        accounts.append(account)
        state["accounts"] = accounts

        # 将 ledger/log 条目中的 accountID 替换为新生成的 UUID
        if isinstance(ledgerEntry, dict):
            ledgerEntry = dict(ledgerEntry)
            ledgerEntry["accountID"] = newID
            ledger = state.get("ledger", [])
            ledger.append(ledgerEntry)
            state["ledger"] = ledger

        if isinstance(logEntry, dict):
            logEntry = dict(logEntry)
            logEntry["accountID"] = newID
            logs = state.get("logs", [])
            logs.append(logEntry)
            state["logs"] = logs

        state["revision"] = int(state.get("revision", 0)) + 1

        ok, err = _save_file(filePath, state)
        if not ok:
            return _err(err)

    # 返回新账户对象，供 Swift 侧构造 SimAccount
    result = dict(state)
    result["newAccount"] = account
    return _ok(result)


# --- op 分发表 --------------------------------------------------------------
_OPS = {
    "sim_state_load": _op_sim_state_load,
    "sim_state_save": _op_sim_state_save,
    "sim_state_apply": _op_sim_state_apply,
    "sim_state_get_revision": _op_sim_state_get_revision,
    "sim_state_sync": _op_sim_state_sync,
    "sim_state_deposit": _op_sim_state_deposit,
    "sim_state_withdraw": _op_sim_state_withdraw,
    "sim_state_create_account": _op_sim_state_create_account,
}


def run(inp):
    """桥接入口：inp 为 kline_input，含 op 字段。返回 kline_result 形状 dict。"""
    op = inp.get("op")
    fn = _OPS.get(op)
    if fn is None:
        return _err("未知 op：%s" % op)
    try:
        return fn(inp)
    except Exception as e:
        return _err("脚本异常：%s" % e)


def _main():
    """桥接入口：`KlinePythonBridge` 以 exec 方式运行本脚本，随后读**模块级** `kline_result`。

    ⚠️ 2026-10-19 修复：本脚本此前只定义 `run(inp)` 而无模块级 `kline_result`，
    导致桥接层包装脚本报「脚本未定义 dict 类型的 kline_result」→ **生产里所有
    `sim_state_*` 调用都失败并静默降级**（阶段 B 的状态所有权反转实际从未生效）。
    """
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    return run(inp)


kline_result = _main()

# 供桥接层直接 import 调用（不走 JSON 分发）
__all__ = ["run", "SIM_STATE_SCRIPT_VERSION", "SIM_STATE_REQUIRED_API_VERSION"]