#!/system/bin/sh
# ============================================================
#  uninstall.sh - Magisk 移除模块时执行
#  停止进程（含守护循环），保留数据（不删配置/渠道）
# ============================================================
case "$0" in
  */*) MODDIR=${0%/*} ;;
  *) MODDIR="/data/adb/modules/newapi_for_magisk" ;;
esac
[ ! -f "$MODDIR/stop-common.sh" ] && MODDIR="/data/adb/modules/newapi_for_magisk"
. "$MODDIR/stop-common.sh"
DATA_DIR="/data/adb/newapi"
PID_FILE="$DATA_DIR/new-api.pid"
GUARD_FILE="$DATA_DIR/guardian.pid"
STOP_FILE="$DATA_DIR/.stop"

# 立停止标记，防止守护循环复活
touch "$STOP_FILE" 2>/dev/null

# 停止运行中的实例（校验 cmdline 特征，防止重启后 PID 复用误杀无关进程）
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$PID" ] && grep -aq "bin/new-api" "/proc/$PID/cmdline" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    wait_pid_exit "$PID"
  fi
fi
pkill -f "bin/new-api" 2>/dev/null
# 此时 new-api 已确认退出，守护的 wait 应已返回并因 .stop 自行退出；下面的 kill 只是兜底
# 停止守护 shell 本体
if [ -f "$GUARD_FILE" ]; then
  GUARD_PID=$(cat "$GUARD_FILE" 2>/dev/null)
  if [ -n "$GUARD_PID" ] && grep -aq "newapi_for_magisk" "/proc/$GUARD_PID/cmdline" 2>/dev/null; then
    kill "$GUARD_PID" 2>/dev/null
  fi
fi
pkill -f "newapi_for_magisk.*service" 2>/dev/null
pkill -f "/bin/new-api" 2>/dev/null
rm -f "$PID_FILE" "$GUARD_FILE"

# 保留数据目录（渠道配置、SQLite 数据库、日志都在里面）
# 注意：保留 .stop 标记无影响，下次 service.sh 启动时会自动清除
# 如需彻底清除，手动删除: rm -rf /data/adb/newapi
echo "New API 模块已卸载，进程及守护均已停止"
echo "数据保留于 $DATA_DIR（如需清除请手动 rm -rf）"
