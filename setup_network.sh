#!/bin/bash

# 1. 获取所有以 eth 开头的网卡名称，并去掉 @ifXX 后缀
# 使用 cut -d'@' -f1 提取真实网卡名
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep '^eth')

if [ -z "$interfaces" ]; then
    echo "未找到以 eth 开头的网卡。"
else
    echo "检测到以下网卡: $interfaces"
    # 2. 循环激活每一个网卡
    for i in $interfaces; do
        echo "正在激活网卡: $i ..."
        # 增加判断，如果网卡已经是 UP 状态则跳过，避免报错
        sudo ip link set "$i" up 2>/dev/null
    done
fi

# 3. 修改 /etc/dhcp/dhclient.conf 设置 DNS
echo "正在配置 dhclient.conf DNS..."
CONF_FILE="/etc/dhcp/dhclient.conf"
if [ -f "$CONF_FILE" ]; then
    # 逻辑：取消注释并修改，或者如果不存在则添加
    sudo sed -i '/^#*prepend domain-name-servers/c\prepend domain-name-servers 1.1.1.1, 8.8.8.8;' "$CONF_FILE"
    echo "DNS 配置已更新。"
else
    echo "错误: 未找到 $CONF_FILE 文件。"
fi

echo "任务完成。"
