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

	_VNC_RES="${VNC_RESOLUTION:-1920x1080}"
	_VNC_W=$(echo "$_VNC_RES" | cut -d'x' -f1)
	_VNC_H=$(echo "$_VNC_RES" | cut -d'x' -f2)
	_VNC_DEPTH="${VNC_DEPTH:-16}"
	_CM_PORT="${CM_PORT:-9020}"
	_CM_PASS="${CM_PASS:-}"

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

# 照搬参考脚本的 generate_caddy_config，原样不动
generate_caddy_config() {
  if [ -z "\$CM_PASS" ]; then
    echo "❌ 环境变量 CM_PASS 未设置"
    return 1
  fi
  PORT="\${CM_PORT:-8081}"
  HASH=\$(caddy hash-password --plaintext "\$CM_PASS")
  if [ -z "\$HASH" ]; then
    echo "❌ 密码加密失败"
    return 1
  fi
  rm -rf \$1/Caddyfile
  cat <<EOF > \$1/Caddyfile
:\$PORT {
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
  echo "✅ Caddyfile 已生成，端口 \$PORT，用户名 chromium"
}

# 照搬参考脚本的 enable_autoconnect，原样不动
enable_autoconnect() {
  local file="\${1:-index.html}"
  if command -v perl >/dev/null 2>&1; then
    perl -i -pe '\$_ = "" if /defaults\["autoconnect"\]/ && \$. != 85;
                 \$_ = "defaults[\"autoconnect\"] = true;\n" if \$. == 85;' "\$file"
  elif command -v grep >/dev/null 2>&1 && command -v sed >/dev/null 2>&1; then
    grep -q '\''defaults\["autoconnect"\]'\'' "\$file" || \
      sed -i '\''85i defaults["autoconnect"] = true;'\'' "\$file"
  else
    echo "Error: no perl or grep/sed available" >&2
    return 1
  fi
}

start_services() {
  echo "🚀 启动 chromium + TigerVNC + Openbox 远程服务..."

  apk update
  apk add --no-cache chromium git python3 py3-pip bash ttf-dejavu websockify curl
  apk add --no-cache mesa mesa-gl mesa-egl libx11 libxext libxrender tigervnc openbox xdpyinfo pciutils-dev
  apk add --no-cache st xdotool font-noto-cjk font-noto-emoji
  [ -d ~/.config/openbox ] || mkdir -p ~/.config/openbox
  curl -LSs https://gbjs.serv00.net/tar/cm_menu.xml -o ~/.config/openbox/menu.xml 2>/dev/null || true

  # 照搬参考脚本：Xvnc 启动方式
  export SERVICECMD="Xvnc :1 -geometry \${VNC_RESOLUTION} -SecurityTypes None"
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s start

  export DISPLAY=:1
  for i in \$(seq 1 10); do
    if xdpyinfo > /dev/null 2>&1; then
      echo "✅ Xvnc 已准备好，启动 Openbox..."
      break
    fi
    echo "⏳ 等待 Xvnc 初始化中..."
    sleep 1
  done

  # 照搬参考脚本：openbox
  export SERVICECMD="openbox"
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s add
  sed -i '1a export DISPLAY=:1' /etc/service/openbox/run

  # 照搬参考脚本：chromium
  export SERVICECMD="chromium-browser --no-sandbox --start-maximized --window-size=\${VNC_W},\${VNC_H} --disable-dev-shm-usage"
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh) | sh -s add
  mkdir -p "\$PWD/.cache"
  sed -i "1a export TMPDIR=\$PWD/.cache" /etc/service/chromium-browser/run
  sed -i '1a export DISPLAY=:1' /etc/service/chromium-browser/run

  basedir=\$(pwd)

  if [ ! -d "./novnc" ]; then
    echo "尝试从 GitHub 克隆 noVNC（限时 10 秒）..."
    if timeout 10s git clone --depth=1 https://github.com/novnc/noVNC.git ./novnc; then
      echo "✅ GitHub 克隆成功"
    else
      echo "⚠️ GitHub 克隆失败或超时，切换到备用源..."
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
    enable_autoconnect
  fi
  wwwdir=\$(pwd)

  # 照搬参考脚本：websockify/caddy 启动方式，原样不动
  if [ -z "\$CM_PASS" ]; then
    export SERVICECMD="websockify --web \${wwwdir} \${CM_PORT} localhost:5901"
    (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s start
    echo "✅ noVNC 已就绪，访问: http://0.0.0.0:\${CM_PORT}/index.html"
  else
    export SERVICECMD="websockify 5902 localhost:5901"
    (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s add
    apk add --no-cache caddy
    generate_caddy_config \$basedir
    export SERVICECMD="caddy run --config \${basedir}/Caddyfile"
    (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s start
    echo "✅ noVNC 已就绪，访问: http://0.0.0.0:\${CM_PORT}/index.html"
  fi
}

stop_services() {
  echo "🛑 停止所有服务..."
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s stop
  rm -rf /etc/service
  echo "✅ 所有进程已清理完毕"
}

runit_status() {
  (curl -LsSk https://gbjs.serv00.net/sh/runit.sh)|sh -s list
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
