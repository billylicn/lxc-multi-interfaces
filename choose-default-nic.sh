#!/bin/bash

# ==============================
# 颜色定义（兼容不支持颜色的终端）
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
# 获取公网 IP 和简化地区信息
# ==============================
get_public_info() {
    local ip country city
    if command -v curl >/dev/null 2>&1; then
        local resp=$(curl -s --max-time 5 https://ipinfo.io/json)
        ip=$(echo "$resp" | grep -oP '"ip":\s*"\K[^"]+')
        country=$(echo "$resp" | grep -oP '"country":\s*"\K[^"]+' || echo "??")
        city=$(echo "$resp" | grep -oP '"city":\s*"\K[^"]+' || echo "")
        [[ "$country" == "HK" ]] && country="🇭🇰 HK"
        [[ "$country" == "CN" ]] && country="🇨🇳 CN"
        [[ "$country" == "DE" ]] && country="🇩🇪 DE"
        # 可继续添加 emoji 国家码
        loc="$country${city:+ / $city}"
    else
        ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "N/A")
        loc="—"
    fi
    echo -e "${GREEN}🌐 出口: ${BOLD}${ip}${NC} ${loc}"
}

# ==============================
# 显示当前路由（极简）
# ==============================
show_current_route() {
    dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    src=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    echo -e "${BLUE}📡 当前出口网卡: ${BOLD}${dev:-?}${NC} (${src:-?})"
}

# ==============================
# 主程序开始
# ==============================

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}⚠️  此脚本需要 root 权限来修改默认路由。请使用 sudo 运行。${NC}"
    exit 1
fi

# 获取并清理 eth 网卡列表
declare -a nics=()
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    clean_name=$(echo "$line" | cut -d'@' -f1)
    if [[ "$clean_name" =~ ^eth[0-9]+ ]]; then
        nics+=("$clean_name")
    fi
done < <(ls /sys/class/net/ 2>/dev/null)

# 去重
readarray -t nics < <(printf '%s\n' "${nics[@]}" | sort -u)

if [[ ${#nics[@]} -eq 0 ]]; then
    echo -e "${RED}❌ 未找到任何以 'eth' 开头的网卡。${NC}"
    exit 1
fi

# ==============================
# 显示初始状态
# ==============================
echo -e "${BOLD}${GREEN}==============================${NC}"
echo -e "${BOLD}${GREEN}🚀 当前出口信息（切换前）${NC}"
echo -e "${BOLD}${GREEN}==============================${NC}"
get_public_info
show_current_route
echo

# ==============================
# 构建彩色菜单
# ==============================
echo -e "${BOLD}${BLUE}==============================${NC}"
echo -e "${BOLD}${BLUE}📋 请选择要设为默认出口的网卡：${NC}"
echo -e "${BOLD}${BLUE}==============================${NC}"

for i in "${!nics[@]}"; do
    nic="${nics[$i]}"
    region="${NIC_REGION_MAP[$nic]:-未配置区域}"
    ip_local=$(ip addr show "$nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    ip_display=${ip_local:-"无IP"}

    # 标记 eth0 为默认
    marker=""
    [[ "$nic" == "eth0" ]] && marker=" ${YELLOW}(默认)${NC}"

    printf "${GREEN}%2d)${NC} %-10s ${CYAN}[%-15s]${NC} → %s%s\n" \
           $((i+1)) "$nic" "$ip_display" "$region" "$marker"
done

echo -e "${YELLOW} r)${NC} 恢复默认出口到 eth0"
echo -e "${RED} q)${NC} 退出"
echo

# ==============================
# 用户输入处理
# ==============================
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
            echo -e "${RED}❌ 网卡 eth0 不存在，无法恢复。${NC}"
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
# 获取网关和源 IP
# ==============================
echo -e "${CYAN}🔍 正在分析网卡 $selected_nic 的路由信息...${NC}"

gateway=$(ip route show dev "$selected_nic" 2>/dev/null | grep -m1 '^default' | awk '{print $3}')
if [[ -z "$gateway" ]]; then
    gateway=$(ip route show dev "$selected_nic" 2>/dev/null | grep -m1 'via' | awk '{print $3}')
fi

src_ip=$(ip route get 1.1.1.1 oif "$selected_nic" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)

if [[ -z "$gateway" ]]; then
    echo -e "${RED}❌ 无法获取网关地址。请确保该网卡已正确配置网络。${NC}"
    echo -e "${YELLOW}💡 提示：可手动添加路由，例如：${NC}"
    echo "   ip route add default via <GATEWAY> dev $selected_nic"
    exit 1
fi

# ==============================
# 执行路由切换
# ==============================
echo -e "${YELLOW}🔄 正在将默认出口切换到 ${BOLD}$selected_nic${NC}${YELLOW} (网关: $gateway)...${NC}"

if [[ -n "$src_ip" ]]; then
    ip route replace default via "$gateway" dev "$selected_nic" src "$src_ip"
else
    ip route replace default via "$gateway" dev "$selected_nic"
fi

if [[ $? -ne 0 ]]; then
    echo -e "${RED}❌ 路由设置失败！${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 默认路由已成功更新！${NC}"
echo

# ==============================
# 显示切换后状态
# ==============================
echo -e "${BOLD}${GREEN}==============================${NC}"
echo -e "${BOLD}${GREEN}🎯 切换后出口信息${NC}"
echo -e "${BOLD}${GREEN}==============================${NC}"
get_public_info
show_current_route

echo -e "\n${GREEN}✅ 操作完成！当前默认出口已切换至 ${BOLD}$selected_nic${NC}${GREEN}。${NC}"
