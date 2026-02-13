#!/bin/bash

# ==============================
# 出口区域/用途名单（硬编码）
# 格式: "ethX:区域名称"
# ==============================
declare -A NIC_REGION_MAP=(
    ["eth0"]="主线路 - 中国大陆"
    ["eth1"]="备用线路 - 香港"
    ["eth2"]="测试线路 - 美国"
    ["eth3"]="专线 - 新加坡"
    # 可根据实际需求扩展
)

# ==============================
# 辅助函数：获取公网出口 IP 和地区
# ==============================
get_public_info() {
    echo "正在获取公网出口信息..."
    local ip=""
    local loc=""

    # 尝试多个免费服务，优先使用 ipinfo.io（含地区）
    if command -v curl >/dev/null 2>&1; then
        # 使用 ipinfo.io 获取 IP + 地区（免费 tier 足够）
        response=$(curl -s --max-time 5 https://ipinfo.io/json)
        ip=$(echo "$response" | grep -oP '"ip":\s*"\K[^"]+')
        loc=$(echo "$response" | grep -oP '"country":\s*"\K[^"]+' || echo "未知")
        city=$(echo "$response" | grep -oP '"city":\s*"\K[^"]+' || echo "")
        region=$(echo "$response" | grep -oP '"region":\s*"\K[^"]+' || echo "")
        if [[ -n "$city" && -n "$region" ]]; then
            loc="$loc ($region, $city)"
        fi
    elif command -v wget >/dev/null 2>&1; then
        response=$(wget -qO- --timeout=5 https://ipinfo.io/json)
        ip=$(echo "$response" | grep -oP '"ip":\s*"\K[^"]+')
        loc=$(echo "$response" | grep -oP '"country":\s*"\K[^"]+' || echo "未知")
    else
        echo "错误：需要 curl 或 wget 来获取公网 IP。"
        return 1
    fi

    if [[ -z "$ip" ]]; then
        # 回退到纯 IP 服务
        ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || wget -qO- --timeout=5 https://icanhazip.com 2>/dev/null | tr -d ' \t\n\r')
        loc="（仅IP，无法获取地区）"
    fi

    echo "🌐 公网出口 IP: $ip"
    echo "📍 出口地区: $loc"
}

# ==============================
# 辅助函数：显示当前路由路径（用于核对）
# ==============================
show_current_route() {
    echo "📡 当前路由路径 (ip route get 1.1.1.1):"
    ip route get 1.1.1.1 2>/dev/null | head -n1
}

# ==============================
# 主逻辑开始
# ==============================

# 检查是否为 root（修改路由需要权限）
if [[ $EUID -ne 0 ]]; then
    echo "⚠️  此脚本需要 root 权限来修改默认路由。请使用 sudo 运行。"
    exit 1
fi

# 获取所有以 eth 开头的网卡（去重并标准化名称）
declare -a nics=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        # 处理 eth0@if50 → eth0
        clean_name=$(echo "$line" | cut -d'@' -f1)
        if [[ "$clean_name" =~ ^eth[0-9]+ ]]; then
            nics+=("$clean_name")
        fi
    fi
done < <(ls /sys/class/net/ 2>/dev/null)

# 去重
readarray -t nics < <(printf '%s\n' "${nics[@]}" | sort -u)

if [[ ${#nics[@]} -eq 0 ]]; then
    echo "❌ 未找到任何以 'eth' 开头的网卡。"
    exit 1
fi

# 显示初始出口信息
echo "=============================="
echo "🚀 当前出口信息（切换前）"
echo "=============================="
get_public_info
show_current_route
echo

# 构建菜单
echo "=============================="
echo "请选择要设为默认出口的网卡："
echo "=============================="
for i in "${!nics[@]}"; do
    nic="${nics[$i]}"
    region="${NIC_REGION_MAP[$nic]:-未配置区域}"
    # 获取该网卡的 IP（用于辅助识别）
    ip_local=$(ip addr show "$nic" 2>/dev/null | grep -w 'inet' | awk '{print $2}' | cut -d'/' -f1 | head -n1)
    ip_display=${ip_local:-"无IP"}
    printf "%2d) %-10s [%-15s] → %s\n" $((i+1)) "$nic" "$ip_display" "$region"
done
echo " r) 恢复默认出口到 eth0"
echo " q) 退出"
echo

# 获取用户输入
read -rp "请输入选项: " choice

# 处理输入
case "$choice" in
    [0-9]*)
        idx=$((choice - 1))
        if [[ $idx -ge 0 && $idx -lt ${#nics[@]} ]]; then
            selected_nic="${nics[$idx]}"
        else
            echo "❌ 无效选项。"
            exit 1
        fi
        ;;
    r|R)
        selected_nic="eth0"
        if ! ip link show "$selected_nic" &>/dev/null; then
            echo "❌ 网卡 eth0 不存在，无法恢复。"
            exit 1
        fi
        ;;
    q|Q)
        echo "👋 退出。"
        exit 0
        ;;
    *)
        echo "❌ 无效输入。"
        exit 1
        ;;
esac

# 获取所选网卡的网关和源 IP（用于设置默认路由）
gateway=$(ip route show dev "$selected_nic" | grep -m1 '^default' | awk '{print $3}')
src_ip=$(ip route get 1.1.1.1 oif "$selected_nic" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)

if [[ -z "$gateway" ]]; then
    # 尝试从非 default 路由推断网关（常见于 DHCP）
    gateway=$(ip route show dev "$selected_nic" | grep -m1 'via' | awk '{print $3}')
fi

if [[ -z "$gateway" ]]; then
    echo "❌ 无法自动获取网关地址（请确保该网卡已配置路由）。"
    echo "💡 提示：可手动添加如 'ip route add default via <GATEWAY> dev $selected_nic'"
    exit 1
fi

# 执行路由切换
echo "🔄 正在将默认出口切换到 $selected_nic (网关: $gateway) ..."
if [[ -n "$src_ip" ]]; then
    ip route replace default via "$gateway" dev "$selected_nic" src "$src_ip"
else
    ip route replace default via "$gateway" dev "$selected_nic"
fi

if [[ $? -ne 0 ]]; then
    echo "❌ 路由设置失败。"
    exit 1
fi

echo "✅ 默认路由已更新！"
echo

# 显示切换后的出口信息
echo "=============================="
echo "🎯 切换后出口信息"
echo "=============================="
get_public_info
show_current_route
echo "✅ 操作完成。"
