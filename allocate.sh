#!/bin/bash

# ================= 配置区域 =================
# 请求超时时间(秒) - 设长一点以防网络波动
CURL_TIMEOUT=20
# 检测目标
CHECK_URL="https://myip.ipip.net"
# ===========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GREY='\033[0;90m'
NC='\033[0m'

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 或 root 权限运行！${NC}"
  exit 1
fi

clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}   多网卡出口检测 (指定源IP模式) v3.2    ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 1. 获取所有 eth 网卡
NET_INTERFACES=$(ls /sys/class/net/ | grep "^eth" | sort -V)

if [ -z "$NET_INTERFACES" ]; then
    echo -e "${RED}未找到 eth 开头的网卡${NC}"
    exit 1
fi

echo -e "${GREEN}检测列表: $(echo $NET_INTERFACES | tr '\n' ' ')${NC}"
echo -e "${YELLOW}提示: 使用源IP进行 Curl 测试，超时时间 ${CURL_TIMEOUT}s...${NC}"
echo ""

# 2. 循环检测
for DEV in $NET_INTERFACES; do
    
    # --- 步骤1：获取该网卡的 IPv4 地址 ---
    # 提取 inet 后面的第一个 IP，去掉掩码
    CURRENT_IP=$(ip -4 addr show dev "$DEV" 2>/dev/null | grep inet | awk '{print $2}' | head -n 1 | cut -d/ -f1)

    # --- 步骤2：判断状态 (分层级报错) ---
    
    # 情况 A: 根本没有获取到 IP
    if [ -z "$CURRENT_IP" ]; then
        # 进一步检查是“网卡没开(DOWN)”还是“开了但没配IP”
        LINK_STATE=$(ip link show "$DEV" | head -n 1)
        
        if [[ "$LINK_STATE" == *"<"*UP*">"* ]]; then
             # 网卡是 UP 的，但是没有 inet 信息
             STATUS_MSG="${RED}网卡已启动，但未配置IP${NC}"
        else
             # 网卡标志里没有 UP
             STATUS_MSG="${RED}网卡未启动 (DOWN状态)${NC}"
        fi
        
        echo -e "网卡: ${YELLOW}${DEV}${NC} | 状态: ${STATUS_MSG}"
        echo -e "${GREY}-----------------------------------------${NC}"
        continue
    fi

    # --- 步骤3：有 IP 了，开始测试连通性 ---
    
    # 3.1 Ping 测试 (用源IP Ping)
    if ping -c 1 -W 1 -I "$CURRENT_IP" 1.1.1.1 > /dev/null 2>&1; then
        PING_STATUS="${GREEN}通${NC}"
    else
        PING_STATUS="${RED}不通${NC}"
    fi

    # 3.2 Curl 测试 (核心修改：使用 --interface IP地址)
    # 这里的 "$CURRENT_IP" 就是例如 10.99.0.101
    MY_IP_INFO=$(curl --interface "$CURRENT_IP" -s --connect-timeout 5 --max-time $CURL_TIMEOUT "$CHECK_URL" 2>/dev/null)
    # 去除换行
    MY_IP_INFO=$(echo "$MY_IP_INFO" | tr -d '\n')

    if [ -n "$MY_IP_INFO" ]; then
        EXIT_INFO="${GREEN}${MY_IP_INFO}${NC}"
    else
        # Curl 失败，判断原因
        EXIT_INFO="${RED}连接失败 (超时或路由不可达)${NC}"
    fi

    # --- 输出结果 ---
    echo -e "网卡: ${YELLOW}${DEV}${NC} | 指定源IP: ${CYAN}${CURRENT_IP}${NC} | Ping: ${PING_STATUS}"
    echo -e "   └── 出口: ${EXIT_INFO}"
    echo -e "${GREY}-----------------------------------------${NC}"

done

echo -e "${GREEN}检测完成。${NC}"
