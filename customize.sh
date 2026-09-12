#!/system/bin/sh
# ============================================================
#  customize.sh - Magisk/KSU 安装时执行
# ============================================================
ui_print "=================================="
ui_print "  New API for Magisk 模块安装中"
ui_print "=================================="

# 二进制为 aarch64 构建，架构不符直接中止
if [ "$ARCH" != "arm64" ]; then
  ui_print "! 设备架构: ${ARCH:-unknown}，本模块仅支持 arm64"
  abort "! 安装中止"
fi

ui_print "- 设置文件权限 ..."
set_perm_recursive "$MODDIR" 0 0 0755 0644
set_perm "$MODDIR/certs/ca-certificates.crt" 0 0 0644

# 二进制和库需要可执行权限（libc.so 若为指向 libc.so.6 的软链接则跳过，避免解引用）
set_perm "$MODDIR/bin/new-api"              0 0 0755
set_perm "$MODDIR/lib/ld-linux-aarch64.so.1" 0 0 0755
if [ -L "$MODDIR/lib/libc.so" ]; then
  set_perm "$MODDIR/lib/libc.so.6" 0 0 0755
else
  set_perm_recursive "$MODDIR/lib" 0 0 0755 0755
fi
set_perm "$MODDIR/service.sh"              0 0 0755
set_perm "$MODDIR/action.sh"               0 0 0755
set_perm "$MODDIR/update.sh"                0 0 0755
set_perm "$MODDIR/uninstall.sh"            0 0 0755
set_perm "$MODDIR/download-binary.sh"      0 0 0755
set_perm "$MODDIR/pack.sh"                 0 0 0755

# 数据目录
mkdir -p /data/adb/newapi/logs
set_perm /data/adb/newapi 0 0 0755

# 检查二进制
if [ ! -f "$MODDIR/bin/new-api" ]; then
  ui_print ""
  ui_print "! 警告: bin/new-api 二进制未找到"
  ui_print "! 请运行: sh $MODDIR/download-binary.sh"
else
  ui_print "- 二进制就绪"
  # 检查 glibc 库
  if [ -f "$MODDIR/lib/ld-linux-aarch64.so.1" ] && [ -f "$MODDIR/lib/libc.so.6" ]; then
    ui_print "- glibc 运行时就绪"
  else
    ui_print "! 警告: lib/ 下缺少 glibc 库文件"
    ui_print "! 需要: ld-linux-aarch64.so.1 + libc.so.6"
  fi
fi

ui_print "- 安装完成，重启后自动启动"
ui_print "- 管理面板: http://localhost:3100"
ui_print "- 首次访问 http://localhost:3100 按引导页初始化管理员账号"
ui_print "=================================="
