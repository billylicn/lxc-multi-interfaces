#!/bin/bash

# ==============================
# 颜色定义
# ==============================
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ==============================
# 配置区域
# ==============================
SERVICE_FILE="/etc/systemd/system/force-default-route.service"

declare -A NIC_REGION_MAP=(
    ["eth0"]="机房出口"
    ["eth1"]="香港HKT家宽100"
    ["eth2"]="家宽解锁机"
    ["eth3"]="澳门Mtel家宽"
    ["eth4"]="朝鲜"
    ["eth5"]="德国原生"
    ["eth6"]="香港HKT家宽"
    ["eth7"]="台湾HINAT家宽"
    ["eth8"]="香港CMHK家宽"
)

declare -A NIC_GATEWAY_MAP=(
    ["eth0"]="10.129.17.1"
    ["eth1"]="10.99.0.1"
    ["eth2"]="10.98.0.1"
    ["eth3"]="10.97.0.1"
    ["eth4"]="10.96.0.1"
    ["eth5"]="10.95.0.1"
    ["eth6"]="10.94.0.1"
    ["eth7"]="10.93.0.1"
    ["eth8"]="10.92.0.1"
)

# ==============================
# 核心功能：设置开机自启 (Systemd 方案)
# ==============================
enable_boot_persistence() {
    local target_nic=$1
    local target_gw=$2
    local target_src=$3

    echo -e "${YELLOW}💾 正在创建 Systemd 开机服务...${NC}"

    # 写入服务文件
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Force Custom Default Route for $target_nic
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# 核心命令：强制替换默认路由
ExecStart=/sbin/ip route replace default via $target_gw dev $target_nic src $target_src
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # 启用服务
    systemctl daemon-reload
    systemctl enable force-default-route.service >/dev/null 2>&1
    
    # 验证文件是否存在
    if [[ -f "$SERVICE_FILE" ]]; then
        echo -e "${GREEN}✅ 开机任务已设置！系统重启后将强制走 $target_nic${NC}"
        echo -e "📄 配置文件路径: ${CYAN}$SERVICE_FILE${NC}"
    else
        echo -e "${RED}❌ 服务文件创建失败，请检查文件系统权限。${NC}"
    fi
}

# ==============================
# 获取当前开机配置
# ==============================
get_boot_nic() {
    if [[ -f "$SERVICE_FILE" ]]; then
        # 从服务文件中提取设备名
        local nic=$(grep -oP 'dev \Keth[0-9]+' "$SERVICE_FILE" | head -n1)
        echo "${nic:-None}"
    else
        echo "未配置(默认)"
    fi
}

# ==============================
# 辅助信息显示
# ==============================
get_public_info() {
    local ip country city asn resp
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s --max-time 3 https://ipinfo.io/json)
        if [[ -n "$resp" ]]; then
            ip=$(echo "$resp" | grep -oP '"ip":\s*"\K[^"]+')
            country=$(echo "$resp" | grep -oP '"country":\s*"\K[^"]+')
            asn=$(echo "$resp" | grep -oP '"org":\s*"\K[^"]+')
        fi
    fi
    echo -e "${GREEN}🌐 公网: ${BOLD}${ip:-N/A}${NC} ${country:-?} ${asn:-?}"
}

show_current_route() {
    local route_info=$(ip route get 1.1.1.1 2>/dev/null)
    local dev=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    local src=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    echo -e "${BLUE}📡 当前: ${BOLD}${dev:-?}${NC} (${src:-?})"
}

# ==============================
# 主程序
# ==============================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}⚠️  请使用 sudo 运行此脚本。${NC}"
    exit 1
fi

# 检查环境
boot_nic=$(get_boot_nic)

# 获取网卡
declare -a nics=()
for n in /sys/class/net/eth*; do
    [[ -e "$n" ]] && nics+=("$(basename "$n")")
done
readarray -t nics < <(printf '%s\n' "${nics[@]}" | sort -V)

# 界面显示
echo -e "🚀 ${BOLD}网络出口切换工具 (LXC Systemd 版)${NC}"
get_public_info
show_current_route
echo -e "${CYAN}💾 开机预设: ${BOLD}${boot_nic}${NC}"
echo

echo -e "📋 可用出口网卡："
for i in "${!nics[@]}"; do
    nic="${nics[$i]}"
    region="${NIC_REGION_MAP[$nic]:-未配置区域}"
    ip_local=$(ip addr show "$nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    
    marker=""
    [[ "$nic" == "$boot_nic" ]] && marker="${YELLOW} [开机预设]${NC}"
    
    printf "${GREEN}%2d)${NC} %-6s ${CYAN}[%-14s]${NC} → %s%s\n" \
           $((i+1)) "$nic" "${ip_local:-无IP}" "$region" "$marker"
done
echo -e "${YELLOW} r)${NC} 清除开机强制路由 (恢复系统默认)"
echo -e "${RED} q)${NC} 退出"
echo

read -rp "$(echo -e "${BOLD}请选择: ${NC}")" choice

# 逻辑处理
selected_nic=""
case "$choice" in
    [0-9]*)
        idx=$((choice - 1))
        [[ $idx -ge 0 && $idx -lt ${#nics[@]} ]] && selected_nic="${nics[$idx]}"
        ;;
    r|R)
        echo -e "${YELLOW}🗑️  正在移除开机强制服务...${NC}"
        systemctl disable --now force-default-route.service 2>/dev/null
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}✅ 已恢复系统默认路由行为。${NC}"
        # 尝试恢复默认路由（通常是 eth0，这里简单重启网络或手动指回 eth0）
        echo -e "提示: 请手动重启网络或执行重启以生效默认策略。"
        exit 0
        ;;
    q|Q) exit 0 ;;
    *) echo "无效输入"; exit 1 ;;
esac

if [[ -z "$selected_nic" ]]; then
    echo "无效选择"; exit 1
fi

# 获取网关和IP
gateway="${NIC_GATEWAY_MAP[$selected_nic]}"
if [[ -z "$gateway" ]]; then
    gateway=$(ip route show dev "$selected_nic" | grep -m1 'via' | awk '{print $3}')
fi
src_ip=$(ip addr show "$selected_nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)

if [[ -z "$gateway" || -z "$src_ip" ]]; then
    echo -e "${RED}❌ 错误: 无法获取 $selected_nic 的网关或IP地址。${NC}"
    exit 1
fi

# 1. 立即切换 (当前会话生效)
echo -e "${YELLOW}🔄 正在即时切换出口到 $selected_nic...${NC}"
ip route replace default via "$gateway" dev "$selected_nic" src "$src_ip"

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✅ 即时切换成功！${NC}\n"
    get_public_info
    
    # 2. 询问持久化
    if [[ "$selected_nic" != "$boot_nic" ]]; then
        echo
        read -rp "$(echo -e "${BOLD}❓ 是否要设置 ${selected_nic} 为开机默认出口? (y/n): ${NC}")" save_choice
        if [[ "$save_choice" =~ ^[Yy]$ ]]; then
            enable_boot_persistence "$selected_nic" "$gateway" "$src_ip"
        fi
    else
        echo -e "${BLUE}ℹ️ 该网卡已经是开机预设。${NC}"
    fi
else
    echo -e "${RED}❌ 切换失败，请检查网络配置。${NC}"
fi
