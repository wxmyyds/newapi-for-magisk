#!/system/bin/sh
# ============================================================
#  pack.sh - 把模块打包成可刷入的 Magisk zip
#  在 Termux/PC 中运行:  sh ./pack.sh
# ============================================================
MODDIR=${0%/*}
case "$MODDIR" in
  */*) ;;
  *) MODDIR="." ;;
esac
PARENT=${MODDIR%/*}
# 在模块目录内直接运行时 PARENT 会出错，兜底为上一级
[ "$PARENT" = "$MODDIR" ] && PARENT=".."
NAME=$(basename "$(cd "$MODDIR" && pwd)")
OUT="$(cd "$PARENT" && pwd)/${NAME}.zip"

echo "================================================"
echo "  打包 Magisk 模块"
echo "================================================"

# 检查二进制
if [ ! -f "$MODDIR/bin/new-api" ]; then
  echo "! 二进制未下载，先运行:"
  echo "  sh $MODDIR/download-binary.sh"
  exit 1
fi

# 检查打包工具：优先 zip，缺 zip 时用 python3 兜底（同样保留软链接与可执行权限）
if ! command -v zip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "! 需要 zip 或 python3 之一"
  echo "  (Termux: pkg install zip / PC: apt install zip)"
  exit 1
fi

rm -f "$OUT"

echo ">> 打包中..."
# 模块文件必须位于 zip 根目录（Magisk 官方规范；嵌套子目录在部分 Magisk/KSU 版本会安装失败）
# --symlinks 保留 lib/libc.so 等软链接；排除 git / 临时文件 / 手机数据备份 / 已产出的 zip
cd "$MODDIR" || exit 1
if command -v zip >/dev/null 2>&1; then
  zip -r --symlinks "$OUT" . \
    -x ".git/*" "*.zip" "bin/*.tmp" ".backup_phone/*" "*.DS_Store" \
    >/dev/null 2>&1
else
  python3 - "$MODDIR" "$OUT" <<'PYEOF' || exit 1
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
skip_dirs = {'.git', '.backup_phone'}
n = 0
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        if root == src:
            dirs[:] = sorted(d for d in dirs if d not in skip_dirs)
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src)
            if rel.endswith(('.zip', '.DS_Store')):
                continue
            if rel.startswith('bin/') and rel.endswith('.tmp'):
                continue
            if os.path.islink(full):
                zi = zipfile.ZipInfo(rel)
                zi.create_system = 3                      # unix
                zi.external_attr = 0o120777 << 16         # 符号链接 + 0777
                zf.writestr(zi, os.readlink(full))
            else:
                zf.write(full, rel)                       # zipfile 自动保留 unix 权限位
            n += 1
print(f"python3 打包完成，共 {n} 个条目")
PYEOF
fi

if [ -f "$OUT" ]; then
  SIZE=$(wc -c < "$OUT" 2>/dev/null)
  echo ""
  echo "================================================"
  echo "  ✓ 打包完成"
  echo "  文件: $OUT"
  echo "  大小: ${SIZE} 字节"
  echo "================================================"
  echo ""
  echo "刷入步骤:"
  echo "  1. 打开 Magisk App"
  echo "  2. 模块 → 从存储安装"
  echo "  3. 选择 ${NAME}.zip"
  echo "  4. 重启手机，自动启动 New API"
  echo "  5. 访问 http://localhost:3100，按引导页初始化管理员账号"
else
  echo "✗ 打包失败"
  exit 1
fi
