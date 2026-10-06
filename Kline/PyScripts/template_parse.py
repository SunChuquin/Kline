# -*- coding: utf-8 -*-
"""template_parse.py — .tdx 指标模板解析权威实现（Python 引擎阶段 1 试点批 Task 2）。

契约来源
  - `.trae/specs/add-python-offload-pilot/spec.md` 候选 1（template_parse.py）。

镜像源（本脚本逐条镜像，语义不允许有任何偏差）
  - `Kline/Formula/SystemIndicatorStore.swift` 的 `parse(content:id:)`（58-105 行）：
    头部 KIND= 预扫描 + 主循环逐行（NAME=/SCOPE=/GROUP=/COORD=/FORMULA:|FORMULA|FORMULA=）。
  - `src/contract_golden.py` build_indicator_templates 的 kind 判定：
    KIND 缺失 → 通过；KIND=TECH → 通过；出现 KIND= 且非 TECH（含未知取值）→ 拒载。
  - 注意：`check_indicators.py` 的 parse_tdx 不含 KIND/COORD 处理，以 Swift 版为准。

Swift 语义细节（本脚本的对应写法）
  - 所有行先 strip（Swift `trimmingCharacters(in: .whitespaces)`）再做前缀判断；
  - NAME=：`String(line.dropFirst(5))` → Python `line[5:]`，**不再 strip**（保留原样）；
  - SCOPE=：`String(line.dropFirst(6)).uppercased()` → `line[6:].upper()`；
    取值 MAIN 或 主图 → "main"，否则 "sub"；
  - GROUP=：`line.dropFirst(6).trimmingCharacters(in: .whitespaces)` → `line[6:].strip()`；
  - COORD=：`Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))`，失败为 nil
    → 严格十进制整数解析（`_swift_int`），失败为 None；
  - `FORMULA:` 或恰为 `FORMULA` → 进入 FORMULA 区；`FORMULA=` → 进入 FORMULA 区，
    剩余部分非空则作为 template 首行；进入 FORMULA 区后非空行 append，直到结束；
  - template 为空 → 拒载（Swift parse 返回 nil）。

执行契约（由 Swift 桥接层包装，本脚本不做文件 IO、不依赖 stdout）
  - 桥接把输入 JSON 解析后注入模块全局变量 `kline_input`（dict）；
  - 本脚本定义模块级 dict `kline_result`，`kline_result["ok"]` 为 bool；
  - 输出条目顺序与输入 items 一致；拒载条目也出现在 result 里
    （accepted=false，其余字段 null/默认）。
"""


def _err(msg):
    return {"ok": False, "error": msg}


def _swift_int(s):
    """镜像 Swift `Int(String)`：仅接受可选 +/- 前缀 + 纯 ASCII 数字；
    失败（空串/小数/下划线/全角等）返回 None。"""
    t = s[1:] if s[:1] in ("+", "-") else s
    if t and all("0" <= c <= "9" for c in t):
        return int(s)
    return None


def _rejected(iid):
    """拒载条目（Swift parse 返回 nil → App 端无该定义）。"""
    return {
        "id": iid,
        "accepted": False,
        "name": None,
        "scope": "sub",
        "group": "",
        "coord": None,
        "formulaTemplate": None,
    }


def _parse_tdx(content, iid):
    """逐条镜像 SystemIndicatorStore.parse(content:id:)。"""
    lines = content.splitlines()

    # 头部预扫描：兜住 KIND= 被写在 FORMULA: 之后的手工粘贴场景——
    # 遍历所有行，只要出现 KIND= 且取值不是 TECH（含无法解析的未知值），一律不装载
    for raw in lines:
        line = raw.strip()
        if line.startswith("KIND="):
            value = line[5:].strip().upper()
            if value != "TECH":
                return _rejected(iid)

    name = iid
    scope = "sub"
    group = ""
    coord = None
    template = []
    in_formula = False
    for raw in lines:
        line = raw.strip()
        if in_formula:
            if line:
                template.append(line)
            continue
        if line.startswith("KIND="):
            # 预扫描已保证此处取值必为 TECH；分支保留以逐条镜像 Swift 结构
            kind_value = line[5:].strip().upper()
            if kind_value != "TECH":
                return _rejected(iid)
        elif line.startswith("NAME="):
            name = line[5:]  # Swift dropFirst(5) 原样，不再 strip
        elif line.startswith("SCOPE="):
            v = line[6:].upper()
            scope = "main" if (v == "MAIN" or v == "主图") else "sub"
        elif line.startswith("GROUP="):
            group = line[6:].strip()
        elif line.startswith("COORD="):
            coord = _swift_int(line[6:].strip())
        elif line == "FORMULA:" or line == "FORMULA":
            in_formula = True
        elif line.startswith("FORMULA="):
            in_formula = True
            rest = line[8:]
            if rest:
                template.append(rest)

    if not template:
        return _rejected(iid)
    return {
        "id": iid,
        "accepted": True,
        "name": name,
        "scope": scope,
        "group": group,
        "coord": coord,
        "formulaTemplate": "\n".join(template),
    }


def _main():
    inp = globals().get("kline_input")
    if not isinstance(inp, dict):
        return _err("kline_input 未注入或不是对象")
    items = inp.get("items")
    if not isinstance(items, list):
        return _err("items 必须为数组")
    result = []
    for it in items:
        if not isinstance(it, dict):
            return _err("items 元素必须为对象")
        iid = it.get("id")
        if not isinstance(iid, str) or not iid:
            return _err("items 元素缺少合法 id 字段")
        content = it.get("content")
        if not isinstance(content, str):
            return _err("%s 缺少 content 字符串字段" % iid)
        result.append(_parse_tdx(content, iid))
    return {"ok": True, "result": result}


kline_result = _main()
