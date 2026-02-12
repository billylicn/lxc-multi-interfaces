#!/bin/bash

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
echo -e "${CYAN}      多网卡自动配置与检测脚本 v1.0      ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 1. 获取用户输入
echo -e "${YELLOW}请输入 IP 最后一段的数字 (例如: 101):${NC}"
read -p "> " IP_SUFFIX

# 简单的数字检查
if ! [[ "$IP_SUFFIX" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}错误: 请输入有效的数字！${NC}"
    exit 1
fi

echo -e "${YELLOW}请输入要配置几个网卡 (1-4):${NC}"
echo -e "1: 仅配置 eth1 (10.99.0.X)"
echo -e "2: 配置 eth1-eth2 (向下包含 10.98.0.X)"
echo -e "3: 配置 eth1-eth3 (向下包含 10.97.0.X)"
echo -e "4: 配置 eth1-eth4 (向下包含 10.96.0.X)"
read -p "> " COUNT

if ! [[ "$COUNT" =~ ^[1-4]$ ]]; then
    echo -e "${RED}错误: 请输入 1 到 4 之间的数字！${NC}"
    exit 1
fi

echo -e "${CYAN}-----------------------------------------${NC}"
echo -e "${GREEN}开始配置网卡...${NC}"

# 2. 循环配置网卡
# 逻辑映射:
# i=1 -> eth1 -> 10.99.0.X
# i=2 -> eth2 -> 10.98.0.X
# i=3 -> eth3 -> 10.97.0.X
# i=4 -> eth4 -> 10.96.0.X

for ((i=1; i<=COUNT; i++)); do
    DEV="eth${i}"
    # 计算中间段：100 - i (1->99, 2->98, 3->97, 4->96)
    SECOND_OCTET=$((100 - i))
    IP_ADDR="10.${SECOND_OCTET}.0.${IP_SUFFIX}"
    
    echo -n "正在配置 ${DEV} ($IP_ADDR) ... "
    
    # 启动网卡
    ip link set "$DEV" up
    
    # 添加 IP (如果已存在会报错，重定向错误输出)
    # 先尝试删除旧的同网段 IP 以免冲突(可选，这里直接 add)
    ip addr add "${IP_ADDR}/24" dev "$DEV" 2>/dev/null
    
    if [ $? -eq 0 ] || [ $? -eq 2 ]; then # 0是成功，2是已存在
        echo -e "${GREEN}[完成]${NC}"
    else
        echo -e "${RED}[失败]${NC}"
    fi
done

echo -e "${CYAN}-----------------------------------------${NC}"
echo -e "${GREEN}开始连通性测试 (Ping 1.1.1.1)...${NC}"

# 3. 连通性测试 & 出口 IP 检测
for ((i=1; i<=COUNT; i++)); do
    DEV="eth${i}"
    SECOND_OCTET=$((100 - i))
    IP_ADDR="10.${SECOND_OCTET}.0.${IP_SUFFIX}"
    
    # Ping 测试
    if ping -c 1 -W 1 -I "$IP_ADDR" 1.1.1.1 > /dev/null 2>&1; then
        PING_STATUS="${GREEN}通${NC}"
    else
        PING_STATUS="${RED}不通${NC}"
    fi

    # 获取出口 IP (设置超时防止卡住)
    # 使用 myip.ipip.net 或者 ipinfo.io
    MY_IP=$(curl --interface "$IP_ADDR" -s --max-time 3 https://myip.ipip.net 2>/dev/null)
    # 清理一下输出中的换行符
    MY_IP=$(echo "$MY_IP" | tr -d '\n')
    
    if [ -z "$MY_IP" ]; then
        MY_IP="${RED}获取失败或超时${NC}"
    else
        MY_IP="${GREEN}${MY_IP}${NC}"
    fi

    echo -e "网卡: ${YELLOW}${DEV}${NC} | 内网IP: ${CYAN}${IP_ADDR}${NC} | Ping: ${PING_STATUS}"
    echo -e "   └── 出口信息: ${MY_IP}"
    echo ""
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}            网卡配置详情                 ${NC}"
echo -e "${CYAN}=========================================${NC}"

# 4. 输出 ip addr 详情
for ((i=1; i<=COUNT; i++)); do
    DEV="eth${i}"
    # 只显示该网卡的信息
    ip addr show "$DEV"
done

echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}配置脚本运行结束。${NC}"
