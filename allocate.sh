#!/bin/bash

# ================= 配置区域 =================
# 检测出口IP的超时时间(秒)
CURL_TIMEOUT=10
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

# 检查 dhclient 是否安装
if ! command -v dhclient &> /dev/null; then
    echo -e "${RED}错误: 未找到 dhclient 命令。${NC}"
    echo -e "${YELLOW}请尝试安装: apt install isc-dhcp-client (Debian/Ubuntu) 或 yum install dhclient (CentOS)${NC}"
    exit 1
fi

clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}    所有网卡 DHCP 自动刷新脚本 v3.0      ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 获取所有以 eth 开头的网卡名称
ETH_LIST=$(ls /sys/class/net/ | grep "^eth" | sort -V)

if [ -z "$ETH_LIST" ]; then
    echo -e "${RED}错误: 未找到任何 eth 开头的网卡！${NC}"
    exit 1
fi

echo -e "${GREEN}检测到以下网卡: ${YELLOW}$(echo $ETH_LIST | tr '\n' ' ')${NC}"
echo -e "${CYAN}-----------------------------------------${NC}"

for IFACE in $ETH_LIST; do
    echo -e "${YELLOW}正在处理网卡: ${IFACE} ...${NC}"
    
    # 1. 释放旧租约 (Release)
    echo -n "   └── 正在释放旧 IP... "
    dhclient -r "$IFACE" >/dev/null 2>&1
    echo -e "${GREEN}[完成]${NC}"
    
    # 2. 确保网卡是 UP 状态
    ip link set "$IFACE" up
    
    # 3. 获取新 IP (Renew)
    echo -n "   └── 正在请求新 IP (DHCP)... "
    # 使用 timeout 防止 dhclient 卡死
    timeout 15s dhclient "$IFACE" >/dev/null 2>&1
    RET_VAL=$?
    
    if [ $RET_VAL -eq 0 ]; then
        echo -e "${GREEN}[获取成功]${NC}"
    else
        echo -e "${RED}[获取失败]${NC}"
        continue # 如果获取 IP 失败，跳过后续检测
    fi
    
    # 4. 获取本机分配到的内网 IP
    LOCAL_IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    
    # 5. 检测连通性 & 出口 IP
    echo -n "   └── 正在检测出口连通性... "
    
    if ping -c 1 -W 1 -I "$IFACE" 1.1.1.1 > /dev/null 2>&1; then
        PING_STATUS="${GREEN}通${NC}"
    else
        PING_STATUS="${RED}不通${NC}"
    fi
    
    MY_IP=$(curl --interface "$IFACE" -s --max-time $CURL_TIMEOUT https://myip.ipip.net 2>/dev/null)
    MY_IP=$(echo "$MY_IP" | tr -d '\n') # 去除换行
    
    if [ -z "$MY_IP" ]; then
        MY_IP="${RED}获取出口IP超时${NC}"
    else
        MY_IP="${GREEN}${MY_IP}${NC}"
    fi
    
    echo -e "\n   👉 网卡: ${CYAN}${IFACE}${NC} | 内网: ${YELLOW}${LOCAL_IP}${NC} | Ping: ${PING_STATUS}"
    echo -e "      出口信息: ${MY_IP}\n"
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}所有网卡刷新完毕。${NC}"
