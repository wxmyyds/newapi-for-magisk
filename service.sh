#!/system/bin/sh
# ============================================================
#  New API for Magisk - Magisk/KSU 模块开机自启 + 崩溃守护
#  运行于 late_start service 阶段（非阻塞，root 权限）
# ============================================================
# MODDIR 兼容两种调用方式：
# - Magisk 直接 exec（$0 为完整路径）→ ${0%/*} 正常
# - 手动 sh /path/service.sh（$0 可能为 sh）→ 回退到默认路径
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR="/data/adb/modules/newapi_for_magisk" ;;
esac
[ ! -f "$MODDIR/service.sh" ] && MODDIR="/data/adb/modules/newapi_for_magisk"
BIN="$MODDIR/bin/new-api"
LIB_DIR="$MODDIR/lib"
LD_LINUX="$LIB_DIR/ld-linux-aarch64.so.1"
DATA_DIR="/data/adb/newapi"
LOG_FILE="$DATA_DIR/service.log"
PID_FILE="$DATA_DIR/new-api.pid"
GUARD_FILE="$DATA_DIR/guardian.pid"
STOP_FILE="$DATA_DIR/.stop"
PORT=3100  # 3000 常被其他应用（如 AdGuard Home）占用，改用 3100

# 进程存活且命令行含指定特征（防止重启后 PID 复用导致误判"已在运行"/误杀无关进程）
pid_match() {
  [ -n "$1" ] && grep -aq "$2" "/proc/$1/cmdline" 2>/dev/null
}

mkdir -p "$DATA_DIR" "$DATA_DIR/logs"
exec > "$LOG_FILE" 2>&1
echo "[$(date)] ====== New API for Magisk 模块服务启动 ======"

# ---------- 启动互斥锁（防止启动等待窗口内被二次拉起，产生双守护抢端口） ----------
START_LOCK="$DATA_DIR/.starting.pid"
if [ -f "$START_LOCK" ]; then
  LOCK_PID=$(cat "$START_LOCK" 2>/dev/null)
  if pid_match "$LOCK_PID" "newapi_for_magisk.*service"; then
    echo "[$(date)] 另一实例正在启动（PID=$LOCK_PID），本次退出"
    exit 0
  fi
fi
echo $$ > "$START_LOCK"

# ---------- 停止标记清理 ----------
# 仅开机自启路径清理（重启即恢复自启）；手动路径由 action.sh 启动前已清理，
# 且保留启动等待期间收到的停止请求（守护拉起后看到 .stop 会立即退出）
if command -v getprop >/dev/null 2>&1 && [ "$(getprop sys.boot_completed)" != "1" ]; then
  rm -f "$STOP_FILE"
fi

# ---------- 等待系统启动完成（状态轮询，不用固定 sleep）----------
# 手动启动时 sys.boot_completed 已为 1，直接跳过且不额外等待；
# 轮询上限 5 分钟，防止个别 ROM 属性异常导致永久挂起
if command -v getprop >/dev/null 2>&1; then
  WAITED=0
  until [ "$(getprop sys.boot_completed)" = "1" ] || [ "$WAITED" -ge 150 ]; do
    sleep 2
    WAITED=$((WAITED+1))
  done
  if [ "$WAITED" -gt 0 ]; then
    sleep 5  # 再等网络栈就绪
    [ "$WAITED" -ge 150 ] && echo "[$(date)] WARN: 等待 sys.boot_completed 超时（5 分钟），强制继续启动"
  fi
fi

# ---------- 清除 Termux LD_PRELOAD 干扰 ----------
unset LD_PRELOAD

# ---------- DNS 修复（best-effort：只读 /system 上允许失败） ----------
# New API 是 glibc 动态链接二进制，net resolver 通过 NSS 工作
if [ ! -s /etc/resolv.conf ]; then
  echo "[$(date)] resolv.conf 为空，尝试写入 DNS"
  if echo "nameserver 223.5.5.5" > /etc/resolv.conf 2>/dev/null; then
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf 2>/dev/null
  else
    echo "[$(date)] WARN: /etc/resolv.conf 只读，跳过（依赖系统 DNS）"
  fi
fi
# NSS 配置：先查 hosts 文件再查 DNS
if [ ! -f /etc/nsswitch.conf ]; then
  echo "hosts: files dns" > /etc/nsswitch.conf 2>/dev/null || \
    echo "[$(date)] WARN: /etc/nsswitch.conf 只读，跳过"
fi

# ---------- CA 证书修复（x509: unknown authority 根因）----------
# Go 程序按 Linux 习惯找 /etc/ssl/certs/ca-certificates.crt，
# Android 上该路径不存在，导致 HTTPS 上游全部报
# "tls: failed to verify certificate: x509: certificate signed by unknown authority"
# 策略：DATA_DIR 副本为主（一定可写）+ /etc 尝试写入为辅（只读则跳过）
CA_SRC="$MODDIR/certs/ca-certificates.crt"
CA_DATA="$DATA_DIR/ca-certificates.crt"
CA_SYS="/etc/ssl/certs/ca-certificates.crt"
if [ -f "$CA_SRC" ]; then
  # DATA_DIR 副本：Go 优先读 SSL_CERT_FILE，指向这里最稳
  if [ ! -f "$CA_DATA" ] || ! cmp -s "$CA_SRC" "$CA_DATA" 2>/dev/null; then
    cp -f "$CA_SRC" "$CA_DATA" 2>/dev/null && \
      echo "[$(date)] CA 证书已同步到 $CA_DATA" || \
      echo "[$(date)] WARN: CA 证书同步到 DATA_DIR 失败"
  fi
  # /etc 尝试写入：成功最好，失败不致命（有 SSL_CERT_FILE 兜底）
  if [ ! -s "$CA_SYS" ]; then
    mkdir -p /etc/ssl/certs 2>/dev/null
    cat "$CA_SRC" > "$CA_SYS" 2>/dev/null && \
      echo "[$(date)] 已写入 CA 证书包到 /etc/ssl/certs/" || \
      echo "[$(date)] WARN: /etc/ssl 只读，跳过系统路径写入（用 SSL_CERT_FILE 兜底）"
  fi
else
  echo "[$(date)] WARN: 模块内置 CA 包缺失: $CA_SRC"
fi
export SSL_CERT_FILE="$CA_DATA"

# ---------- 出站代理（可选，proxy.conf 单 URL 行） ----------
# 配置文件：$DATA_DIR/proxy.conf，首次启动自动建模板，之后永不覆盖。
# 空文件/全注释 = 直连（默认，零影响）；填一行代理地址即走代理，仅代理外网。
# 代理连不上/格式非法 = WARN + 直连（不断服）；恢复后点 ACTION 重启模块生效。
PROXY_CONF="$DATA_DIR/proxy.conf"
if [ ! -f "$PROXY_CONF" ]; then
  cat > "$PROXY_CONF" <<'EOF'
# New API 出站代理（可选）
# 直连：保持全注释/空文件即可（默认）
# 走代理：取消最后一行注释，改成你的代理地址（地址中不要带 #）
# 格式：http:// / https:// / socks5:// / socks5h://
# 示例（本机 mihomo 默认 mixed-port 7890）：
# http://127.0.0.1:7890
EOF
  echo "[$(date)] 已生成代理配置模板：$PROXY_CONF（默认直连，需代理请编辑后重启模块）"
fi
PROXY_URL=$(sed -e 's/#.*$//' -e 's/[[:space:]]//g' -e '/^$/d' "$PROXY_CONF" 2>/dev/null | head -n1)
if [ -z "$PROXY_URL" ]; then
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
  echo "[$(date)] 直连模式（proxy.conf 未配置代理）"
else
  case "$PROXY_URL" in
    http://*|https://*|socks5://*|socks5h://*) ;;
    *)
      echo "[$(date)] WARN: 代理地址格式非法，已忽略并走直连：$PROXY_URL（应为 http(s):// 或 socks5(h):// 开头）"
      PROXY_URL=""
      ;;
  esac
fi
if [ -n "$PROXY_URL" ]; then
  # 连通性检查：只测代理端口通不通，不测外网（开机时外网可能还没就绪）。
  # 本机代理给 30 秒启动窗口（等 mihomo 之类先起）；远端代理只测一次。
  _tmp=${PROXY_URL#*://}; _tmp=${_tmp%%/*}; _tmp=${_tmp##*@}
  PROXY_HOST=""; PROXY_PORT=""
  case "$_tmp" in
    \[*)
      # [v6] 或 [v6]:port：先按 ] 切分，避免裸 v6 冒号干扰
      PROXY_HOST=${_tmp%%]*}; PROXY_HOST=${PROXY_HOST#\[}
      _rest=${_tmp#*\]}
      case "$_rest" in
        :*) PROXY_PORT=${_rest#:} ;;
      esac
      ;;
    *:*) PROXY_HOST=${_tmp%:*}; PROXY_PORT=${_tmp##*:} ;;
    *) PROXY_HOST=$_tmp ;;
  esac
  case "$PROXY_PORT" in ''|*[!0-9]*) PROXY_PORT="" ;; esac
  if [ -z "$PROXY_HOST" ]; then
    echo "[$(date)] WARN: 代理地址无有效主机，已忽略并走直连：$PROXY_URL"
    PROXY_URL=""
  fi
  if [ -z "$PROXY_PORT" ] && [ -n "$PROXY_URL" ]; then
    case "$PROXY_URL" in https://*) PROXY_PORT=443 ;; socks5://*|socks5h://*) PROXY_PORT=1080 ;; *) PROXY_PORT=80 ;; esac
  fi
  _proxy_probe() {
    _probe_host=$1
    case "$_probe_host" in *:*) _probe_host="[$_probe_host]" ;; esac
    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null --max-time 3 "http://$_probe_host:$2/" >/dev/null 2>&1
      _c=$?
      # 7=连不上 28=超时 算不通；其他（400/404/空回包/握手失败等）都算端口活着
      [ "$_c" -ne 7 ] && [ "$_c" -ne 28 ]
      return $?
    fi
    if command -v nc >/dev/null 2>&1; then
      nc -z -w 3 "$1" "$2" >/dev/null 2>&1
      return $?
    fi
    return 2
  }
  PROXY_STATE="fail"
  case "$PROXY_HOST" in
    127.*|localhost|::1)
      _w=0
      while [ "$_w" -lt 30 ]; do
        _proxy_probe "$PROXY_HOST" "$PROXY_PORT"; _rc=$?
        if [ "$_rc" -eq 0 ]; then PROXY_STATE="ok"; break; fi
        if [ "$_rc" -eq 2 ]; then PROXY_STATE="unchecked"; break; fi
        sleep 2; _w=$((_w+2))
      done
      ;;
    *)
      _proxy_probe "$PROXY_HOST" "$PROXY_PORT"; _rc=$?
      if [ "$_rc" -eq 0 ]; then PROXY_STATE="ok"; fi
      if [ "$_rc" -eq 2 ]; then PROXY_STATE="unchecked"; fi
      ;;
  esac
  if [ -z "$PROXY_URL" ]; then
    : # 主机非法已在上面 WARN，直接直连
  elif [ "$PROXY_STATE" = "fail" ]; then
    echo "[$(date)] WARN: 代理连不上，已走直连：$PROXY_URL（检查代理是否运行，恢复后点 ACTION 重启模块）"
  else
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export NO_PROXY="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" no_proxy="$NO_PROXY"
    if [ "$PROXY_STATE" = "unchecked" ]; then
      echo "[$(date)] 出站走代理（无探测工具，未检查连通性）：$PROXY_URL"
    else
      echo "[$(date)] 出站走代理：$PROXY_URL（局域网/本机直连）"
    fi
  fi
  unset _tmp _rest PROXY_HOST PROXY_PORT PROXY_STATE _rc _w _c _probe_host
  unset -f _proxy_probe 2>/dev/null
fi

# ---------- New API 运行时配置（环境变量） ----------
# 错误日志：上游默认关闭（仅环境变量可控，不在后台设置里），
# 开启后"日志"页的类型筛选才能看到"错误"记录（模型调用失败详情）
export ERROR_LOG_ENABLED=true

# 版本号：上游 release 构建的 -X ldflags 用了错误路径，注入静默失败，UI 会显示 v0.0.0。
# 运行时用 VERSION 环境变量覆盖。版本号从二进制 Go buildinfo 自动提取（buildinfo 在 ELF 末尾，
# tail 只读 8MB 窗口开销毫秒级），永远与实际二进制一致，升级时无需改任何配置。
# 提取失败则回退读 bin/VERSION（download-binary.sh 下载成功时自动写入）
NAPI_VER=""
if [ -f "$BIN" ]; then
  NAPI_VER=$(tail -c 8388608 "$BIN" 2>/dev/null | \
    grep -aoE 'github\.com/QuantumNous/new-api[[:space:]]+v[0-9][^[:space:]]*' | \
    head -n1 | awk '{print $2}' | sed 's/+dirty$//')
fi
if [ -z "$NAPI_VER" ] && [ -s "$MODDIR/bin/VERSION" ]; then
  NAPI_VER=$(head -n1 "$MODDIR/bin/VERSION" | tr -d '[:space:]')
fi
if [ -n "$NAPI_VER" ] && [ "$NAPI_VER" != "(devel)" ]; then
  export VERSION="$NAPI_VER"
  echo "[$(date)] new-api 版本: $VERSION（自动检测）"
else
  echo "[$(date)] WARN: 未能检测到 new-api 版本号，UI 将显示 v0.0.0（无功能影响）"
fi

# ---------- 防重复启动 ----------
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if pid_match "$OLD_PID" "bin/new-api"; then
    echo "[$(date)] 已在运行 PID=$OLD_PID，跳过本次启动"
    exit 0
  fi
fi
if [ -f "$GUARD_FILE" ]; then
  OLD_GUARD=$(cat "$GUARD_FILE" 2>/dev/null)
  if pid_match "$OLD_GUARD" "newapi_for_magisk.*service"; then
    echo "[$(date)] 守护进程已在运行 PID=$OLD_GUARD，跳过本次启动"
    exit 0
  fi
fi

# ---------- 检查文件 ----------
if [ ! -f "$BIN" ]; then
  echo "[$(date)] FATAL: 二进制不存在: $BIN"
  exit 1
fi
if [ ! -f "$LD_LINUX" ]; then
  echo "[$(date)] FATAL: glibc 链接器不存在: $LD_LINUX"
  exit 1
fi
chmod 0755 "$BIN" "$LD_LINUX" 2>/dev/null
chmod 0755 "$LIB_DIR"/lib*.so* 2>/dev/null

# ---------- 端口占用预检 ----------
# 端口被占（其他实例/其他应用）时快速失败并写明日志，不陷入崩溃循环
if netstat -lnt 2>/dev/null | grep -q "[.:]$PORT[^0-9]"; then
  echo "[$(date)] FATAL: 端口 $PORT 已被占用，本次拒绝启动（排查: netstat -lnt | grep $PORT）"
  exit 1
fi

# ---------- 工作目录：SQLite 用相对路径，DB 固定在 DATA_DIR ----------
# 不再放模块目录（模块更新/重装会清空模块目录导致数据库丢失）；
# 必须 cd 到可写目录，否则从 / 等只读目录启动会报 sqlite error 14
cd "$DATA_DIR" 2>/dev/null || {
  echo "[$(date)] FATAL: 无法进入数据目录: $DATA_DIR"
  exit 1
}
echo "[$(date)] 工作目录: $(pwd)（数据库: $DATA_DIR/one-api.db）"

# ---------- 守护循环（崩溃自动重启，可被 .stop 优雅停止）----------
# 用 glibc 的 ld-linux 加载动态链接二进制
# --library-path 指定库搜索路径，root 环境下不受 seccomp 限制
(
  while true; do
    # 停止标记：action.sh / uninstall.sh 创建，守护看到后彻底退出
    if [ -f "$STOP_FILE" ]; then
      echo "[$(date)] 收到停止标记，守护退出"
      exit 0
    fi
    # stdout.log 超 20MB 轮转一份（请求日志都会打到 stdout，防止无限膨胀）
    LOGSZ=$(wc -c 2>/dev/null < "$DATA_DIR/stdout.log" || echo 0)
    [ -z "$LOGSZ" ] && LOGSZ=0
    [ "$LOGSZ" -gt 20971520 ] && \
      mv -f "$DATA_DIR/stdout.log" "$DATA_DIR/stdout.log.old" 2>/dev/null
    echo "[$(date)] 拉起 new-api ..."
    "$LD_LINUX" --library-path "$LIB_DIR" \
      "$BIN" \
      --port "$PORT" \
      --log-dir "$DATA_DIR/logs" \
      >> "$DATA_DIR/stdout.log" 2>&1 &
    NEW_PID=$!
    echo "$NEW_PID" > "$PID_FILE"
    # 与父进程的 renice 存在竞态（首个子进程可能在降级前 fork），这里补一次
    renice -n 19 -p "$NEW_PID" 2>/dev/null
    ionice -c 3 -p "$NEW_PID" 2>/dev/null
    echo "[$(date)] new-api 启动 PID=$NEW_PID，监听 :$PORT"
    wait "$NEW_PID" 2>/dev/null
    rm -f "$PID_FILE"
    # 被主动停止则不再重启
    if [ -f "$STOP_FILE" ]; then
      echo "[$(date)] 收到停止标记，守护退出"
      exit 0
    fi
    echo "[$(date)] new-api 进程退出，8 秒后自动重启 ..."
    sleep 8
  done
) &
GUARD_PID=$!
echo "$GUARD_PID" > "$GUARD_FILE"
# 守护已接管防重复职责，释放启动互斥锁（仅当锁仍属于本次实例时）
[ "$(cat "$START_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$START_LOCK"

# 降级守护进程优先级（renice 作用于守护 PID，而非短命父 shell）
renice -n 19 -p "$GUARD_PID" 2>/dev/null
ionice -c 3 -p "$GUARD_PID" 2>/dev/null

echo "[$(date)] 守护进程已脱离到后台 PID=$GUARD_PID"
echo "[$(date)] 管理面板: http://localhost:$PORT  (首次访问请按引导页初始化管理员账号)"
