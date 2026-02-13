#!/usr/bin/env bash
set -euo pipefail

# =========================
# 内置出口区域名单（不外联）
# =========================
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

# =========================
# 公网 IP 查询（外联）
# =========================
IP_CHECK_URLS=(
  "https://api.ipify.org"
  "https://icanhazip.com"
  "https://ipinfo.io/ip"
  "https://ifconfig.me/ip"
)
IP_CHECK_TIMEOUT="${IP_CHECK_TIMEOUT:-4}"

# =========================
# 美化输出
# =========================
if command -v tput >/dev/null 2>&1; then
  B="$(tput bold)"; D="$(tput dim)"
  R="$(tput setaf 1)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; U="$(tput setaf 4)"
  Z="$(tput sgr0)"
else
  B=""; D=""; R=""; G=""; Y=""; U=""; Z=""
fi
hr() { printf '%*s\n' "${1:-100}" '' | tr ' ' '-'; }
die() { echo "${R}$*${Z}" >&2; exit 1; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请用 root 运行：sudo $0"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }

# 强制交互读输入：从 /dev/tty 读，避免 stdin 不是 tty 时直接 EOF
read_tty() {
  local prompt="$1"
  local varname="$2"
  if [[ -t 0 ]]; then
    read -r -p "$prompt" "$varname"
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt" "$varname" </dev/tty
  else
    die "当前环境无法交互输入（无 tty）。"
  fi
}

# =========================
# 网卡/路由信息
# =========================
get_eth_ifaces() {
  # grep 可能匹配不到导致非0；这里加 || true 避免 pipefail 直接退出
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | awk -F'@' '{print $1}' \
    | grep -E '^eth[0-9]+' || true
}

get_ipv4_cidr() { ip -o -4 addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -n1; }
get_ipv4_ip() { [[ -n "${1:-}" ]] && echo "${1%%/*}" || true; }
get_link_cidr() { ip -o -4 route show dev "$1" scope link 2>/dev/null | awk '{print $1}' | head -n1; }
calc_gw_dot1() { awk -F. '{print $1"."$2"."$3".1"}' <<<"$1"; }

get_region() {
  local dev="$1" cidr="$2"
  if [[ -n "${IFACE_REGION[$dev]+x}" ]]; then
    echo "${IFACE_REGION[$dev]}"
  elif [[ -n "${CIDR_REGION[$cidr]+x}" ]]; then
    echo "${CIDR_REGION[$cidr]}"
  else
    echo "未知区域"
  fi
}

get_route_guess() {
  local target="${1:-1.1.1.1}"
  local line
  line="$(ip -4 route get "$target" 2>/dev/null | head -n1 || true)"
  [[ -z "$line" ]] && { echo "dev=? via=? src=?"; return 0; }
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
    echo "N/A(need curl/wget)"; return 0
  fi
  echo "N/A"
}

show_egress_report() {
  echo "公网IP=$(get_public_ip) | 路由推断($(get_route_guess 1.1.1.1))"
}

backup_default_routes() {
  local f="/tmp/default_routes.backup.$(date +%F_%H%M%S).txt"
  ip -4 route show default >"$f" 2>/dev/null || true
  echo "$f"
}

apply_default_route() {
  local dev="$1" gw="$2"
  ip -4 route replace default via "$gw" dev "$dev"
}

# =========================
# 主程序
# =========================
need_root
need_cmd ip

echo "${B}默认出口网卡选择/切换工具${Z}"
hr
echo "${D}运行前出口信息：$(show_egress_report)${Z}"
echo "${D}当前 default 路由：${Z}"
ip -4 route show default || true
hr
echo

# 收集接口
mapfile -t ifaces < <(get_eth_ifaces | sort -V | uniq)
((${#ifaces[@]} > 0)) || die "未发现 eth* 网卡（当前命名空间可能只有 lo/或非 eth 命名）"

echo "${B}检测到 ${#ifaces[@]} 个 eth* 网卡：${Z}"
echo

# 构造菜单
declare -a DEV_LIST IP_LIST CIDR_LIST GW_LIST REGION_LIST
i=0
for dev in "${ifaces[@]}"; do
  ipv4_cidr="$(get_ipv4_cidr "$dev" || true)"
  ipv4_ip="$(get_ipv4_ip "$ipv4_cidr" || true)"
  link_cidr="$(get_link_cidr "$dev" || true)"
  [[ -z "$link_cidr" ]] && link_cidr="${ipv4_cidr:-N/A}"

  gw="N/A"
  [[ -n "$ipv4_ip" ]] && gw="$(calc_gw_dot1 "$ipv4_ip")"

  region="$(get_region "$dev" "$link_cidr")"

  DEV_LIST+=("$dev")
  IP_LIST+=("${ipv4_cidr:-N/A}")
  CIDR_LIST+=("$link_cidr")
  GW_LIST+=("$gw")
  REGION_LIST+=("$region")

  # 更直观的菜单显示
  printf "  %s) %-6s  ip=%-18s  gw=%-15s  cidr=%-18s  region=%s\n" \
    "$i" "$dev" "${ipv4_cidr:-N/A}" "$gw" "$link_cidr" "$region"
  ((i++))
done

echo
hr
echo "${B}请选择操作：${Z}"
echo "  ${Y}[0..$(( ${#DEV_LIST[@]}-1 ))]${Z}  切换默认出口到指定网卡"
echo "  ${Y}r${Z}           恢复默认出口到 eth0"
echo "  ${Y}q${Z}           退出"
hr

choice=""
read_tty "请输入选择（编号/r/q）： " choice

[[ "$choice" =~ ^[Qq]$ ]] && { echo "已退出"; exit 0; }

target_dev=""
if [[ "$choice" =~ ^[Rr]$ ]]; then
  target_dev="eth0"
else
  [[ "$choice" =~ ^[0-9]+$ ]] || die "输入无效：$choice"
  (( choice >= 0 && choice < ${#DEV_LIST[@]} )) || die "输入越界：$choice"
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
echo "${B}即将执行：${Z}"
echo "  default via ${G}${target_gw}${Z} dev ${G}${target_dev}${Z}"
echo "  说明：ipv4=${target_ipv4_cidr}  region=${target_region}"
echo
yn=""
read_tty "确认执行？(y/N) " yn
yn="${yn:-N}"
[[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

backup="$(backup_default_routes)"
echo "${D}已备份当前 default 路由到：$backup${Z}"

apply_default_route "$target_dev" "$target_gw"

echo
hr
echo "${B}切换完成${Z}"
echo "${D}运行后出口信息：$(show_egress_report)${Z}"
echo "${D}当前 default 路由：${Z}"
ip -4 route show default || true
hr
echo "${D}如需回滚：查看备份文件 $backup${Z}"
