#!/bin/bash

# 定义 systemd 服务文件路径，用于实现开机启动
SERVICE_FILE="/etc/systemd/system/dhclient-startup.service"

echo "=== 检查开机启动状态 ==="
if [ -f "$SERVICE_FILE" ]; then
    echo "状态: dhclient [已配置] 开机启动。"
else
    echo "状态: dhclient [未配置] 开机启动。"
fi

# 询问用户是否开始运行
read -p "是否开始运行脚本逻辑？(y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "操作已取消，退出脚本。"
    exit 0
fi

echo "--------------------------------"

# 1. 获取所有以 eth 开头的网卡名称，并去掉 @ifXX 后缀
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep '^eth')

if [ -z "$interfaces" ]; then
    echo "未找到以 eth 开头的网卡。"
else
    echo "检测到以下网卡: $interfaces"
    # 2. 循环激活每一个网卡
    for i in $interfaces; do
        echo "正在激活网卡: $i ..."
        sudo ip link set "$i" up 2>/dev/null
    done
fi

# 3. 运行 dhclient 获取 IP
echo "正在执行 dhclient 获取 IP..."
sudo dhclient

# 4. 修改 /etc/resolv.conf 设置 DNS
echo "正在配置 /etc/resolv.conf DNS..."
# 使用 tee 重写文件，确保 1.1.1.1 和 8.8.8.8 在最前面
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF'
echo "DNS 配置已更新为 1.1.1.1 和 8.8.8.8。"

# 5. 配置 sudo dhclient 开机启动 (使用 systemd)
if [ ! -f "$SERVICE_FILE" ]; then
    echo "正在配置 dhclient 开机自启..."
    sudo bash -c "cat > $SERVICE_FILE << EOF
[Unit]
Description=Run dhclient on startup
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/dhclient
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF"
    sudo systemctl daemon-reload
    sudo systemctl enable dhclient-startup.service
    echo "已创建并启用 dhclient 开机启动服务。"
else
    echo "开机启动服务已存在，跳过配置。"
fi

echo "--------------------------------"
echo "任务完成。"
