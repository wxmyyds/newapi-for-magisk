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
    fi
  fi
  # 兜底：按特征杀残留
  pkill -f "bin/new-api" 2>/dev/null
  sleep 1
  # 杀守护 shell 本体
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
