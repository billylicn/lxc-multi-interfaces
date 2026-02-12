#!/bin/bash
# ================= 配置区域 =================
# 检测出口IP的超时时间(秒)
CURL_TIMEOUT=15
# 检测的目标网站 (显示归属地信息)
CHECK_URL="https://myip.ipip.net"
# ===========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 或 root 权限运行此脚本！${NC}"
  exit 1
fi

clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}      全网卡出口归属检测脚本 v3.0        ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 1. 自动获取所有 eth 开头的网卡并排序 (eth0, eth1, ... eth10)
# 使用 sort -V 进行自然数字排序
NET_INTERFACES=$(ls /sys/class/net/ | grep "^eth" | sort -V)

if [ -z "$NET_INTERFACES" ]; then
    echo -e "${RED}错误: 未找到任何以 'eth' 开头的网卡！${NC}"
    exit 1
fi

echo -e "${GREEN}发现以下网卡，开始检测...${NC}"
echo -e "${YELLOW}提示: 获取出口IP等待时间较长(${CURL_TIMEOUT}s)，请耐心等待...${NC}"
echo ""

# 2. 循环检查每一张网卡
for DEV in $NET_INTERFACES; do
    # 获取当前网卡绑定的第一个IPv4地址 (用于显示)
    # 格式清理：获取 inet 后面的地址，去掉掩码
    CURRENT_IP=$(ip -4 addr show dev "$DEV" 2>/dev/null | grep inet | awk '{print $2}' | head -n 1 | cut -d/ -f1)
    
    # 检查网卡是否启用或有IP
    if [ -z "$CURRENT_IP" ]; then
        echo -e "网卡: ${YELLOW}${DEV}${NC} | ${RED}跳过 (无IPv4地址或网卡未启动)${NC}"
        echo -e "${CYAN}-----------------------------------------${NC}"
        continue
    fi

    # Ping 测试 (使用网卡接口发送)
    if ping -c 1 -W 1 -I "$DEV" 1.1.1.1 > /dev/null 2>&1; then
        PING_STATUS="${GREEN}通${NC}"
    else
        PING_STATUS="${RED}不通${NC}"
    fi

    # 获取出口 IP
    # --interface 指定网卡名称，避免多IP时的歧义
    MY_IP_INFO=$(curl --interface "$DEV" -s --max-time $CURL_TIMEOUT "$CHECK_URL" 2>/dev/null)
    
    # 移除换行符，整理输出
    MY_IP_INFO=$(echo "$MY_IP_INFO" | tr -d '\n')

    if [ -z "$MY_IP_INFO" ]; then
        MY_IP_DISPLAY="${RED}获取失败(超时或网络不可达)${NC}"
    else
        # 这里的 MY_IP_INFO 通常包含 IP 和 地理位置信息 (myip.ipip.net 返回格式)
        MY_IP_DISPLAY="${GREEN}${MY_IP_INFO}${NC}"
    fi

    # 打印结果
    echo -e "网卡: ${YELLOW}${DEV}${NC} | 本机IP: ${CYAN}${CURRENT_IP}${NC} | Ping: ${PING_STATUS}"
    echo -e "   └── 出口信息: ${MY_IP_DISPLAY}"
    echo -e "${CYAN}-----------------------------------------${NC}"

done

echo -e "${GREEN}所有网卡检测结束。${NC}"
