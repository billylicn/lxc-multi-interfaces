#!/bin/bash

# ==============================
# 颜色定义（使用 $'...' 确保转义生效）
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
# 出口区域/用途名单（硬编码）
# ==============================
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

# ==============================
# 手动维护的网关地址（关键！）
# 格式: ["网卡名"]="网关IP"
# ==============================
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
# 获取公网出口信息（精简版）
# ==============================
get_public_info() {
    local ip country city loc
    if command -v curl >/dev/null 2>&1; then
        local resp=$(curl -s --max-time 5 https://ipinfo.io/json)
        ip=$(echo "$resp" | grep -oP '"ip":\s*"\K[^"]+')
        country=$(echo "$resp" | grep -oP '"country":\s*"\K[^"]+' || echo "??")
        city=$(echo "$resp" | grep -oP '"city":\s*"\K[^"]+' || echo "")
        # 国家 emoji 映射（可选）
        case "$country" in
            "HK") country="🇭🇰 HK" ;;
            "CN") country="🇨🇳 CN" ;;
            "MO") country="🇲🇴 MO" ;;
            "DE") country="🇩🇪 DE" ;;
            "TW") country="🇹🇼 TW" ;;
            *) country="$country" ;;
        esac
        loc="$country${city:+ / $city}"
    else
        ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")
        loc="—"
    fi
    echo -e "${GREEN}🌐 出口: ${BOLD}${ip}${NC} ${loc}"
}

# ==============================
# 显示当前出口网卡和源 IP
# ==============================
show_current_route() {
    dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    src=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    echo -e "${BLUE}📡 当前出口: ${BOLD}${dev:-?}${NC} (${src:-?})"
}

# ==============================
# 主程序
# ==============================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}⚠️  请使用 sudo 运行此脚本。${NC}"
    exit 1
fi

# 获取 eth 网卡列表（去重）
declare -a nics=()
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    clean_name=$(echo "$line" | cut -d'@' -f1)
    if [[ "$clean_name" =~ ^eth[0-9]+ ]]; then
        nics+=("$clean_name")
    fi
done < <(ls /sys/class/net/ 2>/dev/null)

readarray -t nics < <(printf '%s\n' "${nics[@]}" | sort -u)

if [[ ${#nics[@]} -eq 0 ]]; then
    echo -e "${RED}❌ 未找到 eth 网卡。${NC}"
    exit 1
fi

# ==============================
# 显示当前状态
# ==============================
echo -e "==============================${NC}"
echo -e "🚀 当前出口${NC}"
echo -e "==============================${NC}"
get_public_info
show_current_route
echo

# ==============================
# 构建菜单
# ==============================
echo -e "==============================${NC}"
echo -e "📋 请选择默认出口网卡：${NC}"
echo -e "==============================${NC}"

for i in "${!nics[@]}"; do
    nic="${nics[$i]}"
    region="${NIC_REGION_MAP[$nic]:-未配置区域}"
    ip_local=$(ip addr show "$nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    ip_display=${ip_local:-"无IP"}
    marker=""
    [[ "$nic" == "eth0" ]] && marker=" ${YELLOW}(默认)${NC}"
    printf "${GREEN}%2d)${NC} %-6s ${CYAN}[%-14s]${NC} → %s%s\n" \
           $((i+1)) "$nic" "$ip_display" "$region" "$marker"
done

echo -e "${YELLOW} r)${NC} 恢复默认出口到 eth0"
echo -e "${RED} q)${NC} 退出"
echo

read -rp "$(echo -e "${BOLD}请输入选项: ${NC}")" choice

case "$choice" in
    [0-9]*)
        idx=$((choice - 1))
        if [[ $idx -ge 0 && $idx -lt ${#nics[@]} ]]; then
            selected_nic="${nics[$idx]}"
        else
            echo -e "${RED}❌ 无效选项。${NC}"
            exit 1
        fi
        ;;
    r|R)
        selected_nic="eth0"
        if ! ip link show "$selected_nic" &>/dev/null; then
            echo -e "${RED}❌ eth0 不存在。${NC}"
            exit 1
        fi
        ;;
    q|Q)
        echo -e "${GREEN}👋 退出。${NC}"
        exit 0
        ;;
    *)
        echo -e "${RED}❌ 无效输入。${NC}"
        exit 1
        ;;
esac

# ==============================
# 获取网关（优先使用手动配置）
# ==============================
gateway="${NIC_GATEWAY_MAP[$selected_nic]}"
if [[ -z "$gateway" ]]; then
    # Fallback: 尝试自动探测
    gateway=$(ip route show dev "$selected_nic" 2>/dev/null | grep -m1 'via' | awk '{print $3}' | head -n1)
fi

if [[ -z "$gateway" ]]; then
    echo -e "${RED}❌ 未配置且无法探测到网关。请在脚本中 NIC_GATEWAY_MAP 添加 [$selected_nic] 的网关。${NC}"
    exit 1
fi

# 获取源 IP（用于保持连接稳定性）
src_ip=$(ip addr show "$selected_nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
if [[ -z "$src_ip" ]]; then
    echo -e "${YELLOW}⚠️  未找到 $selected_nic 的 IP，将不指定 src。${NC}"
fi

# ==============================
# 切换默认路由
# ==============================
echo -e "${YELLOW}🔄 切换默认出口到 ${BOLD}$selected_nic${NC}${YELLOW} (网关: $gateway)...${NC}"

if [[ -n "$src_ip" ]]; then
    ip route replace default via "$gateway" dev "$selected_nic" src "$src_ip"
else
    ip route replace default via "$gateway" dev "$selected_nic"
fi

if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ 路由设置失败！${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 切换成功！${NC}"
echo

# ==============================
# 显示切换后状态
# ==============================
echo -e "==============================${NC}"
echo -e "🎯 切换后出口${NC}"
echo -e "==============================${NC}"
get_public_info
show_current_route
echo -e "\n${GREEN}✅ 操作完成。${NC}"
