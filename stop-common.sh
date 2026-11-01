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
