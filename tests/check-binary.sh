#!/bin/sh
# ============================================================
#  check-binary.sh - 校验 bin/new-api（CI 打包前，需先 download-binary.sh）
#  用法: sh tests/check-binary.sh
# ============================================================
BIN="bin/new-api"
FAIL=0

[ -f "$BIN" ] || { echo "✗ 缺少 $BIN（先运行 sh download-binary.sh）"; exit 1; }

echo "== 校验 $BIN"

# ELF 魔数
if head -c 4 "$BIN" 2>/dev/null | grep -q ELF; then
  echo "  ✓ ELF 魔数"
else
  echo "  ✗ 非 ELF（镜像可能返回了错误页）"; FAIL=1
fi

# 架构 aarch64
if file "$BIN" 2>/dev/null | grep -q aarch64; then
  echo "  ✓ 架构 aarch64"
else
  echo "  ✗ 架构不符（需 arm64 动态链接）"; file "$BIN"; FAIL=1
fi

# 动态链接（interpreter 指向模块自带的 ld-linux）
if readelf -l "$BIN" 2>/dev/null | grep -q "ld-linux-aarch64"; then
  echo "  ✓ glibc 动态链接（interpreter: ld-linux-aarch64.so.1）"
else
  echo "  ✗ 非 glibc 动态链接（模块依赖 lib/ 运行时）"; FAIL=1
fi

# 动态依赖：仅 libc.so.6（lib/ 已内置）
NEEDED=$(readelf -d "$BIN" 2>/dev/null | grep NEEDED | grep -oE '\[[^]]+\]' | tr -d '[]')
if [ -n "$NEEDED" ] && [ "$NEEDED" = "libc.so.6" ]; then
  echo "  ✓ 动态依赖仅 libc.so.6（lib/ 内置）"
else
  echo "  ✗ 动态依赖异常: ${NEEDED:-（无）}（lib/ 可能缺库）"; FAIL=1
fi

# GLIBC 版本兼容（内置 libc 须不低于二进制所需）
if command -v objdump >/dev/null 2>&1; then
  _MAXREQ=$(objdump -T "$BIN" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -n1)
  _MAXHAVE=$(objdump -T lib/libc.so.6 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -Vu | tail -n1)
  echo "  ✓ GLIBC 需求 ≤ $_MAXREQ，lib/ 提供 ≤ $_MAXHAVE"
fi

# buildinfo 版本提取（service.sh 同款逻辑）
_VER=$(tail -c 8388608 "$BIN" 2>/dev/null | \
  grep -aoE 'github\.com/QuantumNous/new-api[[:space:]]+v[0-9][^[:space:]]*' | \
  head -n1 | awk '{print $2}' | sed 's/+dirty$//')
if [ -n "$_VER" ]; then
  echo "  ✓ buildinfo 版本提取: $_VER"
else
  echo "  ✗ 无法从 buildinfo 提取版本（运行时可回退 bin/VERSION）"; FAIL=1
fi

# 体积
_SIZE=$(wc -c < "$BIN" 2>/dev/null || echo 0)
if [ "$_SIZE" -gt 50000000 ]; then
  echo "  ✓ 体积 ${_SIZE} 字节"
else
  echo "  ✗ 体积异常（${_SIZE} 字节）"; FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "二进制校验通过"
  exit 0
else
  echo "二进制校验失败"
  exit 1
fi
