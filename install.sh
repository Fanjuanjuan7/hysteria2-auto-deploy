#!/bin/bash

# === 配置项 ===
PASSWORD=$(openssl rand -base64 12)
PORTS=(12345 21234 30489 40112 51820) # 端口跳跃
OBFS_PASSWORD=$(openssl rand -base64 12)
CERT_DIR="/etc/hysteria"
CONFIG_FILE="/etc/hysteria/config.yaml"
CLIENT_CONFIG="/root/hysteria-client.yaml"
SHARE_LINK_FILE="/root/hysteria-share-link.txt"
SERVICE_NAME="hysteria-server"

# === 生成快捷命令 fff ===
create_shortcut() {
    echo 'fff() { bash /usr/local/bin/hysteria2-menu.sh; }' >> /root/.bashrc
    source /root/.bashrc
}

# === 生成菜单脚本 ===
create_menu_script() {
cat > /usr/local/bin/hysteria2-menu.sh <<'EOF'
#!/bin/bash

show_menu() {
    clear
    echo "=============================="
    echo " Hysteria2 管理菜单"
    echo "=============================="
    echo "1. 重新安装 Hysteria2"
    echo "2. 查看服务状态"
    echo "3. 显示分享链接"
    echo "4. 查看配置信息"
    echo "5. 卸载 Hysteria2"
    echo "6. 退出"
    echo "=============================="
}

while true; do
    show_menu
    read -p "请输入选项 (1-6): " choice
    case $choice in
        1)
            echo "🔄 正在重新安装 Hysteria2..."
            curl -sSL https://raw.githubusercontent.com/你的用户名/hysteria2-auto-deploy/main/install.sh | bash
            read -p "按回车继续..."
            ;;
        2)
            systemctl status hysteria-server
            read -p "按回车继续..."
            ;;
        3)
            cat /root/hysteria-share-link.txt
            read -p "按回车继续..."
            ;;
        4)
            cat /etc/hysteria/config.yaml
            read -p "按回车继续..."
            ;;
        5)
            echo "⚠️ 正在卸载 Hysteria2..."
            systemctl stop hysteria-server
            systemctl disable hysteria-server
            rm -f /usr/local/bin/hysteria
            rm -rf /etc/hysteria
            rm -f /etc/systemd/system/hysteria-server.service
            systemctl daemon-reload
            echo "✅ 卸载完成"
            read -p "按回车继续..."
            ;;
        6)
            exit 0
            ;;
        *)
            echo "❌ 无效选项，请重试"
            sleep 1
            ;;
    esac
done
EOF
chmod +x /usr/local/bin/hysteria2-menu.sh
}

# === 主部署逻辑 ===
deploy_hysteria2() {
    echo "🚀 开始部署 Hysteria2 + Nginx..."

    # 安装依赖
    apt update && apt install -y curl wget unzip openssl jq nginx

    # 下载 Hysteria2
    HYS_URL=$(curl -s https://api.github.com/repos/HyNetwork/hysteria/releases/latest | jq -r '.assets[] | select(.name | endswith("linux-amd64")) | .browser_download_url')
    wget -qO /tmp/hysteria.zip "$HYS_URL"
    unzip -o /tmp/hysteria.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/hysteria

    # 创建证书目录
    mkdir -p "$CERT_DIR"

    # 生成自签名证书（有效期 1 年）
    openssl req -x509 -newkey rsa:4096 \
      -keyout "$CERT_DIR/private.key" \
      -out "$CERT_DIR/cert.crt" \
      -days 365 \
      -nodes \
      -subj "/CN=localhost"

    # 创建 Hysteria2 配置文件
    cat > "$CONFIG_FILE" <<EOF
listen: :${PORTS[0]}@${PORTS[1]},${PORTS[2]},${PORTS[3]},${PORTS[4]}
tls:
  cert: $CERT_DIR/cert.crt
  key: $CERT_DIR/private.key

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $PASSWORD

heartbeat: 30s
timeout: 600s

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://maimai.sega.jp
    rewriteHost: true
EOF

    # 创建 systemd 服务
    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server --config $CONFIG_FILE
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" --now
    systemctl start "$SERVICE_NAME"

    # 放行本地防火墙
    for port in "${PORTS[@]}"; do ufw allow "$port/udp"; done

    # 配置 Nginx 反向代理
    cat > /etc/nginx/sites-available/hysteria2 <<EOF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/hysteria/cert.crt;
    ssl_certificate_key /etc/hysteria/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass https://127.0.0.1:${PORTS[0]};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/hysteria2 /etc/nginx/sites-enabled/
    systemctl restart nginx

    # 生成客户端配置
    SERVER_IP=$(curl -s ifconfig.me)

    # 生成分享链接（终端输出 + 文件保存）
    SHARE_LINK="hysteria2://$SERVER_IP:443@${PORTS[0]},${PORTS[1]},${PORTS[2]},${PORTS[3]},${PORTS[4]}?auth=$PASSWORD&obfs=salamander&obfsParam=$OBFS_PASSWORD&sni=localhost&insecure=true#Hysteria2_Node"

    echo "$SHARE_LINK" > "$SHARE_LINK_FILE"

    echo ""
    echo "🔗 分享链接已生成，你可以直接复制以下内容："
    echo "--------------------------------------------------"
    echo "$SHARE_LINK"
    echo "--------------------------------------------------"

    # 优化系统参数
    echo "net.core.rmem_max=67108864" >> /etc/sysctl.conf
    echo "net.core.wmem_max=67108864" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_rmem=4096 87380 67108864" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_wmem=4096 65536 67108864" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_mtu_probing=1" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p

    # 创建快捷命令和菜单
    create_shortcut
    create_menu_script

    echo ""
    echo "✅ 部署完成！"
    echo "📌 请在阿里云控制台放行以下 UDP 端口：${PORTS[@]}"
    echo "📌 你可以使用快捷命令 'fff' 进入管理菜单"
}

# === 启动部署 ===
deploy_hysteria2
