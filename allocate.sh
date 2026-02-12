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
echo -e "${CYAN}      多网卡自动配置与检测脚本 v2.1      ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 1. 获取用户输入 IP 后缀 (双重确认)
while true; do
    echo -e "${YELLOW}请输入 IP 最后一段的数字 (从服务商获得，配置错误可能导致网络崩溃):${NC}"
    read -p "> " IP_SUFFIX
    
    # 简单的数字检查
    if ! [[ "$IP_SUFFIX" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误: 请输入有效的数字！${NC}"
        continue
    fi

    echo -e "${YELLOW}请再次输入以确认:${NC}"
    read -p "> " IP_SUFFIX_CONFIRM

    if [ "$IP_SUFFIX" == "$IP_SUFFIX_CONFIRM" ]; then
        break
    else
        echo -e "${RED}两次输入的数字不一致，请重新输入！${NC}\n"
    fi
done

# 2. 获取网卡范围
echo -e "${YELLOW}网卡范围 (从服务商获得，配置错误可能导致网络崩溃):${NC}"
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

# 3. 风险警告与确认
echo -e "${CYAN}-----------------------------------------${NC}"
echo -e "${RED}================= 警 告 =================${NC}"
echo -e "${RED}⚠即将配置 eth${START_NUM} 到 eth${END_NUM}，IP后缀 .${IP_SUFFIX}${NC}"
echo -e "${RED}仔细检查！如果IP配置错误，可能导致网络崩溃或连接中断！${NC}"
echo -e "${RED}=========================================${NC}"
echo -e "${YELLOW}确认继续吗？(输入 y 确认，其他键取消)${NC}"
read -p "> " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${RED}用户取消操作，脚本退出。${NC}"
    exit 1
fi

echo -e "${GREEN}正在执行配置...${NC}"

# 4. 循环配置网卡
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
    if [ $? -eq 0 ] || [ $? -eq 2 ]; then # 0=成功, 2=已存在
        echo -e "${GREEN}[完成]${NC}"
    else
        echo -e "${RED}[失败]${NC}"
    fi
done

echo -e "${CYAN}-----------------------------------------${NC}"
echo -e "${GREEN}开始连通性测试 (Ping 1.1.1.1) & 获取出口 IP...${NC}"
echo -e "${YELLOW}提示: 获取出口IP等待时间较长(${CURL_TIMEOUT}s)，请耐心等待...${NC}"
echo ""

# 5. 连通性测试 & 出口 IP 检测
# 只有配置成功的网卡才进行测试，避免无意义的等待
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

# 6. 输出 ip addr 详情
for ((i=START_NUM; i<=END_NUM; i++)); do
    DEV="eth${i}"
    # 检查网卡是否存在，存在则显示信息
    if ip link show "$DEV" > /dev/null 2>&1; then
        ip addr show "$DEV"
    fi
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}脚本运行结束。${NC}"
