# New API for Magisk

本地 AI API 中转站（New API），开机自启，整合多供应商，按渠道关键词筛选模型。

## 快速使用

```bash
# 1. 下载二进制（在模块目录内运行，自动尝试多个镜像）
cd /storage/emulated/0/project/newapi-for-magisk  # 改成你的实际路径
sh ./download-binary.sh

# 2. 打包成 Magisk zip
sh ./pack.sh    # 生成上一级目录的 newapi-for-magisk.zip

# 3. 打开 Magisk App → 模块 → 从存储安装 → 选 newapi-for-magisk.zip → 重启

# 4. 重启后访问 http://localhost:3100
#    首次访问会进入初始化引导页，按提示设置管理员账号密码
```

> `download-binary.sh` 自动探测上游最新版本号（直连 + 镜像 + API 三层兑底），
> 不再硬编码；也可指定版本：`sh download-binary.sh v1.0.0-rc.36`，`--force` 强制重下。

## 手机上直接更新（免打包重刷）

模块装好后，更新 New API 不用再下载→打包→刷入，直接在手机上原地替换二进制：

```bash
# Termux 里执行（需 root）
su -c "sh /data/adb/modules/newapi_for_magisk/update.sh"

# 指定版本 / 强制重下
su -c "sh /data/adb/modules/newapi_for_magisk/update.sh v1.0.0-rc.36"
su -c "sh /data/adb/modules/newapi_for_magisk/update.sh --force"
```

流程：自动探测最新版 → 下载 + ELF 校验 → 停服务 → 原地替换 `bin/new-api` → 自动重启守护。
数据在 `/data/adb/newapi`，更新不受影响。

- 下载器自动探测：curl / Termux curl / Magisk busybox wget / 系统 wget
- 校验通过才停服务，下载失败不影响正在运行的实例
- 刷入含 `update.sh` 的新 zip 一次后，以后更新都只需上面这一条命令

## 安全说明

- `update.sh` / `download-binary.sh` 从上游 [QuantumNous/new-api](https://github.com/QuantumNous/new-api)
  的 GitHub Releases 下载二进制；国内网络不通时会依次尝试
  `ghfast.top`、`ghproxy.net`、`gh-proxy.com`、`gh.h233.eu.org` 等第三方镜像加速
- 下载后会校验 ELF 魔数（`7f 45 4c 46`）与文件体积（>50MB），
  防止代理返回错误页；但对镜像本身不做签名校验，介意者请用代理直连下载
- 模块内置的 `lib/`（glibc 运行时）与 `certs/`（Mozilla CA bundle）
  来源于 Debian 发行版，仅用于在 Android 上运行 glibc 动态链接二进制
- 数据（SQLite 数据库、日志）全部保留在设备本地 `/data/adb/newapi/`，
  模块不采集、不上传任何数据

## 文件说明

| 文件 | 作用 |
|------|------|
| `module.prop` | 模块元信息（必需） |
| `service.sh` | 开机自启 + 崩溃守护（late_start 非阻塞） |
| `customize.sh` | 安装时设置权限 |
| `action.sh` | Magisk 里点“操作”按钮手动启停 |
| `update.sh` | 手机上直接更新二进制（探测最新版→下载→替换→重启，免打包重刷） |
| `uninstall.sh` | 卸载时停止进程（保留数据） |
| `download-binary.sh` | 下载 New API arm64 二进制用于打包（自动探测最新版本，成功后写 `bin/VERSION`） |
| `pack.sh` | 打包成可刷入的 zip |
| `bin/new-api` | 二进制本体（下载后生成） |

## 功能特性

- **开机自启**：late_start service 阶段启动，不阻塞开机
- **崩溃守护**：进程退出后 8 秒自动重启
- **DNS 修复**：纯 Go 二进制 resolv.conf 为空时自动写入
- **防重复启动**：PID 文件检查
- **端口预检**：3100 被占用时快速失败并写明日志，不陷入崩溃循环
- **资源降级**：renice + ionice 降低优先级，不抢开机资源
- **SQLite**：无需 MySQL，零额外内存
- **错误日志**：`ERROR_LOG_ENABLED=true`，日志页按"错误"类型筛选可见
- **版本号自动检测**：从二进制 Go buildinfo 提取，修复上游 v0.0.0 显示 bug

## 内存优化

- New API 约 80~150 MB
- 配合 ZRAM 模块可显著改善（3GB RAM 设备强烈建议）

## 常见问题

### 界面显示版本 v0.0.0？

上游官方二进制的构建 bug：release.yml 里 `-X 'new-api/common.Version=...'` 少了模块前缀，注入静默失败。
模块在 `service.sh` 里自动从二进制 Go buildinfo 提取真实版本并用 `VERSION` 环境变量覆盖，
升级二进制无需改任何配置；提取失败时回退读 `bin/VERSION`（`download-binary.sh` 下载成功时自动写入）。

### 日志页看不到模型报错？

上游默认关闭错误日志记录（仅能通过环境变量开启，后台设置里没有这个开关）。
模块已在 `service.sh` 里 `export ERROR_LOG_ENABLED=true`，重启后生效，只记录之后发生的错误。
注意：余额不足/令牌额度不足这类计费错误上游故意不记录，属正常现象；在日志页用"类型"筛选选"错误"查看。

## 管理操作

```bash
# 手动启动（root shell）
sh /data/adb/modules/newapi_for_magisk/service.sh

# 手动停止
sh /data/adb/modules/newapi_for_magisk/action.sh   # Magisk 里点按钮也行

# 查看日志
cat /data/adb/newapi/service.log
cat /data/adb/newapi/stdout.log

# 检查是否运行
kill -0 $(cat /data/adb/newapi/new-api.pid) && echo "运行中"
```

## 数据位置

- 进程数据：`/data/adb/newapi/`
- `one-api.db`（SQLite：渠道/令牌/用户）、`logs/`、`service.log`、`stdout.log`、CA 证书副本都在此目录下
- 数据库固定在数据目录：模块更新/卸载不影响数据
- 卸载模块保留数据，需手动 `rm -rf /data/adb/newapi` 才彻底清除
