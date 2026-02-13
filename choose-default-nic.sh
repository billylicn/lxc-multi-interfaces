#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# 内置：出口区域名单（按需修改）
# 优先级：IFACE_REGION > CIDR_REGION > 默认“未知区域”
# =========================================================
declare -A IFACE_REGION=(
  # [eth0]="管理网/公网"
)

declare -A CIDR_REGION=(
  ["10.129.17.0/24"]="管理网/公网"
  ["10.99.0.0/24"]="业务区A"
  ["10.98.0.0/24"]="业务区B"
  ["10.97.0.0/24"]="业务区C"
  ["10.96.0.0/24"]="业务区D"
  ["10.95.0.0/24"]="业务区E"
  ["10.94.0.0/24"]="业务区F"
  ["10.93.0.0/24"]="业务区G"
  ["10.92.0.0/24"]="业务区H"
)

# =========================================================
# 公网 IP 查询站点（会依次尝试；你可按需增删）
# =========================================================
IP_CHECK_URLS=(
  "https://api.ipify.org"
  "https://icanhazip.com"
  "https://ipinfo.io/ip"
  "https://ifconfig.me/ip"
)

# 超时（秒）
IP_CHECK_TIMEOUT="${IP_CHECK_TIMEOUT:-4}"

# =========================================================
# 美化输出（无 tput 也能用）
# =========================================================
if command -v tput >/dev/null 2>&1; then
  C_BOLD="$(tput bold)"
  C_DIM="$(tput dim)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_RESET="$(tput sgr0)"
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

hr() { printf '%*s\n' "${1:-100}" '' | tr ' ' '-'; }

die() { echo "${C_RED}$*${C_RESET}" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行：sudo $0"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# =========================================================
# 基础信息获取
# =========================================================
get_eth_ifaces() {
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | awk -F'@' '{print $1}' \
    | grep -E '^eth[0-9]+' \
    | sort -V \
    | uniq
}

get_ipv4_cidr() {
  local dev="$1"
  ip -o -4 addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -n1
}

get_ipv4_ip() {
  local cidr="${1:-}"
  [[ -n "$cidr" ]] && echo "${cidr%%/*}" || true
}

get_link_cidr() {
  local dev="$1"
  ip -o -4 route show dev "$dev" scope link 2>/dev/null | awk '{print $1}' | head -n1
}

calc_gw_dot1() {
  local ip="$1"
  awk -F. '{print $1"."$2"."$3".1"}' <<<"$ip"
}

get_region() {
  local dev="$1"
  local cidr="$2"
  if [[ -n "${IFACE_REGION[$dev]+x}" ]]; then
    echo "${IFACE_REGION[$dev]}"
  elif [[ -n "${CIDR_REGION[$cidr]+x}" ]]; then
    echo "${CIDR_REGION[$cidr]}"
  else
    echo "未知区域"
  fi
}

# =========================================================
# 出口信息：本机路由推断 + 公网出口IP（外联查询）
# =========================================================
get_route_guess() {
  local target="${1:-1.1.1.1}"
  local line
  line="$(ip -4 route get "$target" 2>/dev/null | head -n1 || true)"
  [[ -z "$line" ]] && { echo "route=N/A"; return 0; }

  local via dev src
  via="$(awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' <<<"$line")"
  dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$line")"
  src="$(awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' <<<"$line")"
  echo "dev=${dev:-?} via=${via:-?} src=${src:-?}"
}

get_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    for url in "${IP_CHECK_URLS[@]}"; do
      ip="$(curl -4 -sS --max-time "$IP_CHECK_TIMEOUT" "$url" 2>/dev/null | tr -d ' \r\n' || true)"
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
  elif command -v wget >/dev/null 2>&1; then
    for url in "${IP_CHECK_URLS[@]}"; do
      ip="$(wget -4 -qO- --timeout="$IP_CHECK_TIMEOUT" "$url" 2>/dev/null | tr -d ' \r\n' || true)"
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
    done
  else
    echo "N/A(need curl/wget)"
    return 0
  fi

  echo "N/A"
}

show_egress_report() {
  local route_guess public_ip
  route_guess="$(get_route_guess 1.1.1.1)"
  public_ip="$(get_public_ip)"
  echo "公网IP=${public_ip} | 路由推断(${route_guess})"
}

# =========================================================
# 路由变更
# =========================================================
backup_default_routes() {
  local backup="/tmp/default_routes.backup.$(date +%F_%H%M%S).txt"
  ip -4 route show default > "$backup" || true
  echo "$backup"
}

apply_default_route() {
  local dev="$1"
  local gw="$2"
  ip -4 route replace default via "$gw" dev "$dev"
}

# =========================================================
# 主流程
# =========================================================
need_root
need_cmd ip

echo "${C_BOLD}默认出口网卡选择/切换工具${C_RESET}"
hr
echo "${C_DIM}运行前出口信息：$(show_egress_report)${C_RESET}"
echo "${C_DIM}当前 default 路由：${C_RESET}"
ip -4 route show default || true
hr
echo

mapfile -t ifaces < <(get_eth_ifaces)
[[ "${#ifaces[@]}" -gt 0 ]] || die "未发现 eth* 网卡"

declare -a DEV_LIST IP_LIST CIDR_LIST GW_LIST REGION_LIST

printf "%s\n" "${C_BOLD}可选出口网卡：${C_RESET}"
printf "%-6s %-8s %-18s %-18s %-16s %s\n" "No." "DEV" "IPv4" "LINK_CIDR" "GATEWAY" "REGION"
printf "%-6s %-8s %-18s %-18s %-16s %s\n" "------" "--------" "------------------" "------------------" "----------------" "----------------"

idx=0
for dev in "${ifaces[@]}"; do
  ipv4_cidr="$(get_ipv4_cidr "$dev" || true)"
  ipv4_ip="$(get_ipv4_ip "$ipv4_cidr" || true)"
  link_cidr="$(get_link_cidr "$dev" || true)"
  [[ -z "$link_cidr" ]] && link_cidr="${ipv4_cidr:-N/A}"

  if [[ -n "$ipv4_ip" ]]; then
    gw="$(calc_gw_dot1 "$ipv4_ip")"
  else
    gw="N/A"
  fi

  region="$(get_region "$dev" "$link_cidr")"

  DEV_LIST+=("$dev")
  IP_LIST+=("${ipv4_cidr:-N/A}")
  CIDR_LIST+=("$link_cidr")
  GW_LIST+=("$gw")
  REGION_LIST+=("$region")

  printf "[%-4s] %-8s %-18s %-18s %-16s %s\n" \
    "$idx" "$dev" "${ipv4_cidr:-N/A}" "$link_cidr" "$gw" "$region"
  ((idx++))
done

echo
hr
echo "${C_BOLD}操作选择：${C_RESET}"
echo "  ${C_YELLOW}输入编号${C_RESET}：切换默认出口到该网卡"
echo "  ${C_YELLOW}输入 r${C_RESET}    ：恢复默认出口（eth0）"
echo "  ${C_YELLOW}输入 q${C_RESET}    ：退出"
hr
read -r -p "请输入选择（编号/r/q）： " choice

[[ "${choice:-}" =~ ^[Qq]$ ]] && { echo "已退出"; exit 0; }

target_dev=""
if [[ "${choice:-}" =~ ^[Rr]$ ]]; then
  target_dev="eth0"
else
  [[ "${choice:-}" =~ ^[0-9]+$ ]] || die "输入无效"
  (( choice >= 0 && choice < ${#DEV_LIST[@]} )) || die "输入越界"
  target_dev="${DEV_LIST[$choice]}"
fi

target_ipv4_cidr="$(get_ipv4_cidr "$target_dev" || true)"
target_ipv4_ip="$(get_ipv4_ip "$target_ipv4_cidr" || true)"
[[ -n "${target_ipv4_ip:-}" ]] || die "网卡 $target_dev 没有 IPv4，无法设置默认路由"

target_gw="$(calc_gw_dot1 "$target_ipv4_ip")"
target_link_cidr="$(get_link_cidr "$target_dev" || true)"
[[ -z "$target_link_cidr" ]] && target_link_cidr="${target_ipv4_cidr:-N/A}"
target_region="$(get_region "$target_dev" "$target_link_cidr")"

echo
echo "${C_BOLD}即将设置默认路由：${C_RESET}"
echo "  dev    : ${C_GREEN}${target_dev}${C_RESET}"
echo "  ipv4   : ${C_GREEN}${target_ipv4_cidr}${C_RESET}"
echo "  gateway: ${C_GREEN}${target_gw}${C_RESET}"
echo "  region : ${C_GREEN}${target_region}${C_RESET}"
echo
read -r -p "确认执行？(y/N) " yn
yn="${yn:-N}"
[[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

backup="$(backup_default_routes)"
echo "${C_DIM}已备份当前 default 路由到：$backup${C_RESET}"

apply_default_route "$target_dev" "$target_gw"

echo
hr
echo "${C_BOLD}切换完成${C_RESET}"
echo "${C_DIM}运行后出口信息：$(show_egress_report)${C_RESET}"
echo "${C_DIM}当前 default 路由：${C_RESET}"
ip -4 route show default || true
hr
echo "${C_DIM}如需回滚：查看 $backup 并手工恢复其中的 default 路由${C_RESET}"
