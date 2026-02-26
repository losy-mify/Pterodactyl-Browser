#!/bin/bash
ACTION=$1

# 接收基础环境变量，提供默认值保底 (默认对外端口 9010)
PORT=${CM_PORT:-9010}
PASS=${CM_PASS:-'Ww112211'}

if [ "$ACTION" == "start" ]; then
    echo "=> 1. 正在清理旧环境并创建专用网络..."
    docker rm -f chrome chrome-argo socks5-bridge 2>/dev/null
    docker network create chrome-net 2>/dev/null

    # 判断是否传入了代理信息，如果有，则启动 SOCKS5 中转
    if [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ] && [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
        echo "=> 2. 检测到代理配置，正在启动 Gost SOCKS5 中转..."
        docker run -d \
          --name socks5-bridge \
          --network chrome-net \
          --restart unless-stopped \
          -p 1080:1080 \
          ginuerzh/gost \
          -L=socks5://:1080 -F=socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_IP}:${PROXY_PORT}
        echo -e "\033[32m[成功] 无密码代理桥接已就绪！\033[0m"
    else
        echo "=> 2. 未提供完整代理变量(PROXY_IP/PORT/USER/PASS)，跳过代理中转部署。"
    fi

    echo "=> 3. 正在启动 Chromium 容器..."
    docker run -d \
      --name chrome \
      --network chrome-net \
      --restart unless-stopped \
      --security-opt seccomp=unconfined \
      -p $PORT:3000 \
      -e PUID=1000 \
      -e PGID=1000 \
      -e TZ=Asia/Shanghai \
      -e LANG=zh_CN.UTF-8 \
      -e CUSTOM_USER=chrome \
      -e PASSWORD="$PASS" \
      -v $(pwd)/home/vncuser_data:/config \
      --shm-size="2gb" \
      lscr.io/linuxserver/chromium:latest

    if [ -n "$ARGO_AUTH" ]; then
        echo "=> 4. 检测到 ARGO_AUTH，正在启动 Cloudflare Tunnel..."
        docker run -d \
          --name chrome-argo \
          --network chrome-net \
          --restart unless-stopped \
          cloudflare/cloudflared:latest \
          tunnel --no-autoupdate run --token "$ARGO_AUTH"
        
        echo -e "\033[32m[成功] Cloudflare Tunnel 已在后台运行！\033[0m"
    else
        echo "=> 4. 未提供 ARGO_AUTH，跳过 Cloudflare 穿透。"
    fi

    echo "======================================"
    echo " 🚀 部署完成！"
    echo " 👤 访问账号: chrome"
    echo " 🔑 访问密码: $PASS"
    echo " 🌐 宿主端口: $PORT"
    if [ -n "$PROXY_IP" ]; then
        echo " 🛡️ 代理配置: 请在 FoxyProxy 中选 SOCKS5"
        echo "    👉 IP地址填: socks5-bridge"
        echo "    👉 端口填: 1080"
        echo "    👉 密码: (留空不填)"
    fi
    echo "======================================"

elif [ "$ACTION" == "stop" ]; then
    echo "=> 正在停止并清理所有相关容器及网络..."
    docker rm -f chrome chrome-argo socks5-bridge 2>/dev/null
    docker network rm chrome-net 2>/dev/null
    echo -e "\033[32m[成功] 清理完成。\033[0m"
else
    echo "用法: PROXY_USER=x PROXY_PASS=x PROXY_IP=x PROXY_PORT=x ARGO_AUTH=x CM_PASS=x CM_PORT=x bash <(curl -Ls URL) start | stop"
fi
