#!/usr/bin/env bash
# 把「给 AltStore 用的最新 ipa」发布到一个固定位置，供 iPhone 手动安装。
#
# 用法：
#   bash scripts/kline_serve_ipa.sh            # = publish：导出最新 ipa → 推到手机固定目录 → 确保 HTTP 服务在跑
#   bash scripts/kline_serve_ipa.sh publish    # 同上（显式）
#   bash scripts/kline_serve_ipa.sh start      # 只启动 HTTP 服务（后台常驻）
#   bash scripts/kline_serve_ipa.sh stop       # 停止 HTTP 服务
#   bash scripts/kline_serve_ipa.sh status     # 查看服务状态与下载地址
#
# 环境变量：
#   SCHEME / CONFIG / TEAM_ID   透传给 kline_export_ipa.sh
#   OUTPUT_DIR                  导出的 ipa 存放目录（默认 build/ipa）
#   SERVE_DIR                   HTTP 服务的根目录（默认 ~/Library/Caches/kline-ipa）
#                               注意：不要指到 /Volumes 下的仓库目录——launchd 拉起的 python
#                               没有该卷的 TCC 授权，会 404（实测）。
#   PORT                        HTTP 端口（默认 8088，固定端口便于手机书签）
#   UDID                        目标设备（缺省自动探测；设为空且 NO_PUSH=1 可跳过推送）
#   NO_PUSH=1                   只导出 + 起服务，不往手机推
#   IPA_SRC=路径                跳过导出，直接发布已有的 ipa
#
# 两个固定落点（实测可用）：
#   1) 手机本地固定目录：Kline 的 Documents（Kline 的 Info.plist 里 UIFileSharingEnabled=true，
#      所以「文件」App → 我的 iPhone → Kline 里能看到它），文件名固定为 Kline-latest.ipa；
#   2) 局域网固定地址：http://<主机名>.local:8088/Kline-latest.ipa（用 Bonjour 主机名，IP 变了也不影响）
#
# 退出码：0 成功；2 参数/环境错误；3 导出失败；4 推送失败；5 服务启动失败
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="${SCHEME:-Kline}"
CONFIG="${CONFIG:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-build/ipa}"
SERVE_DIR="${SERVE_DIR:-$HOME/Library/Caches/kline-ipa}"
PORT="${PORT:-8088}"
UDID="${UDID:-}"
NO_PUSH="${NO_PUSH:-0}"
IPA_SRC="${IPA_SRC:-}"
SERVE_NAME="Kline-latest.ipa"

die() { printf '\n[错误] %s\n' "$2" >&2; exit "$1"; }

lan_ip() {
  ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true
}
mdns_host() {
  local h
  h=$(scutil --get LocalHostName 2>/dev/null || true)
  [ -n "$h" ] && printf '%s.local' "$h" || true
}
server_label() { printf 'kline-ipa-server'; }

# 优先用 launchctl 托管（脱离终端存活，关掉终端也不停）；不可用时退回 nohup
server_alive() {
  if launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$(server_label)"; then
    return 0
  fi
  [ -f "$SERVE_DIR/.server.pid" ] && kill -0 "$(cat "$SERVE_DIR/.server.pid")" 2>/dev/null
}

start_server() {
  mkdir -p "$SERVE_DIR"
  local abs
  abs=$(cd "$SERVE_DIR" && pwd)
  if server_alive; then
    echo "==> HTTP 服务已在运行"
    return 0
  fi
  command -v python3 >/dev/null || die 5 "找不到 python3，无法启动下载服务"
  launchctl remove "$(server_label)" >/dev/null 2>&1 || true
  if ! launchctl submit -l "$(server_label)" -- /usr/bin/python3 -m http.server "$PORT" \
        --bind 0.0.0.0 --directory "$abs" >/dev/null 2>&1; then
    # 兜底：launchctl 不可用（极少见）时退回 nohup
    nohup python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$abs" \
          >"$SERVE_DIR/.server.log" 2>&1 &
    echo $! > "$SERVE_DIR/.server.pid"
  fi
  sleep 1.5
  if ! curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/${SERVE_NAME}"; then
    echo "---- 服务日志 ----" >&2
    tail -5 "$SERVE_DIR/.server.log" 2>/dev/null >&2 || true
    die 5 "服务启动失败或 ${SERVE_NAME} 不可访问（端口 ${PORT} 被占用？换 PORT=xxxx 再试）"
  fi
  echo "==> HTTP 服务已启动（launchctl 托管，端口 ${PORT}）"
}

stop_server() {
  launchctl remove "$(server_label)" >/dev/null 2>&1 || true
  if [ -f "$SERVE_DIR/.server.pid" ]; then
    kill "$(cat "$SERVE_DIR/.server.pid")" 2>/dev/null || true
    rm -f "$SERVE_DIR/.server.pid"
  fi
  echo "==> 已停止"
}

print_urls() {
  local host ip
  host=$(mdns_host)
  ip=$(lan_ip)
  echo
  echo "📥 手机下载地址（Safari 打开即下载到「文件 → 下载」）："
  [ -n "$host" ] && echo "   http://${host}:${PORT}/${SERVE_NAME}   ← 推荐，IP 变了也不用改"
  [ -n "$ip" ]   && echo "   http://${ip}:${PORT}/${SERVE_NAME}"
  echo
  echo "📁 手机本地固定位置（无需下载，直接在 AltStore 里选）："
  echo "   文件 App → 我的 iPhone → Kline → ${SERVE_NAME}"
}

push_to_device() {
  local target="$1"
  # 首选：走 Kline 内置 HTTP 服务（PUT /sandbox，无需数据线、无需「暴露」）
  if IPA_SRC="$target" bash scripts/kline_push_ipa_lan.sh >/tmp/kline_lan_push.log 2>&1; then
    echo "✅ 已通过 Kline 局域网接口写入设备沙盒（$(basename "$target")）"
    return 0
  fi
  echo "⚠️  局域网推送失败，回退 USB：$(tail -1 /tmp/kline_lan_push.log)"
  if [ -z "$UDID" ]; then
    UDID=$(xcrun devicectl list devices 2>/dev/null \
          | awk '/ connected / && / physical /{
              for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$/) {print $i; exit}}')
  fi
  if [ -z "$UDID" ]; then
    echo "⚠️  没有已连接的真机，跳过推送（HTTP 下载地址仍然可用）"
    return 0
  fi
  echo "==> 推送到设备 ${UDID} 的 Kline/Documents/${SERVE_NAME}"
  local log
  log=$(mktemp /tmp/kline_push_XXXX.log)
  if ! xcrun devicectl device copy to --device "$UDID" \
        --domain-type appDataContainer --domain-identifier com.sunck.Kline \
        --source "$target" --destination "Documents/${SERVE_NAME}" >"$log" 2>&1; then
    echo "---- devicectl 输出 ----" >&2
    cat "$log" >&2; rm -f "$log"
    die 4 "推送失败。常见原因：设备未连接/未解锁，或 Kline 尚未安装（先跑 kline_build_install_dev.sh）"
  fi
  rm -f "$log"
  echo "✅ 已推送（手机「文件 → 我的 iPhone → Kline」里可直接选到）"
}

publish() {
  local src="$IPA_SRC"
  if [ -z "$src" ]; then
    echo "==> 导出最新 ipa"
    bash scripts/kline_export_ipa.sh || die 3 "导出 ipa 失败（详见上面的输出）"
    src=$(ls -t "$OUTPUT_DIR"/*.ipa 2>/dev/null | head -1)
    [ -n "$src" ] || die 3 "在 ${OUTPUT_DIR} 找不到任何 ipa"
  fi
  [ -f "$src" ] || die 2 "ipa 不存在：$src"

  mkdir -p "$SERVE_DIR"
  cp "$src" "$SERVE_DIR/${SERVE_NAME}"
  echo "✅ 已更新固定文件：${SERVE_DIR}/${SERVE_NAME} ($(du -h "$SERVE_DIR/${SERVE_NAME}" | cut -f1))"

  [ "$NO_PUSH" = "1" ] || push_to_device "$SERVE_DIR/${SERVE_NAME}"
  # 局域网推送成功后其实不需要 Mac 上再起 HTTP 服务；需要时用 START_HTTP=1 打开
  if [ "${START_HTTP:-0}" = "1" ]; then
    start_server
    print_urls
  else
    echo
    echo "📁 手机上取包位置：文件 App → 浏览 → 我的 iPhone → Kline → ${SERVE_NAME}"
    echo "   （Kline 开了 UIFileSharingEnabled，所以沙盒 Documents 会出现在「文件」里）"
    echo "   如需 Safari 下载：START_HTTP=1 重跑本脚本起 HTTP 服务"
  fi
}

status() {
  if server_alive; then
    echo "服务运行中（launchctl label: $(server_label)）"
    print_urls
  else
    echo "服务未运行。用 bash scripts/kline_serve_ipa.sh start 启动"
  fi
  [ -f "$SERVE_DIR/${SERVE_NAME}" ] && ls -lh "$SERVE_DIR/${SERVE_NAME}" | awk '{print "文件:", $9, $5, $6, $7, $8}'
}

case "${1:-publish}" in
  publish) publish ;;
  start)   mkdir -p "$SERVE_DIR"; [ -f "$SERVE_DIR/${SERVE_NAME}" ] || die 2 "还没有 ${SERVE_NAME}，先跑 publish"; start_server; print_urls ;;
  stop)    stop_server ;;
  status)  status ;;
  *)       die 2 "未知子命令：$1（可用：publish | start | stop | status）" ;;
esac
