#!/bin/sh
# ============================================================
#  verify.sh - 模块脚本语法 + 关键逻辑验证
#  用于 CI（.github/workflows/build.yml）与本地：sh tests/verify.sh
#
#  注意：本文件中的 wait_pid_exit / 退避计数 / 启动锁 trap 片段与
#  action.sh、uninstall.sh、service.sh 中的实现保持一致；
#  改动对应脚本时须同步本文件（防回归），反之亦然。
# ============================================================

PASS=0
FAIL=0
check() {  # check <rc> <描述>
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS+1))
    echo "  ✓ $2"
  else
    FAIL=$((FAIL+1))
    echo "  ✗ $2"
  fi
}

echo "== 1/3 脚本语法检查 (sh -n)"
for f in service.sh action.sh uninstall.sh update.sh download-binary.sh pack.sh customize.sh; do
  if [ -f "$f" ]; then
    sh -n "$f" 2>/dev/null && check 0 "语法: $f" || check 1 "语法: $f"
  else
    check 1 "语法: $f（文件不存在）"
  fi
done

echo "== 2/3 停止等待逻辑（wait_pid_exit，与 action.sh / uninstall.sh 同源）"
# 背景：new-api 收到 SIGTERM 后优雅关闭（默认最长 120s，等在途 SSE 流），
# 停止流程必须先确认进程真正退出再杀守护，否则 new-api 成孤儿继续占着 3100 端口。
wait_pid_exit() {
  _wp=$1
  _t=0
  while [ "$_t" -lt 30 ]; do
    kill -0 "$_wp" 2>/dev/null || return 0
    sleep 1
    _t=$((_t+1))
  done
  kill -9 "$_wp" 2>/dev/null
  _t=0
  while [ "$_t" -lt 5 ]; do
    kill -0 "$_wp" 2>/dev/null || return 0
    sleep 1
    _t=$((_t+1))
  done
  return 1
}

# 2a: 进程 2 秒后自行退出 → 应立即确认死亡 (rc=0)
( sleep 2 ) & _P=$!
wait_pid_exit "$_P"; _RC=$?
wait "$_P" 2>/dev/null
if [ "$_RC" -eq 0 ] && ! kill -0 "$_P" 2>/dev/null; then
  check 0 "wait_pid_exit: 正常退出的进程立即确认 (rc=0)"
else
  check 1 "wait_pid_exit: 正常退出的进程立即确认 (rc=$_RC)"
fi

# 2b: 目标不存在 → 立即返回 rc=0
wait_pid_exit 99999999
check $? "wait_pid_exit: 目标不存在 → rc=0"

# 2c: 永不退出 → 至少等 30s 后 SIGKILL，最终确认死亡
( sleep 100 ) & _P=$!
_T0=$(date +%s 2>/dev/null || echo 0)
wait_pid_exit "$_P"; _RC=$?
_T1=$(date +%s 2>/dev/null || echo 0)
wait "$_P" 2>/dev/null
_ELAPSED=$((_T1-_T0))
if [ "$_ELAPSED" -ge 30 ] && ! kill -0 "$_P" 2>/dev/null; then
  check 0 "wait_pid_exit: 顽固进程 ${_ELAPSED}s 后终止并确认死亡 (rc=$_RC)"
else
  check 1 "wait_pid_exit: 顽固进程处理异常 (rc=$_RC, 用时 ${_ELAPSED}s)"
fi

echo "== 3/3 守护退避与启动锁释放（与 service.sh 同源）"
# 退避：短命(<60s)连续 5 次 → 改用 30s 间隔；长命(>=60s)计数清零
# 注意：$( ) 命令替换会隔离变量，多次 sim 必须包进同一个子 shell 以累积 CONSEC
CONSEC=0
sim() {
  _DUR=$1
  if [ "$_DUR" -lt 60 ]; then CONSEC=$((CONSEC+1)); else CONSEC=0; fi
  [ "$CONSEC" -ge 5 ] && echo backoff || echo normal
}
_SIMS=$( { sim 5; sim 3; sim 0; sim 10; sim 2; sim 120; } )
_L1=$(printf '%s\n' "$_SIMS" | sed -n '1p')
_L2=$(printf '%s\n' "$_SIMS" | sed -n '2p')
_L3=$(printf '%s\n' "$_SIMS" | sed -n '3p')
_L4=$(printf '%s\n' "$_SIMS" | sed -n '4p')
_L5=$(printf '%s\n' "$_SIMS" | sed -n '5p')
_L6=$(printf '%s\n' "$_SIMS" | sed -n '6p')
[ "$_L1$_L2$_L3$_L4" = normalnormalnormalnormal ] && check 0 "退避: 前 4 次短命不触发退避" || check 1 "退避: 前 4 次短命不触发退避"
[ "$_L5" = backoff ] && check 0 "退避: 连续第 5 次短命 → 30s 间隔" || check 1 "退避: 连续第 5 次短命 → 30s 间隔"
[ "$_L6" = normal ] && check 0 "退避: 长命(>=60s)后计数清零" || check 1 "退避: 长命(>=60s)后计数清零"

# 启动锁：EXIT trap 在 exit 0 / exit 1 时都释放（防陈旧 .starting.pid 残留）
_TDIR=$(mktemp -d 2>/dev/null || echo /tmp/verify.$$)
mkdir -p "$_TDIR"
_START_LOCK="$_TDIR/.starting.pid"
(
  echo $$ > "$_START_LOCK"
  trap 'LOCK_OWN=$(cat "$_START_LOCK" 2>/dev/null); [ "$LOCK_OWN" = "$$" ] && rm -f "$_START_LOCK"; unset LOCK_OWN' EXIT
  exit 0
)
[ ! -f "$_START_LOCK" ] && check 0 "启动锁: exit 0 后释放" || check 1 "启动锁: exit 0 后释放"
(
  echo $$ > "$_START_LOCK"
  trap 'LOCK_OWN=$(cat "$_START_LOCK" 2>/dev/null); [ "$LOCK_OWN" = "$$" ] && rm -f "$_START_LOCK"; unset LOCK_OWN' EXIT
  exit 1
)
[ ! -f "$_START_LOCK" ] && check 0 "启动锁: exit 1（FATAL 路径）后释放" || check 1 "启动锁: exit 1（FATAL 路径）后释放"
rm -rf "$_TDIR"

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
