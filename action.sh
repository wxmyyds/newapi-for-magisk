#!/system/bin/sh
# ============================================================
#  action.sh - 在 Magisk/KSU App 里点 "操作" 按钮时执行
#  手动启停 New API（通过 .stop 标记让守护循环彻底退出）
# ============================================================
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR="/data/adb/modules/newapi_for_magisk" ;;
esac
[ ! -f "$MODDIR/service.sh" ] && MODDIR="/data/adb/modules/newapi_for_magisk"
DATA_DIR="/data/adb/newapi"
PID_FILE="$DATA_DIR/new-api.pid"
GUARD_FILE="$DATA_DIR/guardian.pid"
STOP_FILE="$DATA_DIR/.stop"
PORT=3100

# 等待进程退出：new-api 收到 SIGTERM 后优雅关闭（默认最长 120s，等在途 SSE 流），
# 必须等它真正退出再杀守护，否则守护在 wait 中被杀、new-api 成孤儿继续占着 3100 端口。
# 最多等 30s，超时 SIGKILL 兜底。返回 0 = 已确认退出。
wait_pid_exit() {
  _wp=$1
  _t=0
  while [ "$_t" -lt 30 ]; do
    kill -0 "$_wp" 2>/dev/null || return 0
    sleep 1
    _t=$((_t+1))
  done
  echo "  new-api 30 秒内未正常退出（可能在等待 SSE 流），强制终止"
  kill -9 "$_wp" 2>/dev/null
  _t=0
  while [ "$_t" -lt 5 ]; do
    kill -0 "$_wp" 2>/dev/null || return 0
    sleep 1
    _t=$((_t+1))
  done
  return 1
}

stop_service() {
  # 先立停止标记，防止守护循环 8 秒后复活
  touch "$STOP_FILE" 2>/dev/null

  STOPPED=""
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    # 校验 cmdline 特征，防止重启后 PID 复用误杀无关进程
    if [ -n "$PID" ] && grep -aq "bin/new-api" "/proc/$PID/cmdline" 2>/dev/null; then
      kill "$PID" 2>/dev/null
      STOPPED="$PID"
      echo "  等待 PID=$PID 退出（new-api 优雅关闭，最长 30 秒）..."
      wait_pid_exit "$PID"
    fi
  fi
  # 兜底：按特征杀残留
  pkill -f "bin/new-api" 2>/dev/null
  # 此时 new-api 已确认退出，守护的 wait 应已返回并因 .stop 自行退出；
  # 下面的 kill 只是兜底清理
  if [ -f "$GUARD_FILE" ]; then
    GUARD_PID=$(cat "$GUARD_FILE" 2>/dev/null)
    if [ -n "$GUARD_PID" ] && grep -aq "newapi_for_magisk" "/proc/$GUARD_PID/cmdline" 2>/dev/null; then
      kill "$GUARD_PID" 2>/dev/null
    fi
  fi
  pkill -f "newapi_for_magisk.*service" 2>/dev/null
  rm -f "$PID_FILE" "$GUARD_FILE"

  if [ -n "$STOPPED" ]; then
    echo "已停止 New API (PID=$STOPPED)，守护已退出"
  else
    echo "已停止 New API（清理残留进程及守护）"
  fi
}

is_running() {
  [ -f "$PID_FILE" ] || return 1
  PID=$(cat "$PID_FILE" 2>/dev/null)
  # 校验 cmdline 特征，防止重启后 PID 复用误判
  [ -n "$PID" ] && grep -aq "bin/new-api" "/proc/$PID/cmdline" 2>/dev/null
}

if is_running; then
  stop_service
  exit 0
fi

# 未运行 → 启动：清停止标记后调用 service.sh
rm -f "$STOP_FILE"
sh "$MODDIR/service.sh" &
echo "已启动 New API，访问 http://localhost:$PORT"
