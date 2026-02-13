#!/bin/bash

# 定义 systemd 服务文件路径
SERVICE_FILE="/etc/systemd/system/dhclient-startup.service"

echo "=== 检查开机启动状态 ==="
if [ -f "$SERVICE_FILE" ]; then
    echo "状态: dhclient [已配置] 开机启动。"
else
    echo "状态: dhclient [未配置] 开机启动。"
fi

# 询问用户是否继续
read -p "是否开始运行脚本逻辑？(y/n): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "操作已取消，退出脚本。"
    exit 0
fi

echo "--------------------------------"

# 1. 获取所有以 eth 开头的网卡（去除 @ifXX 后缀）
interfaces=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep '^eth')
if [ -z "$interfaces" ]; then
    echo "未找到以 eth 开头的网卡。"
    exit 1
else
    echo "检测到以下网卡: $interfaces"
fi

# 2. 配置 dhclient.conf：强制使用 1.1.1.1 和 8.8.8.8 作为 DNS
DHCLIENT_CONF="/etc/dhcp/dhclient.conf"
echo "正在配置 $DHCLIENT_CONF 以固定 DNS 为 1.1.1.1 和 8.8.8.8..."

# 备份原配置（如果存在且未备份过）
if [ -f "$DHCLIENT_CONF" ] && [ ! -f "${DHCLIENT_CONF}.bak" ]; then
    sudo cp "$DHCLIENT_CONF" "${DHCLIENT_CONF}.bak"
fi

# 构建新的 dhclient.conf 内容
{
    echo "# 配置由自动化脚本生成"
    echo "option rfc3442-classless-static-routes code 121 = array of unsigned integer 8;"
    echo ""
    # 为每个 eth 接口设置 supersede DNS
    for iface in $interfaces; do
        echo "interface \"$iface\" {"
        echo "    supersede domain-name-servers 1.1.1.1, 8.8.8.8;"
        echo "}"
    done
} | sudo tee "$DHCLIENT_CONF" > /dev/null

echo "dhclient DNS 配置已更新。"

# 3. 激活所有 eth 网卡
for i in $interfaces; do
    echo "正在激活网卡: $i ..."
    sudo ip link set "$i" up 2>/dev/null
done

# 4. 运行 dhclient 获取 IP（现在会使用我们指定的 DNS）
echo "正在执行 dhclient 获取 IP..."
sudo dhclient -v $interfaces 2>&1 | grep -E "(bound|renew|DNS)" || true

# 5. 手动覆盖 /etc/resolv.conf（确保立即生效，即使 dhclient 有延迟）
echo "正在配置 /etc/resolv.conf DNS..."
sudo bash -c 'cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF'
echo "DNS 配置已更新为 1.1.1.1 和 8.8.8.8。"

# 6. 配置开机自启服务（如果不存在）
if [ ! -f "$SERVICE_FILE" ]; then
    echo "正在配置 dhclient 开机自启..."
    sudo bash -c "cat > $SERVICE_FILE << EOF
[Unit]
Description=Run dhclient on startup
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/dhclient $interfaces
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
echo "注意：DNS 已通过 dhclient.conf 固化，并手动写入 /etc/resolv.conf。"
