#!/bin/bash

# ================= 配置区域 =================
# 检测出口IP的超时时间(秒)
CURL_TIMEOUT=15
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
echo -e "${CYAN}      多网卡自动配置与检测脚本 v2.0      ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 1. 获取用户输入 IP 后缀
echo -e "${YELLOW}请输入 IP 最后一段的数字 (例如: 101):${NC}"
read -p "> " IP_SUFFIX

# 简单的数字检查
if ! [[ "$IP_SUFFIX" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误: 请输入有效的数字！${NC}"
    exit 1
fi

# 2. 获取网卡范围
echo -e "${YELLOW}请输入要配置的网卡范围 (格式如: 1-4 或 1-6):${NC}"
echo -e "例如输入 '1-4' 将配置 eth1 到 eth4"
read -p "> " RANGE_INPUT

# 解析范围输入 (例如 1-4)
if [[ "$RANGE_INPUT" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    START_NUM=${BASH_REMATCH[1]}
    END_NUM=${BASH_REMATCH[2]}
else
    # 如果用户只输入了一个数字，默认从1开始到该数字
    if [[ "$RANGE_INPUT" =~ ^[0-9]+$ ]]; then
        START_NUM=1
        END_NUM=$RANGE_INPUT
    else
        echo -e "${RED}错误: 格式不正确，请输入如 1-4${NC}"
        exit 1
    fi
fi

if [ "$START_NUM" -gt "$END_NUM" ]; then
    echo -e "${RED}错误: 起始数字不能大于结束数字！${NC}"
    exit 1
fi

echo -e "${CYAN}-----------------------------------------${NC}"
echo -e "${GREEN}即将配置 eth${START_NUM} 到 eth${END_NUM}，IP后缀 .${IP_SUFFIX}${NC}"
echo -e "${GREEN}正在执行配置...${NC}"

# 3. 循环配置网卡
for ((i=START_NUM; i<=END_NUM; i++)); do
    DEV="eth${i}"
    # 计算中间段：100 - i (eth1->99, eth4->96, eth6->94)
    SECOND_OCTET=$((100 - i))
    IP_ADDR="10.${SECOND_OCTET}.0.${IP_SUFFIX}"
    
    echo -n "正在配置 ${DEV} ($IP_ADDR) ... "
    
    # 启动网卡
    ip link set "$DEV" up
    
    # 添加 IP (忽略已存在的错误)
    ip addr add "${IP_ADDR}/24" dev "$DEV" 2>/dev/null
    
    # 简单的状态回显
    if [ $? -eq 0 ] || [ $? -eq 2 ]; then 
        echo -e "${GREEN}[完成]${NC}"
    else
        echo -e "${RED}[失败]${NC}"
    fi
done

echo -e "${CYAN}-----------------------------------------${NC}"
echo -e "${GREEN}开始连通性测试 (Ping 1.1.1.1) & 获取出口 IP...${NC}"
echo -e "${YELLOW}提示: 获取出口IP等待时间较长(${CURL_TIMEOUT}s)，请耐心等待...${NC}"
echo ""

# 4. 连通性测试 & 出口 IP 检测
for ((i=START_NUM; i<=END_NUM; i++)); do
    DEV="eth${i}"
    SECOND_OCTET=$((100 - i))
    IP_ADDR="10.${SECOND_OCTET}.0.${IP_SUFFIX}"
    
    # Ping 测试
    if ping -c 1 -W 1 -I "$IP_ADDR" 1.1.1.1 > /dev/null 2>&1; then
        PING_STATUS="${GREEN}通${NC}"
    else
        PING_STATUS="${RED}不通${NC}"
    fi

    # 获取出口 IP (超时时间设长一点)
    MY_IP=$(curl --interface "$IP_ADDR" -s --max-time $CURL_TIMEOUT https://myip.ipip.net 2>/dev/null)
    # 移除换行符
    MY_IP=$(echo "$MY_IP" | tr -d '\n')
    
    if [ -z "$MY_IP" ]; then
        MY_IP="${RED}获取失败(超时)${NC}"
    else
        MY_IP="${GREEN}${MY_IP}${NC}"
    fi

    # 打印单行结果
    echo -e "网卡: ${YELLOW}${DEV}${NC} | 内网: ${CYAN}${IP_ADDR}${NC} | Ping: ${PING_STATUS}"
    echo -e "   └── 出口: ${MY_IP}"
    echo ""
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}            网卡配置详情                 ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 5. 输出 ip addr 详情
for ((i=START_NUM; i<=END_NUM; i++)); do
    DEV="eth${i}"
    # 检查网卡是否存在，存在则显示信息
    if ip link show "$DEV" > /dev/null 2>&1; then
        ip addr show "$DEV"
    fi
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}脚本运行结束。${NC}"
