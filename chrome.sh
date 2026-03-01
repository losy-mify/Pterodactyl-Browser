#!/bin/bash
# 部署 chrome（已集成 Gost SOCKS5 代理中转）

load_env(){
	shopt -s dotglob
	for f in ./.env ./*.env ./*/*.env ./*/*/*.env; do
		if [ -f "$f" ]; then
			ENV_FILE="$f"
			break
		fi
	done
	shopt -u dotglob
	if [ -n "$ENV_FILE" ]; then
		echo "Loading environment variables from: $ENV_FILE"
		while IFS='=' read -r key value || [ -n "$key" ]; do
			case "$key" in
			''|\#*) continue ;;
			esac
			eval "export $key=\"$value\""
		done < "$ENV_FILE"
	else
		echo "No .env file found"
	fi
}

clean_screen() {
	echo "30 秒后自动清屏..."
	for i in $(seq 0 30); do
		printf "\r[%-${30}s] %d%%" $(printf "%${i}s" | tr ' ' '#') $((i*100/30))
		[ $i -lt 30 ] && sleep 1
	done
	echo
	tput clear 2>/dev/null || echo -e "\033c"
}

echo_env_vars() {
	export ARGO_AUTH="${ARGO_AUTH:-''}"
	export CM_PASS="${CM_PASS:-Ww112211}"
	export CM_PORT="${CM_PORT:-9020}"
	[ -n "$ARGO_AUTH" ] && echo "  ARGO_AUTH=$ARGO_AUTH"
	[ -n "$CM_PORT" ]   && echo "  CM_PORT=$CM_PORT"
}

setgamehostproot(){
	mkdir -p /home/container/.tmp
	cd /home/container/.tmp
	source <(curl -LsS https://gbjs.serv00.net/sh/alpineproot322.sh)
}

# ──────────────────────────────────────────────
# 新增：启动 / 停止 Gost SOCKS5 中转
# ──────────────────────────────────────────────
run_gost_proxy(){
	local action="$1"   # start | stop

	if [ "$action" = "stop" ]; then
		if [ -f /tmp/gost.pid ]; then
			kill "$(cat /tmp/gost.pid)" 2>/dev/null && echo "✅ Gost 代理已停止"
			rm -f /tmp/gost.pid
		fi
		return 0
	fi

	# action = start：检测四个代理变量是否齐全
	if [ -z "$PROXY_IP" ] || [ -z "$PROXY_PORT" ] || \
	   [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASS" ]; then
		echo "=> 未提供完整代理变量 (PROXY_IP / PROXY_PORT / PROXY_USER / PROXY_PASS)，跳过代理中转。"
		return 0
	fi

	echo "=> 检测到代理配置，正在准备 Gost SOCKS5 中转..."

	local GOST_BIN=/tmp/gost
	local GOST_PORT="${PROXY_LOCAL_PORT:-25575}"

	# 下载 Gost（仅当还没下载时）
	if [ ! -x "$GOST_BIN" ]; then
		echo "   正在下载 Gost 二进制..."
		# 根据架构自动选择下载链接
		local ARCH
		ARCH=$(uname -m)
		local GOST_URL
		case "$ARCH" in
			x86_64)  GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz" ;;
			aarch64) GOST_URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-armv8-2.11.5.gz" ;;
			*)
				echo "   ⚠️  不支持的架构 $ARCH，跳过 Gost 安装。"
				return 1
				;;
		esac
		curl -Ls "$GOST_URL" | gunzip > "$GOST_BIN"
		chmod +x "$GOST_BIN"
	fi

	# 杀掉旧实例（如果有）
	if [ -f /tmp/gost.pid ]; then
		kill "$(cat /tmp/gost.pid)" 2>/dev/null
		rm -f /tmp/gost.pid
	fi

	# 后台启动：在本机 GOST_PORT 监听无密码 SOCKS5，转发到上游代理
	nohup "$GOST_BIN" \
		-L "socks5://:${GOST_PORT}" \
		-F "socks5://${PROXY_USER}:${PROXY_PASS}@${PROXY_IP}:${PROXY_PORT}" \
		> /tmp/gost.log 2>&1 &
	echo $! > /tmp/gost.pid

	sleep 1
	if kill -0 "$(cat /tmp/gost.pid)" 2>/dev/null; then
		echo -e "\033[32m✅ Gost SOCKS5 中转已就绪！监听端口：${GOST_PORT}\033[0m"
		echo "   在 Chrome / FoxyProxy 中填写："
		echo "      协议: SOCKS5    地址: 127.0.0.1    端口: ${GOST_PORT}    密码: (留空)"
	else
		echo "⚠️  Gost 启动失败，请查看 /tmp/gost.log"
	fi
}
# ──────────────────────────────────────────────

runcftunnel(){
	[[ "$1" != "start" ]] && return 0
	if [ -z "${ARGO_AUTH}" ]; then
		load_env
	fi
	echo_env_vars
	cd /tmp
	curl -Ls https://gbjs.serv00.net/cftunnel.sh | bash
}

run_remote(){
	if [ -z "${PROOT_DIR}" ]; then
		source /home/container/.bashrc
	fi
	if [ -z "${PROOT_DIR}" ] || [ ! -d "${PROOT_DIR}" ]; then
		setgamehostproot
	fi

	# ── 代理中转：start 时启动，stop 时关闭 ──
	if [ "$1" = "start" ]; then
		run_gost_proxy start
	else
		run_gost_proxy stop
	fi

	runcftunnel "$1"
	cd "${PROOT_DIR}"

	if [ -e /tmp/cm_pipe ]; then
		rm -f /tmp/cm_pipe
	fi

	mkfifo /tmp/cm_pipe
	PROOT_STARTED=1 nohup ./proot -S ./rootfs -b /proc -b /sys -w "$PROOT_DIR" --cwd=/root \
		-b /etc/resolv.conf:/etc/resolv.conf \
		-b "$PROOT_TMP_DIR/hosts":/etc/hosts /bin/sh -c "
		export PATH=/sbin:/bin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
		export HOME='/config'
		export TMPDIR='\$HOME/tmp'
		echo  'export HOME=\"/config\"'>/root/.bashrc
		echo  'export TMPDIR=\"/config/tmp\"'>>/root/.bashrc
		[ -d \$TMPDIR ] || mkdir -p \$TMPDIR
		[ -d \$HOME ]   || mkdir -p \$HOME
		apk add --no-cache curl bash
		bash <(curl -LsS https://gbjs.serv00.net/sh/runchrome_runit.sh) \"$1\" 2>&1
		" > /tmp/cm_pipe 2>&1 &

	{
		while IFS= read -r -t 20 line; do
			echo "$line"
		done
	} < /tmp/cm_pipe | tee -a /home/container/.tmp/alpine/cm.log

	if [ "$1" = "start" ]; then
		stats=$(curl -Ls https://gbjs.serv00.net/sh/count.sh | bash -s -- proot_chrome)
		echo "✅ Deployment complete! This script has been deployed $stats times. Enjoy yourself! 🎉"
		# 显示代理提示（若已启用）
		if [ -n "$PROXY_IP" ] && [ -n "$PROXY_PORT" ]; then
			local GOST_PORT="${PROXY_LOCAL_PORT:-25575}"
			echo "🛡  SOCKS5 代理: 127.0.0.1:${GOST_PORT}（无需密码，FoxyProxy 直接填写）"
		fi
		clean_screen
	fi

	rm -f /tmp/cm_pipe
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
		echo "代理变量 (可选): PROXY_IP  PROXY_PORT  PROXY_USER  PROXY_PASS  PROXY_LOCAL_PORT(默认25575)"
		exit 1
		;;
esac
