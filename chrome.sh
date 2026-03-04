#!/bin/bash
# 部署 Chrome（TigerVNC + Gost SOCKS5 代理中转）

# ============================================================
# 环境变量加载
# ============================================================
load_env() {
	shopt -s dotglob
	for f in ./.env ./*.env ./*/*.env ./*/*/*.env; do
		[ -f "$f" ] && ENV_FILE="$f" && break
	done
	shopt -u dotglob
	if [ -n "$ENV_FILE" ]; then
		echo "Loading environment variables from: $ENV_FILE"
		while IFS='=' read -r key value || [ -n "$key" ]; do
			case "$key" in ''|\#*) continue ;; esac
			export "$key=$value"
		done < "$ENV_FILE"
	else
		echo "No .env file found"
	fi
}

echo_env_vars() {
	export ARGO_AUTH="${ARGO_AUTH:-''}"
	export CM_PASS="${CM_PASS:-Ww112211}"
	export CM_PORT="${CM_PORT:-9020}"
	[ -n "$ARGO_AUTH" ] && echo "  ARGO_AUTH=$ARGO_AUTH"
	[ -n "$CM_PORT" ]   && echo "  CM_PORT=$CM_PORT"
}

# ============================================================
# proot 环境初始化
# ============================================================
setgamehostproot() {
	mkdir -p /home/container/.tmp
	cd /home/container/.tmp
	source <(curl -LsS https://gbjs.serv00.net/sh/alpineproot322.sh)
}

# ============================================================
# Gost SOCKS5 代理中转
# ============================================================
run_gost_proxy() {
	local action="$1"

	if [ "$action" = "stop" ]; then
		if [ -f /tmp/gost.pid ]; then
			kill "$(cat /tmp/gost.pid)" 2>/dev/null && echo "✅ Gost 代理已停止"
			rm -f /tmp/gost.pid
		fi
		return 0
	fi

	if [ -z "$PROXY_IP" ] || [ -z "$PROXY_PORT" ] || \
	   [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASS" ]; then
		echo "=> 未提供完整代理变量，跳过代理中转。"
		return 0
	fi

	echo "=> 检测到代理配置，正在准备 Gost SOCKS5 中转..."

	local GOST_BIN=/tmp/gost
	local GOST_PORT="${PROXY_LOCAL_PORT:-1080}"

	if [ ! -x "$GOST_BIN" ]; then
		echo "   正在下载 Gost 二进制..."
		local ARCH GOST_URL
		ARCH=$(uname -m)
		case "$ARCH" in
			x86_64)  GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz" ;;
			aarch64) GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-armv8-2.11.5.gz" ;;
			*)
				echo "   ⚠️  不支持的架构 $ARCH，跳过。"
				return 1
				;;
		esac
		curl -Ls "$GOST_URL" | gunzip > "$GOST_BIN"
		chmod +x "$GOST_BIN"
	fi

	[ -f /tmp/gost.pid ] && kill "$(cat /tmp/gost.pid)" 2>/dev/null && rm -f /tmp/gost.pid

	nohup "$GOST_BIN" \
		-L "socks5://:${GOST_PORT}" \
		-F "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_IP}:${PROXY_PORT}" \
		> /tmp/gost.log 2>&1 &
	echo $! > /tmp/gost.pid

	sleep 1
	if kill -0 "$(cat /tmp/gost.pid)" 2>/dev/null; then
		echo -e "\033[32m✅ Gost SOCKS5 中转已就绪！监听端口：${GOST_PORT}\033[0m"
		echo "   协议: SOCKS5    地址: 127.0.0.1    端口: ${GOST_PORT}    密码: (留空)"
	else
		echo "⚠️  Gost 启动失败，请查看 /tmp/gost.log"
	fi
}

# ============================================================
# Cloudflare Tunnel
# ============================================================
runcftunnel() {
	[[ "$1" != "start" ]] && return 0
	[ -z "${ARGO_AUTH}" ] && load_env
	echo_env_vars
	cd /tmp
	curl -Ls https://gbjs.serv00.net/cftunnel.sh | bash
}

# ============================================================
# 主流程
# ============================================================
run_remote() {
	if [ -z "${PROOT_DIR}" ]; then
		source /home/container/.bashrc 2>/dev/null || true
	fi
	if [ -z "${PROOT_DIR}" ] || [ ! -d "${PROOT_DIR}" ]; then
		setgamehostproot
	fi

	if [ "$1" = "start" ]; then
		run_gost_proxy start
	else
		run_gost_proxy stop
	fi

	runcftunnel "$1"
	cd "${PROOT_DIR}"

	# 解析分辨率（用 cut 兼容 busybox sh，避免 Bad substitution）
	_VNC_RES="${VNC_RESOLUTION:-1920x1080}"
	_VNC_W=$(echo "$_VNC_RES" | cut -d'x' -f1)
	_VNC_H=$(echo "$_VNC_RES" | cut -d'x' -f2)
	_VNC_DEPTH="${VNC_DEPTH:-8}"
	_CM_PORT="${CM_PORT:-9020}"
	_CM_PASS="${CM_PASS:-}"

	# 写入内嵌脚本到 proot /root/
	INNER_SCRIPT_PATH="${PROOT_DIR}/rootfs/root/runchrome_runit.sh"

	cat > "$INNER_SCRIPT_PATH" << INNEREOF
#!/bin/sh
set -eu

MODE="\$1"
CM_PORT="${_CM_PORT}"
CM_PASS="${_CM_PASS}"
VNC_W="${_VNC_W}"
VNC_H="${_VNC_H}"
VNC_DEPTH="${_VNC_DEPTH}"
VNC_RESOLUTION="\${VNC_W}x\${VNC_H}"

generate_caddy_config() {
  [ -z "\$CM_PASS" ] && echo "CM_PASS not set" && return 1
  HASH=\$(caddy hash-password --plaintext "\$CM_PASS")
  [ -z "\$HASH" ] && echo "hash failed" && return 1
  rm -rf \$1/Caddyfile
  cat > \$1/Caddyfile << EOF
:\$CM_PORT {
  @protected {
    not path /websockify*
  }
  basicauth @protected {
    chromium \$HASH
  }
  root * \$1/novnc
  file_server
  handle_path /websockify* {
    reverse_proxy localhost:5902
  }
}
EOF
  echo "✅ Caddyfile 已生成，端口 \$CM_PORT，用户名 chromium"
}

enable_autoconnect() {
  local file="\${1:-index.html}"
  if command -v perl >/dev/null 2>&1; then
    perl -i -pe 's/.*defaults\["autoconnect"\].*//g; \$_ = "defaults[\"autoconnect\"] = true;\n" if \$. == 85;' "\$file" 2>/dev/null || true
  fi
}

start_services() {
  echo "🚀 启动 Chromium + TigerVNC + Openbox..."

  if ! command -v chromium-browser >/dev/null 2>&1; then
    apk update
    apk add --no-cache chromium git bash curl wget \
      font-noto-emoji font-noto-cjk ttf-dejavu \
      mesa mesa-gl mesa-egl libx11 libxext libxrender \
      tigervnc openbox xdotool xdpyinfo pciutils-dev st \
      websockify
    fc-cache -fv
  else
    echo "✅ 软件包已存在，跳过安装"
  fi

  [ -d ~/.config/openbox ] || mkdir -p ~/.config/openbox
  curl -LSs https://gbjs.serv00.net/tar/cm_menu.xml -o ~/.config/openbox/menu.xml 2>/dev/null || true

  # 启动 TigerVNC（色深8降低传输量，配合1920x1080不增加卡顿）
  export SERVICECMD="Xvnc :1 -geometry \${VNC_RESOLUTION} -depth \${VNC_DEPTH} -SecurityTypes None"
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s start

  export DISPLAY=:1
  for i in \$(seq 1 15); do
    if xdpyinfo -display :1 > /dev/null 2>&1; then
      echo "✅ Xvnc 已就绪，启动 Openbox..."
      break
    fi
    echo "⏳ 等待 Xvnc 初始化... (\${i}/15)"
    sleep 1
  done

  # 启动 Openbox
  export SERVICECMD="openbox"
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s add
  sed -i "1a export DISPLAY=:1" /etc/service/openbox/run

  # 启动 Chromium（无 GPU 容器优化参数）
  export SERVICECMD="chromium-browser \
    --no-sandbox \
    --start-maximized \
    --window-size=\${VNC_W},\${VNC_H} \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --disable-background-networking \
    --js-flags=--max-old-space-size=512"
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s add
  mkdir -p "\$PWD/.cache"
  sed -i "1a export TMPDIR=\$PWD/.cache" /etc/service/chromium-browser/run
  sed -i "1a export DISPLAY=:1" /etc/service/chromium-browser/run

  basedir=\$(pwd)

  # 下载 noVNC（已存在则跳过）
  if [ ! -d "./novnc" ]; then
    echo "📦 下载 noVNC..."
    if timeout 10s git clone --depth=1 https://github.com/novnc/noVNC.git ./novnc 2>/dev/null; then
      echo "✅ noVNC 克隆成功"
    else
      echo "⚠️ GitHub 超时，使用备用源..."
      wget -O noVNC.tar.gz https://gbjs.serv00.net/tar/noVNC-1.6.0.tar.gz
      mkdir -p novnc
      tar -xzf noVNC.tar.gz -C ./novnc --strip-components=1
      rm noVNC.tar.gz
    fi
  else
    echo "✅ noVNC 已存在，跳过下载"
  fi

  cd novnc || { echo "❌ 无法进入 novnc 目录"; exit 1; }
  if [ -f "vnc.html" ] && [ ! -f "index.html" ]; then
    mv vnc.html index.html
    enable_autoconnect index.html
  fi
  wwwdir=\$(pwd)

  if [ -z "\$CM_PASS" ]; then
    export SERVICECMD="websockify --web \${wwwdir} \${CM_PORT} localhost:5901"
    (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s add
    echo "✅ noVNC 已就绪，访问: http://0.0.0.0:\${CM_PORT}/index.html"
  else
    export SERVICECMD="websockify 5902 localhost:5901"
    (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s add
    apk add --no-cache caddy
    generate_caddy_config \$basedir
    export SERVICECMD="caddy run --config \${basedir}/Caddyfile"
    (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s add
    echo "✅ noVNC 已就绪，访问: http://0.0.0.0:\${CM_PORT}/index.html"
  fi
}

stop_services() {
  echo "🛑 停止所有服务..."
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s stop
  rm -rf /etc/service
  echo "✅ 所有进程已清理"
}

runit_status() {
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s list
}

case "\$MODE" in
  start)   start_services ;;
  stop)    stop_services ;;
  restart) stop_services; sleep 1; start_services ;;
  status)  runit_status ;;
  *) echo "用法: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
INNEREOF

	chmod +x "$INNER_SCRIPT_PATH"

	[ -e /tmp/cm_pipe ] && rm -f /tmp/cm_pipe
	mkfifo /tmp/cm_pipe

	# 后台启动 proot，完成后输出 __CHROME_DONE__ 信号
	PROOT_STARTED=1 nohup ./proot -S ./rootfs -b /proc -b /sys -w "$PROOT_DIR" --cwd=/root \
		-b /etc/resolv.conf:/etc/resolv.conf \
		-b "$PROOT_TMP_DIR/hosts":/etc/hosts /bin/sh -c "
		export PATH=/sbin:/bin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
		export HOME='/config'
		export TMPDIR='\$HOME/tmp'
		echo 'export HOME=\"/config\"' > /root/.bashrc
		echo 'export TMPDIR=\"/config/tmp\"' >> /root/.bashrc
		[ -d \$TMPDIR ] || mkdir -p \$TMPDIR
		[ -d \$HOME ]   || mkdir -p \$HOME
		command -v curl >/dev/null 2>&1 || apk add --no-cache curl bash
		sh /root/runchrome_runit.sh \"$1\" 2>&1
		echo '__CHROME_DONE__'
		" > /tmp/cm_pipe 2>&1 &

	# 读取输出直到收到完成信号，然后立即返回让 nanolimbo 继续
	echo "🔧 [Chrome] 正在初始化，等待服务就绪..."
	while IFS= read -r line; do
		echo "$line"
		echo "$line" >> /home/container/.tmp/alpine/cm.log 2>/dev/null || true
		[ "$line" = "__CHROME_DONE__" ] && break
	done < /tmp/cm_pipe

	rm -f /tmp/cm_pipe

	if [ "$1" = "start" ]; then
		echo "✅ Chrome 后台服务已就绪！"
		if [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ]; then
			local GOST_PORT="${PROXY_LOCAL_PORT:-1080}"
			echo "🛡  SOCKS5 代理: 127.0.0.1:${GOST_PORT}（无需密码）"
		fi
		echo "🌐 noVNC 访问端口: ${_CM_PORT}"
	fi
}

case "$1" in
	start)
		run_remote start
		;;
	stop)
		run_remote stop
		;;
	restart)
		run_remote stop
		sleep 2
		run_remote start
		;;
	status)
		run_remote status
		;;
	*)
		echo "用法: $0 {start|stop|restart|status}"
		echo "可选环境变量:"
		echo "  代理: PROXY_IP  PROXY_PORT  PROXY_USER  PROXY_PASS  PROXY_LOCAL_PORT(默认1080)"
		echo "  显示: VNC_RESOLUTION(默认1280x720)  VNC_DEPTH(默认16)"
		exit 1
		;;
esac
