#!/system/bin/sh
# ============================================================
#  download-binary.sh - 下载 New API arm64 动态链接二进制（需 glibc，见 lib/）
#  版本号自动探测上游最新 release，无需手动改脚本。
#
#  用法:
#    sh ./download-binary.sh                  # 自动探测最新版并下载
#    sh ./download-binary.sh v1.0.0-rc.36     # 下载指定版本
#    sh ./download-binary.sh --force          # 本地已是最新版也强制重下
#
#  在 Termux 里运行（需要 curl）；直接 ./执行 或在 su root shell 里
#  执行也可以，脚本会自动把 Termux 的 bin 目录补进 PATH。
# ============================================================

# ---------- Termux PATH 自愈 ----------
# 直接 ./download-binary.sh 时 shebang 走 /system/bin/sh，PATH 里没有 curl；
# 在 su/root shell 里执行时同样找不到 Termux 的 curl。统一补上。
TERMUX_BIN="/data/data/com.termux/files/usr/bin"
if [ -d "$TERMUX_BIN" ] && ! echo "$PATH" | grep -q "$TERMUX_BIN"; then
  PATH="$TERMUX_BIN:$PATH"
  export PATH
fi

MODDIR=${0%/*}
# $0 不含路径时（如 sh download-binary.sh）回退为当前目录
case "$MODDIR" in
  */*) ;;
  *) MODDIR="." ;;
esac
OUT="$MODDIR/bin/new-api"
VERSION_FILE="$MODDIR/bin/VERSION"
REPO="QuantumNous/new-api"
RELEASES_LATEST="https://github.com/${REPO}/releases/latest"

# ---------- 参数解析 ----------
FORCE=0
TARGET_VER=""
for arg in "$@"; do
  case "$arg" in
    --force|-f)
      FORCE=1 ;;
    -h|--help)
      echo "用法: sh $0 [版本号] [--force]"
      echo "  不带参数     自动探测上游最新版本并下载"
      echo "  版本号       下载指定版本，如 v1.0.0-rc.36"
      echo "  --force      本地已是该版本也强制重新下载"
      exit 0 ;;
    v*)
      TARGET_VER="$arg" ;;
    *)
      TARGET_VER="v$arg" ;;
  esac
done

# ---------- 检查 curl ----------
if ! command -v curl >/dev/null 2>&1; then
  echo "! 未找到 curl"
  if [ -d "$TERMUX_BIN" ]; then
    echo "  请在 Termux 里执行: pkg install curl"
  else
    echo "  请在 Termux 中运行本脚本: sh $0"
    echo "  （或在 Termux 里先: pkg install curl）"
  fi
  exit 1
fi

# ---------- 版本探测 ----------
# releases/latest 会 302 到 .../tag/vX.Y.Z，用 %{redirect_url} 拿真实 tag，
# 不依赖 GitHub API（有速率限制）也不依赖 jq。
# 顺序：直连 -> 镜像（国内网络 GitHub 直连常失败）-> GitHub API 兜底
detect_latest() {
  _probe() {
    _redir=$(curl -s --connect-timeout 8 --max-time 20 \
      -o /dev/null -w '%{redirect_url}' "$1" 2>/dev/null)
    _v=$(printf '%s' "$_redir" | grep -oE 'tag/v[0-9][^/]*' | head -n1 | cut -d/ -f2)
    [ -n "$_v" ] && { echo "$_v"; return 0; }
    return 1
  }
  _probe "$RELEASES_LATEST" && return 0
  _probe "https://ghfast.top/${RELEASES_LATEST}" && return 0
  _probe "https://ghproxy.net/${RELEASES_LATEST}" && return 0
  # GitHub API 兜底（未认证每小时 60 次，仅作备份）
  _v=$(curl -s --connect-timeout 8 --max-time 20 \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | \
    grep -oE '"tag_name": *"[^"]+"' | head -n1 | sed 's/.*: *"//;s/"$//')
  [ -n "$_v" ] && { echo "$_v"; return 0; }
  return 1
}

if [ -n "$TARGET_VER" ]; then
  VERSION="$TARGET_VER"
  echo "使用指定版本: $VERSION"
else
  echo ">> 探测上游最新版本..."
  LATEST=$(detect_latest)
  if [ -n "$LATEST" ]; then
    VERSION="$LATEST"
    echo "   上游最新版本: $VERSION"
  elif [ -s "$VERSION_FILE" ]; then
    VERSION=$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')
    echo "! 无法探测最新版本（网络问题），沿用本地记录: $VERSION"
    echo "  可手动指定版本重试: sh $0 v1.0.0-rc.36"
  else
    echo "! 无法探测最新版本，且未找到 $VERSION_FILE"
    echo "  请检查网络后重试，或手动指定版本: sh $0 v1.0.0-rc.36"
    exit 1
  fi
fi

# ---------- 同版本跳过 ----------
CUR_VER=""
[ -s "$VERSION_FILE" ] && CUR_VER=$(head -n1 "$VERSION_FILE" | tr -d '[:space:]')
if [ "$FORCE" -ne 1 ] && [ -f "$OUT" ] && [ -n "$CUR_VER" ] && [ "$CUR_VER" = "$VERSION" ]; then
  echo ""
  echo "================================================"
  echo "  ✓ 本地已是 $VERSION，跳过下载"
  echo "  强制重新下载: sh $0 --force"
  echo "================================================"
  exit 0
fi

GH="https://github.com/${REPO}/releases/download/${VERSION}/new-api-arm64-${VERSION}"
# 直连 + 镜像加速（依次尝试，哪个通就用哪个）
MIRRORS="
${GH}
https://ghfast.top/${GH}
https://ghproxy.net/${GH}
https://gh-proxy.com/${GH}
https://gh.h233.eu.org/${GH}
"

echo "================================================"
echo "  下载 New API ${VERSION} (arm64 动态链接, ~120MB，需配合 lib/ glibc)"
echo "================================================"
mkdir -p "$MODDIR/bin"
trap 'rm -f "$OUT.tmp"' INT TERM

for URL in $MIRRORS; do
  [ -z "$URL" ] && continue
  echo ""
  echo ">> 尝试: $URL"
  if curl -L -f -o "$OUT.tmp" --connect-timeout 15 --retry 2 --max-time 1800 "$URL"; then
    SIZE=$(wc -c < "$OUT.tmp" 2>/dev/null)
    [ -z "$SIZE" ] && SIZE=0
    # 验证 ELF 魔数: 头 4 字节 = 7f 'E' 'L' 'F'
    # 不用 od（Android toybox 的 od 与 coreutils 行为不一致），grep 对二进制匹配即可
    if head -c 4 "$OUT.tmp" 2>/dev/null | grep -q ELF && [ "$SIZE" -gt 50000000 ]; then
      mv "$OUT.tmp" "$OUT"
      # 写入版本号供 service.sh 在 buildinfo 提取失败时回退使用
      printf '%s\n' "$VERSION" > "$VERSION_FILE"
      echo ""
      echo "================================================"
      echo "  ✓ 下载成功"
      echo "  版本: $VERSION"
      echo "  路径: $OUT"
      echo "  大小: ${SIZE} 字节"
      echo "  ELF 验证: 通过"
      echo "================================================"
      echo ""
      echo "下一步 - 打包成 Magisk zip:"
      echo "  sh $MODDIR/pack.sh"
      echo "然后在 Magisk App 里刷入生成的 zip 并重启（数据在"
      echo "/data/adb/newapi，更新模块不会丢失）"
      exit 0
    else
      echo "  ✗ 文件无效 (size=$SIZE, 非 ELF 或过小)，尝试下一个镜像"
      rm -f "$OUT.tmp"
    fi
  else
    echo "  ✗ 下载失败，尝试下一个镜像"
    rm -f "$OUT.tmp"
  fi
done

echo ""
echo "================================================"
echo "  ✗ 所有自动镜像都失败"
echo "================================================"
echo "请手动下载:"
echo "  浏览器打开(可用代理/VPN):"
echo "  $GH"
echo "  下载后重命名为 new-api"
echo "  放到: $OUT"
echo "  同时创建 $VERSION_FILE，内容写版本号（如 $VERSION）"
echo "然后运行: sh $MODDIR/pack.sh"
exit 1
