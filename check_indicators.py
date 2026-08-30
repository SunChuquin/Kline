#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
编译期校验脚本：扫描 Kline/Indicators/*.tdx，确保每个系统指标模板能被正确加载。

校验逻辑与 App 内 SystemIndicatorStore.parse(content:id:) 保持一致：
  - 解析 NAME= / SCOPE= / FORMULA: 段
  - 必须有 FORMULA 且公式模板非空（否则 App 端 parse 返回 nil，无法加载）
额外检查（固定值模板约束）：
  - 公式中不得残留 {占位符}（系统指标已改为公式内固定值）
  - 公式括号/方括号/花括号配对（轻量语法自检）

返回非 0 会让 Xcode 的 Run Script 构建阶段失败。
"""
import os
import sys
import glob


def parse_tdx(content, fid):
    """与 SystemIndicatorStore.parse 相同的解析规则。"""
    name = fid
    scope = 'sub'
    group = ''
    template = []
    in_formula = False
    for raw in content.splitlines():
        line = raw.strip()
        if in_formula:
            if line:
                template.append(line)
            continue
        if line.startswith('NAME='):
            name = line[5:]
        elif line.startswith('SCOPE='):
            v = line[6:].upper()
            scope = 'main' if (v == 'MAIN' or v == '主图') else 'sub'
        elif line.startswith('GROUP='):
            group = line[6:].strip()
        elif line == 'FORMULA:' or line == 'FORMULA':
            in_formula = True
        elif line.startswith('FORMULA='):
            in_formula = True
            rest = line[8:]
            if rest:
                template.append(rest)
    return name, scope, group, template


def check_delimiters(text):
    """检查 () [] {} 配对，做轻量语法自检。"""
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack = []
    for ch in text:
        if ch in pairs:
            stack.append(ch)
        elif ch in pairs.values():
            if not stack or pairs[stack[-1]] != ch:
                return False, "unmatched '%s'" % ch
            stack.pop()
    if stack:
        return False, "unclosed '%s'" % stack[-1]
    return True, ""


def main(folder):
    files = sorted(glob.glob(os.path.join(folder, '*.tdx')))
    if not files:
        print("[check_indicators] 未找到任何 .tdx 文件: " + folder)
        return 1

    bad = []
    ok = 0
    for path in files:
        fid = os.path.splitext(os.path.basename(path))[0]
        file_errs = []
        try:
            with open(path, 'r', encoding='utf-8') as f:
                content = f.read()
        except Exception as e:
            file_errs.append("无法读取: %s" % e)

        if not file_errs:
            _, scope, group, template = parse_tdx(content, fid)
            if not template:
                file_errs.append("缺少 FORMULA 或公式为空，无法加载")
            else:
                formula = '\n'.join(template)
                if '{' in formula or '}' in formula:
                    file_errs.append("公式仍含 {占位符}，应为固定值")
                ok_d, why = check_delimiters(formula)
                if not ok_d:
                    file_errs.append("公式括号不匹配: " + why)
            # 副图模板必须带 GROUP=（用于选择页数据驱动分组）
            if scope == 'sub' and not group:
                file_errs.append("副图模板缺少 GROUP= 分组字段")

        if file_errs:
            bad.append((fid, file_errs))
        else:
            ok += 1

    if bad:
        print("[check_indicators] ❌ 以下 .tdx 无法正确加载:")
        for fid, errs in bad:
            print("   - %s: %s" % (fid, "; ".join(errs)))
        print("[check_indicators] 失败: %d/%d 个文件异常" % (len(bad), len(files)))
        return 1

    print("[check_indicators] ✅ %d 个 .tdx 全部可正确加载" % ok)
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("用法: python3 check_indicators.py <Indicators目录>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
