#!/usr/bin/env bash

echo -e "\n=== 多网卡出口自动配置脚本 ===\n"

read -p "请输入ipv4最后一段数字: " start_last_octet
if ! [[ "$start_last_octet" =~ ^[0-9]+$ ]] || [ "$start_last_octet" -lt 2 ] || [ "$start_last_octet" -gt 254 ]; then
    echo "错误：请输入 2~254 之间的整数"
    exit 1
fi

read -p "你要连续配置几个网卡？(例如 4 就配置 eth1~eth4): " count
if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt 1 ] || [ "$count" -gt 20 ]; then
    echo "请输入 1~20 之间的合理数字"
    exit 1
fi

echo -e "\n你输入的信息："
echo "  起始最后一段：$start_last_octet"
echo "  要配置的数量：$count 个网卡"
echo -e "  将从 eth1 开始，依次向下递减第三段 (99,98,97...)\n"

read -p "确认无误？按 Enter 继续，Ctrl+C 取消："

echo -e "\n# === 生成的配置命令（复制粘贴执行） ===\n"

# 先生成所有 up + addr add 命令
for ((i=1; i<=count; i++)); do
    eth="eth$i"
    third_octet=$((99 - i + 1))          # eth1=99, eth2=98, eth3=97, eth4=96 ...
    ip_last=$((start_last_octet + i - 1))
    ip="10.$third_octet.0.$ip_last"

    echo "sudo ip link set $eth up"
    echo "sudo ip addr add ${ip}/24 dev $eth"
    echo ""
done

echo "# 如果你还需要 .101 .102 ... 的第二组IP，可手动再加："
echo "# sudo ip addr add 10.99.0.$((start_last_octet+1))/24 dev eth1"
echo "# 以此类推..."

echo -e "\n# === 测试连通性（建议全部 ping 通再继续） ===\n"

for ((i=1; i<=count; i++)); do
    third_octet=$((99 - i + 1))
    ip_last=$((start_last_octet + i - 1))
    ip="10.$third_octet.0.$ip_last"
    echo "ping -I $ip 1.1.1.1 -c 3"
done

echo -e "\n# === 查看每个出口真实IP（最重要！） ===\n"

for ((i=1; i<=count; i++)); do
    third_octet=$((99 - i + 1))
    ip_last=$((start_last_octet + i - 1))
    ip="10.$third_octet.0.$ip_last"
    echo "curl --interface $ip https://myip.ipip.net"
done

echo -e "\n# === 给 x-ui / v2ray / xray 等面板「发送通过」要填的 IP 列表 ===\n"

echo "请依次在面板中新建出口，并填入以下本地 IP（发送通过）："
for ((i=1; i<=count; i++)); do
    third_octet=$((99 - i + 1))
    ip_last=$((start_last_octet + i - 1))
    echo "  10.$third_octet.0.$ip_last"
done

echo -e "\n完成！如果全部 curl 都能显示对应地区的 IP，说明配置成功。\n"
