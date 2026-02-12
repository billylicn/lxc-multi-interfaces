#!/bin/bash

# ================= 配置区域 =================
# 检测出口IP的超时时间(秒) - 已增加时长
CURL_TIMEOUT=10
# Curl 重试次数
CURL_RETRY=2
# 检测的目标网站
CHECK_URL="https://myip.ipip.net"
# ===========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GREY='\033[0;90m'
NC='\033[0m' # No Color

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 或 root 权限运行此脚本！${NC}"
  exit 1
fi

clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}      全网卡出口归属深度检测 v3.1        ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 1. 自动获取所有 eth 开头的网卡并排序
NET_INTERFACES=$(ls /sys/class/net/ | grep "^eth" | sort -V)

if [ -z "$NET_INTERFACES" ]; then
    echo -e "${RED}错误: 未找到任何以 'eth' 开头的网卡！${NC}"
    exit 1
fi

echo -e "${GREEN}发现网卡列表: $(echo $NET_INTERFACES | tr '\n' ' ')${NC}"
echo -e "${YELLOW}提示: 超时时间已设为 ${CURL_TIMEOUT}秒，如网络卡顿请耐心等待...${NC}"
echo ""

# 2. 循环检查每一张网卡
for DEV in $NET_INTERFACES; do
    echo -e "${CYAN}正在检测 ${DEV} ...${NC}"

    # --- 阶段一：检查网卡物理/管理状态 ---
    # 获取网卡标志位，检查是否包含 UP (管理状态开启)
    LINK_FLAGS=$(ip link show "$DEV" | head -n 1)
    
    # 检查 <...> 中是否有 UP。 注意：LOWER_UP 代表物理连线，UP 代表管理员开启
    if [[ "$LINK_FLAGS" != *"<"*UP*">"* ]]; then
        echo -e "网卡: ${YELLOW}${DEV}${NC} | 状态: ${RED}网卡未启动 (DOWN)${NC}"
        echo -e "   └── 原因: 网卡被禁用 (需执行 ip link set $DEV up)"
        echo -e "${GREY}-----------------------------------------${NC}"
        continue
    fi

    # --- 阶段二：检查 IP 地址配置 ---
    # 获取 IPv4 地址
    CURRENT_IP=$(ip -4 addr show dev "$DEV" 2>/dev/null | grep inet | awk '{print $2}' | head -n 1 | cut -d/ -f1)

    if [ -z "$CURRENT_IP" ]; then
        echo -e "网卡: ${YELLOW}${DEV}${NC} | 状态: ${RED}无 IPv4 地址${NC}"
        echo -e "   └── 原因: 网卡已启动，但未配置 IP 地址"
        echo -e "${GREY}-----------------------------------------${NC}"
        continue
    fi

    # --- 阶段三：连通性与出口检测 ---
    
    # 3.1 Ping 测试 (快速检测网关/路由是否通)
    if ping -c 1 -W 2 -I "$DEV" 1.1.1.1 > /dev/null 2>&1; then
        PING_STATUS="${GREEN}通${NC}"
        IS_CONNECTED=true
    else
        PING_STATUS="${RED}不通${NC}"
        IS_CONNECTED=false
    fi

    # 3.2 获取出口 IP (仅当 Ping 不通时可能直接失败，但我们尝试强制获取以防禁Ping)
    # 使用 --connect-timeout 限制连接时间，--max-time 限制总时间
    MY_IP_INFO=$(curl --interface "$DEV" -s --connect-timeout 10 --max-time $CURL_TIMEOUT --retry $CURL_RETRY "$CHECK_URL" 2>/dev/null)
    # 移除换行符
    MY_IP_INFO=$(echo "$MY_IP_INFO" | tr -d '\n')

    # 结果分析
    if [ -n "$MY_IP_INFO" ]; then
        # 成功获取到内容
        EXIT_INFO="${GREEN}${MY_IP_INFO}${NC}"
    else
        # 获取失败，根据 Ping 状态给出推断
        if [ "$IS_CONNECTED" = true ]; then
            EXIT_INFO="${RED}获取超时 (网络通但API无响应)${NC}"
        else
            EXIT_INFO="${RED}无法联网 (路由故障或IP不可用)${NC}"
        fi
    fi

    # --- 输出最终结果 ---
    echo -e "网卡: ${YELLOW}${DEV}${NC} | 本机IP: ${CYAN}${CURRENT_IP}${NC} | Ping: ${PING_STATUS}"
    echo -e "   └── 出口: ${EXIT_INFO}"
    echo -e "${GREY}-----------------------------------------${NC}"

done

echo -e "${GREEN}所有网卡检测结束。${NC}"
