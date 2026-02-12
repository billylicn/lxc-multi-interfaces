#!/bin/bash

# 1. 获取所有以 eth 开头的网卡名称
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep '^eth')

if [ -z "$interfaces" ]; then
    echo "未找到以 eth 开头的网卡。"
else
    echo "检测到以下网卡: $interfaces"
    
    # 2. 循环激活每一个网卡
    for i in $interfaces; do
        echo "正在激活网卡: $i ..."
        sudo ip link set "$i" up
    done
fi

# 3. 修改 /etc/dhcp/dhclient.conf 设置 DNS
echo "正在配置 dhclient.conf DNS..."

# 检查文件是否存在
if [ -f "/etc/dhcp/dhclient.conf" ]; then
    # 使用用户提供的 sed 命令进行修改
    # 逻辑：取消注释 prepend domain-name-servers，并将其值改为 1.1.1.1, 8.8.8.8
    sudo sed -i '/^#prepend domain-name-servers/s/^#//; /^prepend domain-name-servers/c\prepend domain-name-servers 1.1.1.1, 8.8.8.8;' /etc/dhcp/dhclient.conf
    echo "DNS 配置已更新。"
else
    echo "错误: 未找到 /etc/dhcp/dhclient.conf 文件。"
fi

echo "任务完成。"
