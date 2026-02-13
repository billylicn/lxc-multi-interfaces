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
# 出口区域/用途名单
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
# 获取开机默认配置的网卡 (兼容 LXC/Debian)
# ==============================
get_boot_nic() {
    local boot_nic=""

    # 1. 检查 /etc/network/interfaces.d/ (LXC 常见)
    if [ -d "/etc/network/interfaces.d" ]; then
        boot_nic=$(grep -r "gateway" /etc/network/interfaces.d/ | head -n1 | grep -oP 'eth[0-9]+' | head -n1)
    fi

    # 2. 检查 /etc/network/interfaces
    if [[ -z "$boot_nic" && -f "/etc/network/interfaces" ]]; then
        boot_nic=$(grep -B 10 "gateway" "/etc/network/interfaces" | grep "iface" | awk '{print $2}' | tail -n 1)
    fi

    # 3. 检查 systemd-networkd (部分 LXC 模板)
    if [[ -z "$boot_nic" && -d "/etc/systemd/network" ]]; then
        boot_nic=$(grep -l "Gateway=" /etc/systemd/network/*.network 2>/dev/null | head -n1 | xargs grep -oP "Name=\K.*")
    fi

    # 4. 检查 nmcli
    if [[ -z "$boot_nic" ]] && command -v nmcli >/dev/null 2>&1; then
        boot_nic=$(nmcli -t -f IPV4.GATEWAY,DEVICE connection show | grep -v '^:' | cut -d':' -f2 | head -n1)
    fi

    echo "${boot_nic:-None}"
}

# ==============================
# 执行持久化配置 (兼容 LXC/Debian)
# ==============================
set_persistence_config() {
    local target_nic=$1
    local target_gw=$2
    
    echo -e "${YELLOW}💾 正在尝试写入持久化配置...${NC}"

    # 方案 A: 修改 /etc/network/interfaces.d/ 中的文件 (LXC 优先)
    if [ -d "/etc/network/interfaces.d" ]; then
        # 寻找包含网段配置的文件，通常是 eth0, setup, 或 50-cloud-init
        local target_file=$(grep -l "iface $target_nic" /etc/network/interfaces.d/* 2>/dev/null | head -n1)
        
        # 如果找不到特定文件，就尝试在 interfaces 中操作，或者新建一个
        if [ -z "$target_file" ] && [ -f "/etc/network/interfaces" ]; then
            target_file="/etc/network/interfaces"
        fi

        if [ -n "$target_file" ]; then
            cp "$target_file" "${target_file}.bak"
            # 删除原有的所有 gateway 行（跨文件清理比较难，这里只清理当前文件）
            sed -i '/gateway/d' /etc/network/interfaces.d/* 2>/dev/null
            [ -f "/etc/network/interfaces" ] && sed -i '/gateway/d' /etc/network/interfaces
            
            # 插入新网关
            sed -i "/iface $target_nic/a \    gateway $target_gw" "$target_file"
            echo -e "${GREEN}✅ 已更新 $target_file 并备份。${NC}"
            return 0
        fi
    fi

    # 方案 B: systemd-networkd
    if [ -d "/etc/systemd/network" ]; then
        local net_file=$(grep -l "Name=$target_nic" /etc/systemd/network/*.network 2>/dev/null | head -n1)
        if [ -n "$net_file" ]; then
            cp "$net_file" "${net_file}.bak"
            # 删除旧 Gateway，在 [Network] 部分添加新 Gateway
            sed -i '/Gateway=/d' /etc/systemd/network/*.network
            sed -i "/\[Network\]/a Gateway=$target_gw" "$net_file"
            echo -e "${GREEN}✅ 已更新 systemd-networkd 配置: $net_file${NC}"
            return 0
        fi
    fi

    echo -e "${RED}❌ 未能找到可自动修改的配置文件。${NC}"
    echo -e "请手动检查: ${BLUE}/etc/network/interfaces.d/${NC} 或 ${BLUE}/etc/systemd/network/${NC}"
    return 1
}

# ==============================
# 其他辅助功能
# ==============================
get_public_info() {
    local ip country city asn resp
    if command -v curl >/dev/null 2>&1; then
        resp=$(curl -s --max-time 5 https://ipinfo.io/json)
        if [[ -n "$resp" ]]; then
            ip=$(echo "$resp" | grep -oP '"ip":\s*"\K[^"]+')
            country=$(echo "$resp" | grep -oP '"country":\s*"\K[^"]+')
            city=$(echo "$resp" | grep -oP '"city":\s*"\K[^"]+')
            asn=$(echo "$resp" | grep -oP '"org":\s*"\K[^"]+')
        fi
    fi
    echo -e "${GREEN}🌐 出口: ${BOLD}${ip:-N/A}${NC} ${country:-?} / ${city:-?} ASN:${asn:-?}"
}

show_current_route() {
    local route_info=$(ip route get 1.1.1.1 2>/dev/null)
    local dev=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    local src=$(echo "$route_info" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
    echo -e "${BLUE}📡 当前网卡: ${BOLD}${dev:-?}${NC} (${src:-?})"
}

# ==============================
# 主逻辑
# ==============================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}⚠️  请使用 sudo 运行此脚本。${NC}"
    exit 1
fi

boot_nic=$(get_boot_nic)

declare -a nics=()
for n in /sys/class/net/eth*; do
    [[ -e "$n" ]] && nics+=("$(basename "$n")")
done
readarray -t nics < <(printf '%s\n' "${nics[@]}" | sort -V)

echo -e "🚀 ${BOLD}当前网络状态：${NC}"
get_public_info
show_current_route
echo -e "${CYAN}💾 开机默认网卡: ${BOLD}${boot_nic}${NC}"
echo

echo -e "📋 请选择默认出口网卡：${NC}"
for i in "${!nics[@]}"; do
    nic="${nics[$i]}"
    region="${NIC_REGION_MAP[$nic]:-未配置区域}"
    ip_local=$(ip addr show "$nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    marker=""
    [[ "$nic" == "$boot_nic" ]] && marker="${YELLOW} [开机预设]${NC}"
    printf "${GREEN}%2d)${NC} %-6s ${CYAN}[%-14s]${NC} → %s%s\n" \
           $((i+1)) "$nic" "${ip_local:-无IP}" "$region" "$marker"
done
echo -e "${YELLOW} r)${NC} 恢复默认出口到 eth0"
echo -e "${RED} q)${NC} 退出"
echo

read -rp "$(echo -e "${BOLD}请输入选项: ${NC}")" choice
case "$choice" in
    [0-9]*)
        idx=$((choice - 1))
        [[ $idx -ge 0 && $idx -lt ${#nics[@]} ]] && selected_nic="${nics[$idx]}" || { echo "无效选择"; exit 1; }
        ;;
    r|R) selected_nic="eth0" ;;
    q|Q) exit 0 ;;
    *) echo "无效输入"; exit 1 ;;
esac

gateway="${NIC_GATEWAY_MAP[$selected_nic]}"
[[ -z "$gateway" ]] && gateway=$(ip route show dev "$selected_nic" | grep -m1 'via' | awk '{print $3}')
[[ -z "$gateway" ]] && { echo "无法确定网关"; exit 1; }

echo -e "${YELLOW}🔄 正在即时切换出口到 $selected_nic...${NC}"
src_ip=$(ip addr show "$selected_nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
if [[ -n "$src_ip" ]]; then
    ip route replace default via "$gateway" dev "$selected_nic" src "$src_ip"
else
    ip route replace default via "$gateway" dev "$selected_nic"
fi

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✅ 临时切换成功！${NC}\n"
    get_public_info
    show_current_route
    echo
    
    if [[ "$selected_nic" != "$boot_nic" ]]; then
        read -rp "$(echo -e "${BOLD}❓ 是否要将 ${selected_nic} 设置为下次开机默认出口? (y/n): ${NC}")" save_choice
        if [[ "$save_choice" =~ ^[Yy]$ ]]; then
            set_persistence_config "$selected_nic" "$gateway"
        fi
    else
        echo -e "${BLUE}ℹ️ 该网卡已经是开机预设。${NC}"
    fi
else
    echo -e "${RED}❌ 切换失败。${NC}"
fi
