#!/bin/bash

echo "========================================"
echo "        多出口网卡自动配置脚本"
echo "========================================"
echo ""

# 询问IP最后一段
read -p "请输入IP最后一段数字 (例如 100): " IP_LAST

# 询问配置几个出口
read -p "请输入要配置几个出口 (1-4): " COUNT

if [[ $COUNT -lt 1 || $COUNT -gt 4 ]]; then
    echo "出口数量必须是 1-4"
    exit 1
fi

# 定义网段数组
SUBNETS=("10.99.0" "10.98.0" "10.97.0" "10.96.0")
ETHS=("eth1" "eth2" "eth3" "eth4")

echo ""
echo "开始配置网卡..."
echo ""

for ((i=0;i<$COUNT;i++))
do
    subnet=${SUBNETS[$i]}
    eth=${ETHS[$i]}
    ip="$subnet.$IP_LAST"

    echo "正在配置 $eth -> $ip"

    sudo ip link set $eth up
    sudo ip addr flush dev $eth
    sudo ip addr add $ip/24 dev $eth

done

echo ""
echo "========================================"
echo "开始检测连通性"
echo "========================================"
echo ""

for ((i=0;i<$COUNT;i++))
do
    subnet=${SUBNETS[$i]}
    eth=${ETHS[$i]}
    ip="$subnet.$IP_LAST"

    echo -e "\n[$eth] 本地IP: $ip"
    
    ping -I $ip -c 2 1.1.1.1 > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "✅ Ping 正常"
    else
        echo "❌ Ping 失败"
    fi

    echo "🌍 出口IP:"
    curl --interface $ip -s https://myip.ipip.net
done

echo ""
echo "========================================"
echo "        所有配置完成"
echo "========================================"
