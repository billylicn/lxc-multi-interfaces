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
# 手动维护的网关地址
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
# 获取公网出口信息（已关闭国旗，增加ASN）
# ==============================
get_public_info() {
    local ip country city asn resp
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s --max-time 5 https://ipinfo.io/json)
        if [[ -n "$resp" ]]; then
            ip=$(echo "$resp" | grep -oP '"ip":\s*"\K[^"]+')
            country=$(echo "$resp" | grep -oP '"country":\s*"\K[^"]+')
            city=$(echo "$resp" | grep -oP '"city":\s*"\K[^"]+')
            # 提取 ASN (ipinfo 返回格式通常为 "ASxxxx Company Name")
            asn=$(echo "$resp" | grep -oP '"org":\s*"\K[^"]+')
        fi
    fi

    # 如果获取失败的保底处理
    ip=${ip:-"N/A"}
    country=${country:-"Unknown"}
    city=${city:-"Unknown"}
    asn=${asn:-"Unknown"}

    echo -e "${GREEN}🌐 出口: ${BOLD}${ip}${NC} ${country} / ${city} ASN:${asn}"
}

# ==============================
# 显示当前出口网卡和源 IP
# ==============================
show_current_route() {
    # 获取默认路由的网卡和源IP
    local route_info=$(ip route get 1.1.1.1 2>/dev/null)
    local dev=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    local src=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    
    echo -e "${BLUE}📡 当前网卡: ${BOLD}${dev:-?}${NC} (${src:-?})"
}

# ==============================
# 主程序
# ==============================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}⚠️  请使用 sudo 运行此脚本。${NC}"
    exit 1
fi

# 获取 eth 网卡列表
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

# 显示当前状态
echo -e "🚀 ${BOLD}当前网络状态：${NC}"
get_public_info
show_current_route
echo

# 构建菜单
echo -e "📋 请选择默认出口网卡：${NC}"
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

# 获取网关
gateway="${NIC_GATEWAY_MAP[$selected_nic]}"
if [[ -z "$gateway" ]]; then
    gateway=$(ip route show dev "$selected_nic" 2>/dev/null | grep -m1 'via' | awk '{print $3}' | head -n1)
fi

if [[ -z "$gateway" ]]; then
    echo -e "${RED}❌ 无法确定网关。${NC}"
    exit 1
fi

src_ip=$(ip addr show "$selected_nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)

# 切换路由
echo -e "${YELLOW}🔄 切换出口到 $selected_nic...${NC}"
if [[ -n "$src_ip" ]]; then
    ip route replace default via "$gateway" dev "$selected_nic" src "$src_ip"
else
    ip route replace default via "$gateway" dev "$selected_nic"
fi

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✅ 切换成功！${NC}\n"
    echo -e "🎯 ${BOLD}切换后状态：${NC}"
    get_public_info
    show_current_route
else
    echo -e "${RED}❌ 切换失败。${NC}"
fi
