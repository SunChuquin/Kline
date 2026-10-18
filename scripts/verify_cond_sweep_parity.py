#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_cond_sweep_parity.py — `cond_sweep`（整环 op）vs 细粒度 op 序列 的双跑对拍。

背景（可行性分析 §11.31）：
  `cond_sweep` 是准备**接替** `SimCondEngine.sweepConditions` 的整环结算 op，但此前
  从未被任何用例执行过（纯死代码），而它要接替的编排覆盖 网格 / 分批 / 仅提醒 / 被拒 /
  失效 五类分支。因此接线前必须先证明「整环 op」与「细粒度 op 序列」在同输入下产出同结果。

对拍口径：
  · 细粒度路径 = 把 `SimCondEngine.sweepConditions` 的编排（有效期 → 判定 →
    触发方向 / 执行价 → submit_order → 档位推进 / 完成 → 预警）用**公开 op** 逐条重放；
  · 两边结果投影成「确定性视图」后逐字段比较——UUID / 新生成的 order id 等每次运行
    都不同的字段归一化（只比较出现次数与业务字段）。

用法:
  python3 scripts/verify_cond_sweep_parity.py
退出码 0 = 全部分支一致；非 0 = 存在漂移（打印逐字段差异）。
"""

import copy
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_sim_rules as vsr  # noqa: E402  （复用 run_op / _cmp）

NOW = "2026-10-18T02:00:00Z"
TZ = 28800  # UTC+8

ACC = {"id": "acc-1", "name": "模拟账户", "isArchived": False, "cash": 1_000_000.0}
POS = {"accountID": "acc-1", "metaID": 1001, "code": "600519.SH", "name": "贵州茅台",
       "qty": 500, "availableQty": 500, "costPrice": 1400.0}


# ---------------------------------------------------------------------------
# 输入构造
# ---------------------------------------------------------------------------

def made_order(oid, kind, params, *, direction="sell", price_type="market", qty=300,
               alert_only=False, runtime=None, validity="longTerm", created_at=None,
               expires_at=None, meta_id=1001, status="monitoring", triggered_count=0):
    return {
        "id": oid, "accountID": "acc-1", "metaID": meta_id, "code": "600519.SH",
        "name": "条件单" + oid, "kind": kind, "params": params,
        "directive": {"direction": direction, "priceType": price_type,
                      "offsetTicks": 0, "qty": qty, "alertOnly": alert_only},
        "validity": validity, "runtime": runtime or {},
        "createdAt": created_at, "expiresAt": expires_at,
        "status": status, "triggeredCount": triggered_count,
    }


def scenario(orders, snapshots, *, last_prices=None, prev_closes=None,
             accounts=None, positions=None, fills=None, existing_orders=None):
    return {
        "orders": orders, "snapshots": snapshots,
        "now": NOW, "tzOffsetSeconds": TZ,
        "accounts": accounts if accounts is not None else {"acc-1": ACC},
        "positions": positions if positions is not None else {"acc-1_1001": POS},
        "lastPrices": last_prices if last_prices is not None else {"1001": 1500.0},
        "prevCloses": prev_closes if prev_closes is not None else {"1001": 1480.0},
        "existingFills": fills or [],
        "existingOrders": existing_orders or [],
    }


# ---------------------------------------------------------------------------
# 细粒度路径：重放 SimCondEngine.sweepConditions 的编排
# ---------------------------------------------------------------------------

def _log(order, content, result):
    return {"accountID": order.get("accountID"), "module": "condition",
            "content": content, "result": result, "occurredAt": NOW,
            "condID": order.get("id")}


def fine_grained(inp):
    orders = [dict(o) for o in inp["orders"]]
    snapshots = inp["snapshots"]
    accounts = inp["accounts"]
    positions = inp["positions"]
    last_prices = inp["lastPrices"]
    prev_closes = inp["prevCloses"]
    existing_fills = list(inp.get("existingFills") or [])
    existing_orders = list(inp.get("existingOrders") or [])
    now = inp["now"]
    tz = inp["tzOffsetSeconds"]

    counts = {"evaluated": 0, "fired": 0, "rejected": 0, "expired": 0, "completed": 0}
    new_orders, new_fills = [], []
    cash_changes, ledger_entries, log_entries, alert_records = [], [], [], []

    for order in orders:
        if order.get("status") != "monitoring":
            continue
        counts["evaluated"] += 1

        # 1) 有效期优先判定
        reason = vsr.run_op({"op": "cond_expired_reason", "order": order, "now": now,
                             "tzOffsetSeconds": tz})["reason"]
        if reason is not None:
            order["status"] = "expired"
            order["updatedAt"] = now
            rt = dict(order.get("runtime") or {})
            rt["lastEvaluatedAt"] = now
            rt["lastMessage"] = reason
            order["runtime"] = rt
            counts["expired"] += 1
            log_entries.append(_log(order, "条件单失效 %s · %s：%s"
                                    % (order.get("name", ""), order.get("kind", ""), reason), "已失效"))
            continue

        # 2) 判定（A 组）
        snap = snapshots[order["id"]]
        decision = vsr.run_op({"op": "cond_evaluate", "order": order,
                               "snapshot": snap, "now": now})["result"]
        kind_dec = decision["decision"]

        if kind_dec == "hold":
            rt = decision.get("runtime") or {}
            if rt:
                order["runtime"] = rt
                order["updatedAt"] = now

        elif kind_dec == "abort":
            order["status"] = "expired"
            order["updatedAt"] = now
            rt = dict(order.get("runtime") or {})
            rt["lastEvaluatedAt"] = now
            rt["lastMessage"] = decision.get("reason", "")
            order["runtime"] = rt
            counts["expired"] += 1
            log_entries.append(_log(order, "条件单失效 %s · %s：%s"
                                    % (order.get("name", ""), order.get("kind", ""),
                                       decision.get("reason", "")), "已失效"))

        elif kind_dec == "complete":
            order["status"] = "completed"
            order["updatedAt"] = now
            rt = dict(order.get("runtime") or {})
            rt["lastEvaluatedAt"] = now
            rt["lastMessage"] = decision.get("reason", "")
            order["runtime"] = rt
            counts["completed"] += 1
            log_entries.append(_log(order, "条件单完成 %s · %s：%s"
                                    % (order.get("name", ""), order.get("kind", ""),
                                       decision.get("reason", "")), "已完成"))

        elif kind_dec == "fire":
            at = float(decision.get("at", 0) or 0)
            qty = int(decision.get("qty", 0) or 0)
            directive = order.get("directive") or {}

            # 「仅提醒」：不下单，只记运行时状态 + 追加预警记录
            if directive.get("alertOnly"):
                message = vsr.run_op({"op": "cond_alert_message", "order": order,
                                      "triggerPrice": at})["message"]
                rt = dict(order.get("runtime") or {})
                rt["lastEvaluatedAt"] = now
                rt["lastPrice"] = snap.get("last", rt.get("lastPrice"))
                rt["lastTriggerPrice"] = at
                order["runtime"] = rt
                order["triggeredCount"] = int(order.get("triggeredCount", 0) or 0) + 1
                order["updatedAt"] = now
                if order.get("kind") in ("grid", "batch"):
                    order["runtime"] = vsr.run_op({"op": "cond_advance", "order": order,
                                                   "triggerPrice": at})["runtime"]
                    if vsr.run_op({"op": "cond_repeatable_finished",
                                   "order": order})["finished"]:
                        order["status"] = "completed"
                        order["runtime"]["lastMessage"] = ("已完成全部档位"
                                                           if order.get("kind") == "grid"
                                                           else "已完成全部批次")
                        counts["completed"] += 1
                    else:
                        order["runtime"]["lastMessage"] = message
                else:
                    order["status"] = "triggered"
                    order["triggeredAt"] = now
                    order["runtime"]["lastMessage"] = message
                counts["fired"] += 1
                alert_records.append({"condID": order.get("id"), "metaID": order.get("metaID"),
                                      "code": order.get("code"), "name": order.get("name"),
                                      "price": at, "message": message, "occurredAt": now})
                continue

            # 下单路径：触发方向 / 执行价 → 运行时 → submit_order → 档位推进
            direction = vsr.run_op({"op": "cond_fire_direction", "order": order,
                                    "triggerPrice": at})["direction"]
            exec_price = vsr.run_op({"op": "cond_execution_price", "directive": directive,
                                     "triggerPrice": at})["price"]

            rt = dict(order.get("runtime") or {})
            rt["lastEvaluatedAt"] = now
            rt["lastPrice"] = snap.get("last", rt.get("lastPrice"))
            rt["lastTriggerPrice"] = at
            order["runtime"] = rt
            order["updatedAt"] = now

            draft = {"accountID": order.get("accountID"), "metaID": order.get("metaID"),
                     "code": order.get("code"), "name": order.get("name"),
                     "direction": direction,
                     "priceType": directive.get("priceType", "market"),
                     "price": exec_price if directive.get("priceType") == "limit" else None,
                     "qty": qty, "originCondID": order.get("id")}
            meta_id = order.get("metaID")
            sr = vsr.run_op({
                "op": "submit_order", "draft": draft,
                "account": accounts.get(order.get("accountID"), {}),
                "position": positions.get("%s_%s" % (order.get("accountID"), meta_id)),
                "lastPrice": last_prices.get(str(meta_id)),
                "prevClose": prev_closes.get(str(meta_id)),
                "now": now, "tzOffsetSeconds": tz,
                "fills": existing_fills + new_fills,
                "orders": existing_orders + new_orders,
            })["result"]
            rejection = sr.get("rejection")

            if rejection is not None:
                counts["rejected"] += 1
                order["runtime"]["lastMessage"] = rejection.get("message", "")
                if order.get("kind") not in ("grid", "batch"):
                    order["status"] = "rejected"
                log_entries.append(_log(order, "条件单触发被拒 %s · %s：%s"
                                        % (order.get("name", ""), order.get("kind", ""),
                                           rejection.get("message", "")),
                                        order.get("status", "rejected")))
                continue

            generated = sr.get("order")
            if generated is not None:
                order["originOrderID"] = generated.get("id")
            order["triggeredCount"] = int(order.get("triggeredCount", 0) or 0) + 1
            counts["fired"] += 1

            if order.get("kind") in ("grid", "batch"):
                order["runtime"] = vsr.run_op({"op": "cond_advance", "order": order,
                                               "triggerPrice": at})["runtime"]
                if vsr.run_op({"op": "cond_repeatable_finished", "order": order})["finished"]:
                    order["status"] = "completed"
                    order["runtime"]["lastMessage"] = ("已完成全部档位"
                                                       if order.get("kind") == "grid"
                                                       else "已完成全部批次")
                    counts["completed"] += 1
                else:
                    order["runtime"]["lastMessage"] = (
                        "已成交第 %d 档" % (order["runtime"].get("gridLevel", 0))
                        if order.get("kind") == "grid"
                        else "已成交第 %d 批" % (order["runtime"].get("batchDone", 0)))
            else:
                order["status"] = "triggered"
                order["triggeredAt"] = now
                order["runtime"]["lastMessage"] = "已触发并生成委托"

            if generated is not None:
                new_orders.append(generated)
            new_fills.extend(sr.get("fills") or [])
            if sr.get("cashChange"):
                cash_changes.append(sr["cashChange"])
            if sr.get("ledgerEntry"):
                ledger_entries.append(sr["ledgerEntry"])
            if sr.get("logEntry"):
                log_entries.append(sr["logEntry"])
            log_entries.append(_log(order, "条件单触发 %s · %s：%s"
                                    % (order.get("name", ""), order.get("kind", ""),
                                       vsr.run_op({"op": "cond_text", "field": "directiveCore",
                                                   "order": order,
                                                   "tzOffsetSeconds": tz})["text"]),
                                    (generated.get("status") if generated else "已触发")))

    return {"orders": orders, "newOrders": new_orders, "newFills": new_fills,
            "cashChanges": cash_changes, "ledgerEntries": ledger_entries,
            "positionChanges": [], "alertRecords": alert_records, "logs": log_entries,
            **counts}


# ---------------------------------------------------------------------------
# 确定性视图 + 比较
# ---------------------------------------------------------------------------

def _rt_view(rt):
    rt = rt or {}
    return {"batchDone": rt.get("batchDone"), "gridLevel": rt.get("gridLevel"),
            "lastEvaluatedAt": rt.get("lastEvaluatedAt"),
            "lastTriggerPrice": rt.get("lastTriggerPrice"),
            "lastPrice": rt.get("lastPrice"), "lastMessage": rt.get("lastMessage")}


def _order_view(o):
    return {"id": o.get("id"), "status": o.get("status"), "updatedAt": o.get("updatedAt"),
            "triggeredAt": o.get("triggeredAt"), "triggeredCount": o.get("triggeredCount"),
            "hasOriginOrder": bool(o.get("originOrderID")), "runtime": _rt_view(o.get("runtime"))}


def view(res):
    return {
        "counts": {k: res.get(k) for k in
                   ("evaluated", "fired", "rejected", "expired", "completed")},
        "orders": [_order_view(o) for o in res.get("orders") or []],
        "newOrders": [{"direction": o.get("direction"), "qty": o.get("qty"),
                       "priceType": o.get("priceType"), "price": o.get("price"),
                       "status": o.get("status"), "originCondID": o.get("originCondID")}
                      for o in res.get("newOrders") or []],
        "newFills": [{"direction": f.get("direction"), "qty": f.get("qty"),
                      "price": f.get("price"), "amount": f.get("amount"),
                      "fee": f.get("fee")} for f in res.get("newFills") or []],
        "cashChanges": [{"cash": c.get("cash")} for c in res.get("cashChanges") or []],
        "ledgerEntries": [{"kind": e.get("kind"), "amount": e.get("amount"),
                           "balanceAfter": e.get("balanceAfter"), "note": e.get("note")}
                          for e in res.get("ledgerEntries") or []],
        "positionChanges": [{"qty": p.get("qty"), "availableQty": p.get("availableQty"),
                             "costPrice": p.get("costPrice"), "removed": p.get("removed")}
                            for p in res.get("positionChanges") or []],
        "alertRecords": [{"condID": a.get("condID"), "price": a.get("price"),
                          "message": a.get("message")}
                         for a in res.get("alertRecords") or []],
        "logs": [{"content": l.get("content"), "result": l.get("result"),
                  "condID": l.get("condID"), "module": l.get("module")}
                 for l in res.get("logs") or []],
    }


# ---------------------------------------------------------------------------
# 场景
# ---------------------------------------------------------------------------

def scenarios():
    sc = []

    # ① 未监控（status != monitoring）：原样返回，不参与结算
    sc.append(("非监控单原样返回",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0},
                                    status="triggered")],
                        {"o1": {"last": 1501.0}})))

    # ② 价格未到 → hold（runtime 可能更新）
    sc.append(("价格未到 hold",
               scenario([made_order("o1", "price", {"triggerPrice": 1600.0, "compareUp": True})],
                        {"o1": {"last": 1500.0}})))

    # ③ 价格上穿 → fire 单次（有账户资金、有持仓）→ triggered + 委托 + 成交
    sc.append(("价格上穿 fire 单次",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0, "compareUp": True},
                                    direction="sell", qty=300)],
                        {"o1": {"last": 1501.0}})))

    # ④ 资金不足 → rejected（买入 100000 股，远超 100 万本金）
    sc.append(("资金不足被拒",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0, "compareUp": True},
                                    direction="buy", qty=100000)],
                        {"o1": {"last": 1501.0}},
                        positions={})))

    # ⑤ 卖出但无可用持仓 → rejected
    sc.append(("卖出无可用持仓被拒",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0, "compareUp": True},
                                    direction="sell", qty=500)],
                        {"o1": {"last": 1501.0}},
                        positions={"acc-1_1001": {"accountID": "acc-1", "metaID": 1001,
                                                  "code": "600519.SH", "name": "贵州茅台",
                                                  "qty": 500, "availableQty": 0,
                                                  "costPrice": 1400.0}})))

    # ⑥ 当日有效跨日失效（createdAt 早于 now 所在日）
    sc.append(("当日有效跨日失效",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0},
                                    validity="day", created_at="2026-10-17T02:00:00Z")],
                        {"o1": {"last": 1501.0}})))

    # ⑦ 指定有效期已过
    sc.append(("指定有效期已过",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0},
                                    validity="untilDate", expires_at="2026-10-17T02:00:00Z")],
                        {"o1": {"last": 1501.0}})))

    # ⑧ 仅提醒（价格型）：不下单、只追加预警记录
    sc.append(("仅提醒 fire（单次）",
               scenario([made_order("o1", "price", {"triggerPrice": 1500.0, "compareUp": True},
                                    direction="sell", qty=300, alert_only=True)],
                        {"o1": {"last": 1501.0}})))

    # ⑨ 仅提醒（网格）：档位推进
    sc.append(("仅提醒 网格推进",
               scenario([made_order("o1", "grid", {"gridBase": 1500.0, "gridUpper": 1650.0,
                                                   "gridLower": 1350.0, "gridStepPct": 5.0,
                                                   "gridQtyPerLevel": 100},
                                    alert_only=True,
                                    runtime={"gridLevel": 0, "batchDone": 0})],
                        {"o1": {"last": 1490.0}})))

    # ⑩ 网格普通单：档位推进
    sc.append(("网格推进（下单）",
               scenario([made_order("o1", "grid", {"gridBase": 1500.0, "gridUpper": 1650.0,
                                                   "gridLower": 1350.0, "gridStepPct": 5.0,
                                                   "gridQtyPerLevel": 100},
                                    direction="sell", runtime={"gridLevel": 0, "batchDone": 0})],
                        {"o1": {"last": 1490.0}})))

    # ⑪ 分批普通单：批次推进
    sc.append(("分批推进（下单）",
               scenario([made_order("o1", "batch", {"batchFirstPrice": 1500.0,
                                                    "batchTotalQty": 300, "batchCount": 3,
                                                    "batchStepPct": 3.0, "batchCompareUp": False},
                                    direction="buy", runtime={"batchDone": 0})],
                        {"o1": {"last": 1490.0}})))

    # ⑫ 触发价缺失 → abort（判定返回 abort：「触发价缺失」）
    sc.append(("触发价缺失 abort",
               scenario([made_order("o1", "price", {})],
                        {"o1": {"last": 1501.0}})))

    return sc


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def main():
    total = 0
    failed = []
    for name, inp in scenarios():
        total += 1
        # ⚠️ 必须各自 deepcopy：sim_rules.py 的 handler 会**就地改写** kline_input（orders 等），
        #    共用同一份输入会让第二条路径看到「已结算过」的单，对拍退化成假绿/假红。
        a = view(vsr.run_op(dict(copy.deepcopy(inp), op="cond_sweep"))["result"])
        b = view(fine_grained(copy.deepcopy(inp)))
        errs = vsr._cmp(b, a, vsr.A0_TOL, "cond_sweep")
        # 反向：op 不得多出字段（_cmp 已覆盖对象键，但列表长度需双向确认）
        errs += vsr._cmp(a, b, vsr.A0_TOL, "fine_grained")
        if errs:
            failed.append((name, errs))
        status = "OK  " if not errs else "FAIL"
        print("[%s] %s" % (status, name))
        for e in errs[:12]:
            print("        %s" % e)
    print("-" * 72)
    print("场景 %d / 一致 %d / 漂移 %d" % (total, total - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
