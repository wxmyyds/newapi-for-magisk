#!/system/bin/sh
# ============================================================
#  update.sh - 手机上直接更新 New API 二进制（免打包、免重刷模块）
#  流程: 探测上游最新版 -> 下载校验 ELF -> 停服务 -> 原地替换
#        bin/new-api -> 自动重启守护（数据 /data/adb/newapi 不受影响）
#
#  用法 (root shell 或 Termux):
#    su -c "sh /data/adb/modules/newapi_for_magisk/update.sh"
#    su -c "sh /data/adb/modules/newapi_for_magisk/update.sh v1.0.0-rc.36"  # 指定版本
#    su -c "sh /data/adb/modules/newapi_for_magisk/update.sh --force"       # 同版本也强制重下
#
#  下载器自动探测: curl / Termux curl / Magisk busybox wget / 系统 wget
# ============================================================

# ---------- Termux PATH 自愈（su root shell 里也能用 Termux 的 curl）----------
TERMUX_BIN="/data/data/com.termux/files/usr/bin"
if [ -d "$TERMUX_BIN" ] && ! echo "$PATH" | grep -q "$TERMUX_BIN"; then
  PATH="$TERMUX_BIN:$PATH"
  export PATH
fi

SCRIPT_DIR=${0%/*}
case "$SCRIPT_DIR" in
  */*) ;;
  *) SCRIPT_DIR="." ;;
esac

REPO="QuantumNous/new-api"
INSTALLED="/data/adb/modules/newapi_for_magisk"
DATA_DIR="/data/adb/newapi"
PID_FILE="$DATA_DIR/new-api.pid"
GUARD_FILE="$DATA_DIR/guardian.pid"
STOP_FILE="$DATA_DIR/.stop"
RELEASES_LATEST="https://github.com/${REPO}/releases/latest"

# ---------- 更新目标：已安装的模块目录（原地替换），否则脚本所在目录 ----------
ON_PHONE=0
if [ -d "$INSTALLED/bin" ]; then
  if [ "$(id -u 2>/dev/null)" = "0" ]; then
    TARGET="$INSTALLED"
    ON_PHONE=1
  else
    echo "! 检测到已安装的模块，更新它需要 root 权限"
    echo "  在 Termux 里执行: su -c \"sh $SCRIPT_DIR/update.sh\""
    exit 1
  fi
else
  # 未安装模块：更新脚本所在目录的本地副本（配合 pack.sh 打包工作流）
  TARGET="$SCRIPT_DIR"
fi
BIN="$TARGET/bin/new-api"
VERSION_FILE="$TARGET/bin/VERSION"

# 临时文件：手机上放数据目录（一定可写），本地副本模式放 bin/（pack.sh 会排除 *.tmp）
if [ "$ON_PHONE" -eq 1 ]; then
  mkdir -p "$DATA_DIR"
  TMP_BIN="$DATA_DIR/.update.new-api.tmp"
  TMP_HTML="$DATA_DIR/.update.latest.html"
else
  mkdir -p "$SCRIPT_DIR/bin"
  TMP_BIN="$SCRIPT_DIR/bin/new-api.tmp"
  TMP_HTML="$SCRIPT_DIR/bin/.latest.html"
fi
trap 'rm -f "$TMP_BIN" "$TMP_HTML"' EXIT INT TERM

# ---------- 下载器探测 ----------
# 优先 curl（重定向/重试语义最全），其次 Magisk/KSU/APatch 自带 busybox 的
# wget（支持 https），最后 toybox wget（部分老 ROM 不支持 https，仅兜底）
CURL=""
BB_WGET=""
SYS_WGET=""
command -v curl >/dev/null 2>&1 && CURL="curl"
if [ -z "$CURL" ]; then
  for BB in $(command -v busybox 2>/dev/null) \
            /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$BB" ] && "$BB" --list 2>/dev/null | grep -q '^wget$'; then
      BB_WGET="$BB"
      break
    fi
  done
  command -v wget >/dev/null 2>&1 && SYS_WGET="wget"
fi
if [ -z "$CURL" ] && [ -z "$BB_WGET" ] && [ -z "$SYS_WGET" ]; then
  echo "! 没有可用的下载器（curl/wget 均未找到）"
  echo "  最简单: 在 Termux 里执行 pkg install curl 后重试"
  exit 1
fi

# 统一下载入口: fetch <url> <outfile>（跟随重定向，失败返回非 0）
fetch() {
  if [ -n "$CURL" ]; then
    curl -L -f -o "$2" --connect-timeout 15 --retry 2 --max-time 1800 "$1" >/dev/null 2>&1
  elif [ -n "$BB_WGET" ]; then
    "$BB_WGET" wget -q -O "$2" "$1" >/dev/null 2>&1
  else
    "$SYS_WGET" -O "$2" "$1" >/dev/null 2>&1
  fi
}

# ---------- 当前版本 ----------
# bin/VERSION 优先（update.sh / download-binary.sh 都会写），
# 否则从二进制 Go buildinfo 提取（与 service.sh 同一套逻辑）
cur_version() {
  if [ -s "$VERSION_FILE" ]; then
    head -n1 "$VERSION_FILE" | tr -d '[:space:]'
    return
  fi
  if [ -f "$BIN" ]; then
    tail -c 8388608 "$BIN" 2>/dev/null | \
      grep -aoE 'github\.com/QuantumNous/new-api[[:space:]]+v[0-9][^[:space:]]*' | \
      head -n1 | awk '{print $2}' | sed 's/+dirty$//'
  fi
}

# ---------- 探测上游最新版本 ----------
# releases/latest 会 302 到 .../tag/vX.Y.Z；curl 直接取 %{redirect_url}，
# wget 没有这个能力就抓回 HTML 从链接里 grep，最后 GitHub API 兜底
detect_latest() {
  V=""
  if [ -n "$CURL" ]; then
    for BASE in "" "https://ghfast.top/" "https://ghproxy.net/"; do
      V=$(curl -s --connect-timeout 8 --max-time 20 -o /dev/null \
            -w '%{redirect_url}' "${BASE}${RELEASES_LATEST}" 2>/dev/null | \
          grep -oE 'tag/v[0-9][^/]*' | head -n1 | cut -d/ -f2)
      [ -n "$V" ] && { echo "$V"; return 0; }
    done
  fi
  if [ -n "$BB_WGET" ] || [ -n "$SYS_WGET" ]; then
    for BASE in "" "https://ghfast.top/" "https://ghproxy.net/"; do
      rm -f "$TMP_HTML"
      if [ -n "$BB_WGET" ]; then
        "$BB_WGET" wget -q -O "$TMP_HTML" "${BASE}${RELEASES_LATEST}" >/dev/null 2>&1
      else
        "$SYS_WGET" -O "$TMP_HTML" "${BASE}${RELEASES_LATEST}" >/dev/null 2>&1
      fi
      V=$(grep -oE 'tag/v[0-9][^/"]*' "$TMP_HTML" 2>/dev/null | head -n1 | cut -d/ -f2)
      [ -n "$V" ] && { echo "$V"; return 0; }
    done
  fi
  # GitHub API 兜底（未认证每小时 60 次，仅作备份）
  rm -f "$TMP_HTML"
  fetch "https://api.github.com/repos/${REPO}/releases/latest" "$TMP_HTML"
  V=$(grep -oE '"tag_name": *"[^"]+"' "$TMP_HTML" 2>/dev/null | \
      head -n1 | sed 's/.*: *"//;s/"$//')
  [ -n "$V" ] && { echo "$V"; return 0; }
  return 1
}

# ---------- 参数解析 ----------
FORCE=0
TARGET_VER=""
for arg in "$@"; do
  case "$arg" in
    --force|-f) FORCE=1 ;;
    v*) TARGET_VER="$arg" ;;
    *) TARGET_VER="v$arg" ;;
  esac
done

CUR=$(cur_version)
echo "当前版本: ${CUR:-未知}"

if [ -n "$TARGET_VER" ]; then
  VERSION="$TARGET_VER"
  echo "使用指定版本: $VERSION"
else
  echo ">> 探测上游最新版本..."
  VERSION=$(detect_latest)
  if [ -z "$VERSION" ]; then
    echo "! 无法探测上游最新版本（网络问题）"
    echo "  可手动指定版本重试: sh $SCRIPT_DIR/update.sh v1.0.0-rc.36"
    exit 1
  fi
  echo "   上游最新版本: $VERSION"
fi

if [ "$FORCE" -ne 1 ] && [ -f "$BIN" ] && [ -n "$CUR" ] && [ "$CUR" = "$VERSION" ]; then
  echo ""
  echo "================================================"
  echo "  ✓ 已是最新版本 $VERSION，无需更新"
  echo "  强制重新下载: sh $SCRIPT_DIR/update.sh --force"
  echo "================================================"
  exit 0
fi

# ---------- 下载 + 校验（校验通过才动正在运行的服务）----------
GH="https://github.com/${REPO}/releases/download/${VERSION}/new-api-arm64-${VERSION}"
MIRRORS="
${GH}
https://ghfast.top/${GH}
https://ghproxy.net/${GH}
https://gh-proxy.com/${GH}
https://gh.h233.eu.org/${GH}
"

echo "================================================"
echo "  下载 New API ${VERSION} (arm64 动态链接, ~120MB)"
echo "================================================"

OK=0
for URL in $MIRRORS; do
  [ -z "$URL" ] && continue
  echo ""
  echo ">> 尝试: $URL"
  rm -f "$TMP_BIN"
  if fetch "$URL" "$TMP_BIN"; then
    SIZE=$(wc -c < "$TMP_BIN" 2>/dev/null)
    [ -z "$SIZE" ] && SIZE=0
    # ELF 魔数校验: 头 4 字节 = 7f 'E' 'L' 'F'（不用 od，兼容 toybox）
    if head -c 4 "$TMP_BIN" 2>/dev/null | grep -q ELF && [ "$SIZE" -gt 50000000 ]; then
      echo "   下载完成 ($SIZE 字节)，ELF 校验通过"
      OK=1
      break
    fi
    echo "   ✗ 文件无效 (size=$SIZE, 非 ELF 或过小)"
  else
    echo "   ✗ 下载失败"
  fi
done

if [ "$OK" -ne 1 ]; then
  echo ""
  echo "! 所有镜像下载失败，未做任何改动，服务保持运行"
  echo "  手动下载 $GH"
  echo "  放到 $BIN 后重启手机即可"
  exit 1
fi

# ---------- 停止服务（复用 action.sh 同款逻辑，防止守护复活）----------
if [ "$ON_PHONE" -eq 1 ]; then
  echo ""
  echo ">> 停止服务..."
  touch "$STOP_FILE" 2>/dev/null
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && grep -aq "bin/new-api" "/proc/$PID/cmdline" 2>/dev/null; then
      kill "$PID" 2>/dev/null
    fi
  fi
  pkill -f "bin/new-api" 2>/dev/null
  sleep 1
  if [ -f "$GUARD_FILE" ]; then
    GUARD_PID=$(cat "$GUARD_FILE" 2>/dev/null)
    if [ -n "$GUARD_PID" ] && grep -aq "newapi_for_magisk" "/proc/$GUARD_PID/cmdline" 2>/dev/null; then
      kill "$GUARD_PID" 2>/dev/null
    fi
  fi
  pkill -f "newapi_for_magisk.*service" 2>/dev/null
  rm -f "$PID_FILE" "$GUARD_FILE"
fi

# ---------- 原地替换二进制 ----------
if mv -f "$TMP_BIN" "$BIN" && chmod 0755 "$BIN"; then
  printf '%s\n' "$VERSION" > "$VERSION_FILE"
  echo ">> 已替换: $BIN -> $VERSION"
else
  echo "! 替换失败！新二进制保留在: $TMP_BIN"
  if [ "$ON_PHONE" -eq 1 ]; then
    rm -f "$STOP_FILE"
    nohup sh "$TARGET/service.sh" >/dev/null 2>&1 &
    echo "  已尝试恢复旧版服务，请检查日志 $DATA_DIR/service.log"
  fi
  exit 1
fi

# ---------- 重启服务 ----------
if [ "$ON_PHONE" -eq 1 ]; then
  echo ">> 重启服务..."
  rm -f "$STOP_FILE"
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$TARGET/service.sh" >/dev/null 2>&1 &
  else
    sh "$TARGET/service.sh" >/dev/null 2>&1 &
  fi
  # 简短确认守护是否拉起成功
  UP=""
  i=0
  while [ $i -lt 5 ]; do
    sleep 1
    if [ -f "$PID_FILE" ]; then
      P=$(cat "$PID_FILE" 2>/dev/null)
      if [ -n "$P" ] && grep -aq "bin/new-api" "/proc/$P/cmdline" 2>/dev/null; then
        UP="$P"
        break
      fi
    fi
    i=$((i+1))
  done
  echo ""
  echo "================================================"
  if [ -n "$UP" ]; then
    echo "  ✓ 更新完成: $VERSION 已在运行 (PID=$UP)"
  else
    echo "  ✓ 二进制已更新为 $VERSION，但启动未确认"
    echo "  请检查: cat $DATA_DIR/service.log"
  fi
  echo "  管理面板: http://localhost:3100"
  echo "================================================"
else
  echo ""
  echo "================================================"
  echo "  ✓ 本地副本已更新为 $VERSION"
  echo "  重新打包刷入: sh $SCRIPT_DIR/pack.sh"
  echo "================================================"
fi
