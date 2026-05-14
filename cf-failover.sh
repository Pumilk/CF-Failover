#!/usr/bin/env bash
# Cloudflare DNS 故障切换工具 - 交互式菜单版
# 用法: sudo cf-failover.sh           进入菜单
#       sudo cf-failover.sh daemon    守护进程模式（systemd 调用）
set -uo pipefail

# ============================================================
# 路径
# ============================================================
CONFIG_DIR="/etc/cf-failover"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="/var/lib/cf-failover"
STATE_FILE="$STATE_DIR/state"
LOG_FILE="/var/log/cf-failover.log"
SERVICE_NAME="cf-failover"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_PATH="$(readlink -f "$0")"

# ============================================================
# 默认配置
# ============================================================
CF_API_TOKEN=""
ZONE_ID=""
RECORD_ID=""
RECORD_NAME=""
IP_POOL=()
CHECK_INTERVAL=20
FAIL_THRESHOLD=3
CHECK_PORT=443
TTL=1                # 1 = Auto
PROXIED=false        # 灰云 false / 橙云 true

# ============================================================
# 工具
# ============================================================
C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_N=$'\e[0m'
info() { printf '%s[i]%s %s\n' "$C_C" "$C_N" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_N" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_R" "$C_N" "$*"; }
log()  { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }
need_root() { [[ $EUID -ne 0 ]] && { err "请用 sudo 运行"; exit 1; }; }
press_enter() { read -rp "按回车返回菜单..." _; }

service_active() { systemctl is-active --quiet "$SERVICE_NAME"; }
service_exists() { [[ -f "$SERVICE_FILE" ]]; }

load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true; }

save_config() {
  mkdir -p "$CONFIG_DIR" "$STATE_DIR"
  {
    echo "# cf-failover 配置（自动生成，建议用菜单修改）"
    echo "CF_API_TOKEN=$(printf '%q' "$CF_API_TOKEN")"
    echo "ZONE_ID=$(printf '%q' "$ZONE_ID")"
    echo "RECORD_ID=$(printf '%q' "$RECORD_ID")"
    echo "RECORD_NAME=$(printf '%q' "$RECORD_NAME")"
    printf 'IP_POOL=('
    if [[ ${#IP_POOL[@]} -gt 0 ]]; then
      for ip in "${IP_POOL[@]}"; do printf '%q ' "$ip"; done
    fi
    printf ')\n'
    echo "CHECK_INTERVAL=$CHECK_INTERVAL"
    echo "FAIL_THRESHOLD=$FAIL_THRESHOLD"
    echo "CHECK_PORT=$CHECK_PORT"
    echo "TTL=$TTL"
    echo "PROXIED=$PROXIED"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  ok "配置已保存"
  if service_active; then
    warn "服务正在运行，需要重启才能加载新配置（菜单 7 → 选 1）"
  fi
}

cf_api() {
  # $1=METHOD $2=PATH [$3=DATA]
  local args=(-sS --max-time 15 -X "$1"
    "https://api.cloudflare.com/client/v4$2"
    -H "Authorization: Bearer ${CF_API_TOKEN}"
    -H "Content-Type: application/json")
  [[ -n "${3:-}" ]] && args+=(--data "$3")
  curl "${args[@]}"
}

# ============================================================
# 菜单 1：Cloudflare 凭证
# ============================================================
menu_cf_creds() {
  echo
  info "当前 Token: ${CF_API_TOKEN:+${CF_API_TOKEN:0:6}...${CF_API_TOKEN: -4}}"
  info "当前 Zone : $ZONE_ID"
  echo
  read -rp "API Token（留空保留）: " v; [[ -n "$v" ]] && CF_API_TOKEN="$v"
  read -rp "Zone ID（留空保留）: "  v; [[ -n "$v" ]] && ZONE_ID="$v"
  if [[ -n "$CF_API_TOKEN" ]]; then
    info "验证 Token..."
    if echo "$(cf_api GET /user/tokens/verify)" | grep -q '"success":true'; then
      ok "Token 有效"
    else
      err "Token 验证失败，请检查"
    fi
  fi
  save_config
  press_enter
}

# ============================================================
# 菜单 2：选择 DNS 记录
# ============================================================
menu_pick_record() {
  echo
  [[ -z "$CF_API_TOKEN" || -z "$ZONE_ID" ]] && { err "先配置菜单 1"; press_enter; return; }
  info "拉取 A 记录列表..."
  local r; r=$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=A&per_page=100")
  echo "$r" | grep -q '"success":true' || { err "拉取失败: $r"; press_enter; return; }

  mapfile -t records < <(echo "$r" | python3 -c "
import json,sys
for x in json.load(sys.stdin)['result']:
    print(f\"{x['id']}|{x['name']}|{x['content']}|{x['proxied']}\")")
  [[ ${#records[@]} -eq 0 ]] && { warn "无 A 记录"; press_enter; return; }

  echo
  printf '  %-4s %-40s %-18s %s\n' "序号" "记录名" "当前 IP" "代理"
  for i in "${!records[@]}"; do
    IFS='|' read -r _ name content proxied <<<"${records[$i]}"
    printf '  [%-2d] %-40s %-18s %s\n' "$i" "$name" "$content" "$proxied"
  done
  echo
  read -rp "选择序号: " idx
  [[ ! "$idx" =~ ^[0-9]+$ ]] || (( idx >= ${#records[@]} )) && { err "无效"; press_enter; return; }

  IFS='|' read -r RECORD_ID RECORD_NAME current_ip _ <<<"${records[$idx]}"
  ok "已选 $RECORD_NAME ($RECORD_ID)，当前 IP=$current_ip"
  if [[ ${#IP_POOL[@]} -eq 0 ]]; then
    read -rp "IP 池为空，是否把当前 IP $current_ip 加入作为主用？(Y/n): " c
    [[ "$c" != "n" && "$c" != "N" ]] && IP_POOL=("$current_ip")
  fi
  save_config
  press_enter
}

# ============================================================
# 菜单 3：IP 池管理
# ============================================================
menu_ip_pool() {
  while true; do
    echo
    echo "IP 池（[0] 主用，失败按顺序轮换）："
    if [[ ${#IP_POOL[@]} -eq 0 ]]; then
      warn "  （空）"
    else
      for i in "${!IP_POOL[@]}"; do printf '  [%d] %s\n' "$i" "${IP_POOL[$i]}"; done
    fi
    echo "  1) 添加  2) 删除  3) 整体重设  4) 返回"
    read -rp "选择: " c
    case "$c" in
      1) read -rp "新 IP: " ip; [[ -n "$ip" ]] && IP_POOL+=("$ip") && save_config ;;
      2) read -rp "删除序号: " i
         [[ "$i" =~ ^[0-9]+$ ]] && (( i < ${#IP_POOL[@]} )) && \
           IP_POOL=("${IP_POOL[@]:0:$i}" "${IP_POOL[@]:$((i+1))}") && save_config ;;
      3) IP_POOL=(); read -rp "新 IP 列表（空格分隔）: " line
         for ip in $line; do IP_POOL+=("$ip"); done; save_config ;;
      4) break ;;
    esac
  done
}

# ============================================================
# 菜单 4：探测参数
# ============================================================
menu_probe() {
  echo
  read -rp "探测间隔秒 [当前 $CHECK_INTERVAL]: " v; [[ -n "$v" ]] && CHECK_INTERVAL="$v"
  read -rp "失败阈值   [当前 $FAIL_THRESHOLD]: " v; [[ -n "$v" ]] && FAIL_THRESHOLD="$v"
  read -rp "TCP 端口   [当前 $CHECK_PORT]: " v; [[ -n "$v" ]] && CHECK_PORT="$v"
  save_config
  info "切换确认时间 ≈ $((CHECK_INTERVAL * FAIL_THRESHOLD)) 秒"
  press_enter
}

# ============================================================
# 菜单 5：连通性测试
# ============================================================
menu_test() {
  echo
  info "测试 Cloudflare API..."
  if echo "$(cf_api GET /user/tokens/verify)" | grep -q '"success":true'; then
    ok "API 可达"
  else
    err "API 失败"
  fi
  echo
  if [[ ${#IP_POOL[@]} -gt 0 ]]; then
    for ip in "${IP_POOL[@]}"; do
      if ping -c 2 -W 2 -q "$ip" >/dev/null 2>&1; then
        ok "$ip  ping 通"
      elif timeout 3 bash -c "</dev/tcp/$ip/$CHECK_PORT" 2>/dev/null; then
        ok "$ip  TCP:$CHECK_PORT 通（ICMP 丢）"
      else
        err "$ip  不可达"
      fi
    done
  else
    warn "IP 池为空"
  fi
  press_enter
}

# ============================================================
# 菜单 6：查看配置
# ============================================================
menu_show() {
  echo
  echo "===== 当前配置 ====="
  echo "Token    : ${CF_API_TOKEN:+${CF_API_TOKEN:0:6}...${CF_API_TOKEN: -4}}"
  echo "Zone ID  : $ZONE_ID"
  echo "记录     : $RECORD_NAME ($RECORD_ID)"
  echo "TTL/代理 : $TTL / $PROXIED"
  echo "IP 池    : ${IP_POOL[*]:-（空）}"
  echo "探测     : 每 ${CHECK_INTERVAL}s × ${FAIL_THRESHOLD} 次 → ≈ $((CHECK_INTERVAL*FAIL_THRESHOLD))s 切换"
  echo "端口     : $CHECK_PORT"
  echo "服务     : $(service_active && echo 运行中 || echo 未运行)"
  if [[ -f "$STATE_FILE" ]] && [[ ${#IP_POOL[@]} -gt 0 ]]; then
    read -r idx fc 2>/dev/null < "$STATE_FILE" || true
    idx=${idx:-0}; fc=${fc:-0}
    echo "当前主用 : ${IP_POOL[$idx]:-?} (索引 $idx)，失败计数 $fc"
  fi
  echo "===================="
  press_enter
}

# ============================================================
# 菜单 7：安装/启动/重启
# ============================================================
menu_install() {
  echo
  if [[ -z "$CF_API_TOKEN" || -z "$RECORD_ID" || ${#IP_POOL[@]} -lt 2 ]]; then
    err "配置不全：需要 Token、记录、至少 2 个 IP"; press_enter; return
  fi
  if ! service_exists; then
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare DNS Failover Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    ok "服务已安装"
  fi
  systemctl restart "$SERVICE_NAME"
  sleep 1
  systemctl status "$SERVICE_NAME" --no-pager | head -n 8
  press_enter
}

# ============================================================
# 菜单 8：查看日志
# ============================================================
menu_logs() {
  echo
  systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | head -n 6
  echo
  tail -n 30 "$LOG_FILE" 2>/dev/null || warn "暂无日志"
  echo
  read -rp "输入 f 实时跟踪日志（Ctrl+C 退出），回车返回: " c
  [[ "$c" == "f" ]] && tail -f "$LOG_FILE"
}

# ============================================================
# 菜单 9：手动切换（测试用）
# ============================================================
menu_manual_switch() {
  echo
  [[ ${#IP_POOL[@]} -lt 2 ]] && { err "IP 池不足 2 个"; press_enter; return; }
  local idx=0 fc=0
  [[ -f "$STATE_FILE" ]] && read -r idx fc 2>/dev/null < "$STATE_FILE" || true
  idx=${idx:-0}
  local next=$(( (idx + 1) % ${#IP_POOL[@]} ))
  echo "当前主用: ${IP_POOL[$idx]}"
  echo "将切换到: ${IP_POOL[$next]}"
  read -rp "确认？(y/N): " c
  [[ "$c" != "y" && "$c" != "Y" ]] && return
  if update_dns "${IP_POOL[$next]}"; then
    echo "$next 0" > "$STATE_FILE"
    ok "切换完成"
    service_active && systemctl restart "$SERVICE_NAME"
  fi
  press_enter
}

# ============================================================
# 菜单 10：停止/卸载
# ============================================================
menu_uninstall() {
  echo
  read -rp "确认停止并卸载？(y/N): " c
  [[ "$c" != "y" && "$c" != "Y" ]] && return
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  ok "已卸载（配置保留在 $CONFIG_FILE）"
  press_enter
}

# ============================================================
# 守护进程
# ============================================================
check_ip() {
  local ip="$1"
  ping -c 2 -W 2 -q "$ip" >/dev/null 2>&1 && return 0
  timeout 3 bash -c "</dev/tcp/$ip/$CHECK_PORT" 2>/dev/null && return 0
  return 1
}

update_dns() {
  local new_ip="$1"
  local data; data=$(printf '{"type":"A","name":"%s","content":"%s","ttl":%s,"proxied":%s}' \
    "$RECORD_NAME" "$new_ip" "$TTL" "$PROXIED")
  local r; r=$(cf_api PUT "/zones/${ZONE_ID}/dns_records/${RECORD_ID}" "$data")
  if echo "$r" | grep -q '"success":true'; then
    log "DNS updated -> $new_ip"; return 0
  else
    log "DNS update FAILED: $r"; return 1
  fi
}

run_daemon() {
  load_config
  if [[ -z "$CF_API_TOKEN" || -z "$RECORD_ID" || ${#IP_POOL[@]} -lt 2 ]]; then
    log "配置不完整，退出"; exit 1
  fi
  mkdir -p "$STATE_DIR"
  local current_index=0 fail_count=0
  if [[ -f "$STATE_FILE" ]]; then
    read -r current_index fail_count 2>/dev/null < "$STATE_FILE" || true
    current_index=${current_index:-0}; fail_count=${fail_count:-0}
  fi
  # 防止索引越界
  current_index=$(( current_index % ${#IP_POOL[@]} ))
  log "daemon start, current=${IP_POOL[$current_index]}"

  while true; do
    local ip="${IP_POOL[$current_index]}"
    if check_ip "$ip"; then
      (( fail_count > 0 )) && log "Recovered: $ip"
      fail_count=0
    else
      fail_count=$((fail_count + 1))
      log "Check failed $ip ($fail_count/$FAIL_THRESHOLD)"
      if (( fail_count >= FAIL_THRESHOLD )); then
        local next=$(( (current_index + 1) % ${#IP_POOL[@]} ))
        log "Switching ${ip} -> ${IP_POOL[$next]}"
        if update_dns "${IP_POOL[$next]}"; then
          current_index=$next; fail_count=0
        fi
      fi
    fi
    echo "$current_index $fail_count" > "$STATE_FILE"
    sleep "$CHECK_INTERVAL"
  done
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
  load_config
  while true; do
    clear
    echo "========================================"
    echo "   Cloudflare DNS 故障切换 - 菜单"
    echo "========================================"
    echo "  1) 配置 Cloudflare 凭证"
    echo "  2) 选择 DNS 记录"
    echo "  3) 管理 IP 池"
    echo "  4) 调整探测参数"
    echo "  5) 连通性测试"
    echo "  6) 查看当前配置"
    echo "  7) 安装/启动/重启服务"
    echo "  8) 查看日志"
    echo "  9) 手动触发切换（测试）"
    echo " 10) 停止并卸载"
    echo "  0) 退出"
    echo "========================================"
    read -rp "请选择: " c
    case "$c" in
      1) menu_cf_creds ;;
      2) menu_pick_record ;;
      3) menu_ip_pool ;;
      4) menu_probe ;;
      5) menu_test ;;
      6) menu_show ;;
      7) menu_install ;;
      8) menu_logs ;;
      9) menu_manual_switch ;;
      10) menu_uninstall ;;
      0) exit 0 ;;
    esac
  done
}

case "${1:-menu}" in
  daemon)  run_daemon ;;
  menu|"") need_root; main_menu ;;
  *) echo "用法: $0 [menu|daemon]"; exit 1 ;;
esac
