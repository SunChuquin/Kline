#!/usr/bin/env bash
# 通过 Kline App 内置的局域网 HTTP 服务，把最新 ipa 直接推进 iPhone 的沙盒
# （Kline 的 Documents），用户在「文件」App 里就能直接看到并交给 AltStore 安装。
#
# 用到的设备端实现（以代码为准，见 Kline/Infrastructure/KlineHTTPServer.swift）：
#   - 路由：PUT /sandbox/<相对路径> → 写入 App 沙盒 Documents/<相对路径>（先写 .part，收完 rename）
#   - 鉴权：沙盒写门禁 = 回环 / 已「暴露」 / 请求头 X-Kline-Client: pipeline 三者之一
#           → 本脚本走 pipeline 头，**不需要配对 token，也不需要打开「暴露」**
#   - 端口：默认 5051（App 启动参数里的 KLINE_HTTP_PORT 可覆盖）
#   - 大小限制：服务端未设 body 上限（实测 34 MB / 2.3 s 通过）
#
# 用法：
#   bash scripts/kline_push_ipa_lan.sh                 # 用 build/ipa 里最新的 ipa 推送
#   bash scripts/kline_push_ipa_lan.sh discover        # 只找设备地址
#   HOST=192.168.2.9 bash scripts/kline_push_ipa_lan.sh
#   IPA_SRC=~/Downloads/Kline.ipa HOST=192.168.2.9 bash scripts/kline_push_ipa_lan.sh
#
# 环境变量：
#   HOST        设备局域网地址（缺省自动发现；发现到多个会要求显式指定）
#   PORT        设备 HTTP 端口（默认 5051）
#   IPA_SRC     要推送的 ipa（缺省取 build/ipa/*.ipa 里最新的）
#   REMOTE_NAME 设备上的文件名（默认 Kline-latest.ipa，固定名便于长期复用）
#
# 退出码：0 成功；2 参数/发现失败；3 无 ipa；4 推送失败；5 校验失败
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-5051}"
HOST="${HOST:-}"
IPA_SRC="${IPA_SRC:-}"
OUTPUT_DIR="${OUTPUT_DIR:-build/ipa}"
REMOTE_NAME="${REMOTE_NAME:-Kline-latest.ipa}"
HDR="X-Kline-Client: pipeline"

die() { printf '\n[错误] %s\n' "$2" >&2; exit "$1"; }

own_ips() { ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' || true; }
is_own_ip() { own_ips | grep -qx "$1"; }

# 设备端 /sandbox/ 用 pipeline 头访问，返回 JSON 数组即认为是 Kline 实例
probe() {
  local ip="$1"
  curl -sS -m 3 -H "$HDR" "http://${ip}:${PORT}/sandbox/" 2>/dev/null | head -c 1 | grep -q '\['
}

discover() {
  # 1) 优先 mDNS（仅在用户打开「暴露」时才会广播 _klinesync._tcp）
  local name
  name=$(dns-sd -B _klinesync._tcp local 2>/dev/null & sleep 2; kill $! 2>/dev/null)
  local m
  m=$(echo "$name" | awk '/_klinesync/{print $NF}' | head -1)
  if [ -n "${m:-}" ]; then
    local hostip
    hostip=$(printf '%s\n' "$(dns-sd -G v4 "$m.local" 2>/dev/null & sleep 2; kill $! 2>/dev/null)" \
             | awk '/Add/{print $4}' | head -1)
    if [ -n "${hostip:-}" ]; then echo "$hostip"; return 0; fi
  fi
  # 2) 退回扫本网段端口（排除本机所有 IP，避免连到 Mac 上的模拟器实例）
  local prefix
  prefix=$(own_ips | grep -E '^(192|10|172)\.' | head -1 | awk -F. '{print $1"."$2"."$3}')
  [ -n "$prefix" ] || return 1
  local found
  found=$(seq 1 254 | xargs -P 64 -I{} sh -c \
            "nc -z -G 1 ${prefix}.{} ${PORT} 2>/dev/null && (curl -sS -m 2 -H '${HDR}' http://${prefix}.{}:${PORT}/sandbox/ 2>/dev/null | head -c1 | grep -q '\\[' && echo ${prefix}.{})" \
          | sort -u || true)
  # 排除本机 IP（Mac 上可能同时跑着模拟器实例，它也会响应 /sandbox/）
  found=$(printf '%s\n' "$found" | while read -r ip; do [ -n "$ip" ] && ! is_own_ip "$ip" && echo "$ip"; done || true)
  [ -n "$found" ] || return 1
  if [ "$(printf '%s\n' "$found" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "$found" >&2
    return 2
  fi
  echo "$found"
  return 0
}

cmd="${1:-push}"
if [ "$cmd" = "discover" ]; then
  HOST=$(discover) || die 2 "没找到 Kline 设备。请确认：手机与 Mac 同一 Wi-Fi、Kline 正在前台运行；或显式指定 HOST=<手机IP>"
  echo "$HOST"; exit 0
fi

[ -n "$HOST" ] || HOST=$(discover) || die 2 "自动发现失败（可能扫到多台或没有设备）。请在手机「设置 → Wi-Fi → ⓘ」看 IP，然后 HOST=<ip> bash scripts/kline_push_ipa_lan.sh"
is_own_ip "$HOST" && die 2 "$HOST 是本机地址（Mac 上的模拟器实例），请改用 iPhone 的 IP"

[ -n "$IPA_SRC" ] || IPA_SRC=$(ls -t "$OUTPUT_DIR"/*.ipa 2>/dev/null | head -1 || true)
[ -n "$IPA_SRC" ] && [ -f "$IPA_SRC" ] || die 3 "找不到 ipa。先跑 bash scripts/kline_export_ipa.sh，或用 IPA_SRC=<路径> 指定"

SIZE=$(du -h "$IPA_SRC" | cut -f1)
echo "==> 推送 $(basename "$IPA_SRC") ($SIZE) → http://${HOST}:${PORT}/sandbox/${REMOTE_NAME}"

RESP=$(curl -sS -m 600 -X PUT --data-binary @"$IPA_SRC" \
        -H "$HDR" -H "Content-Type: application/octet-stream" \
        -w '\n%{http_code}' \
        "http://${HOST}:${PORT}/sandbox/${REMOTE_NAME}" 2>&1) || {
  die 4 "推送请求失败：网络不通 / 手机不在同一 Wi-Fi / Kline 已被系统挂起（把它切到前台再试）"
}
CODE=$(printf '%s' "$RESP" | tail -1)
BODY=$(printf '%s' "$RESP" | sed '$d')
case "$CODE" in
  200) : ;;
  403) die 4 "403：设备拒绝了沙盒写（说明请求头没带上或被代理改写）。用 -H '${HDR}' 直连设备 IP，别经过反向代理" ;;
  404) die 4 "404：该地址上没有 /sandbox/ 路由（不是 Kline 实例，或版本过旧）" ;;
  *)   die 4 "推送失败 HTTP ${CODE}：${BODY}" ;;
esac
echo "==> 设备返回：${BODY}"

# 校验：列目录确认文件已落地且大小一致
GOT=$(curl -sS -m 10 -H "$HDR" "http://${HOST}:${PORT}/sandbox/" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(next((i['size'] for i in d if i.get('name')=='${REMOTE_NAME}'),''))" 2>/dev/null || true)
WANT=$(stat -f %z "$IPA_SRC")
[ "$GOT" = "$WANT" ] || die 5 "校验失败：设备上是 ${GOT:-无此文件} 字节，本地是 ${WANT} 字节"

echo "✅ 已落地：Kline 沙盒 Documents/${REMOTE_NAME}（$((WANT/1048576)) MB，大小一致）"
echo
echo "接下来在 iPhone 上操作："
echo "  1) 打开「文件」App → 浏览 → 我的 iPhone → Kline → 看到 ${REMOTE_NAME}"
echo "  2) AltStore → My Apps → 左上角 ＋ → 选这个 ipa → 首次输入 Apple ID 密码"
echo "  3) 装完 My Apps 里出现 Kline 与剩余天数 → 它才进入 Refresh All 的续签范围"
