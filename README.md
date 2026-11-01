# New API for Magisk

将 [New API](https://github.com/QuantumNous/new-api) 作为 Magisk 模块运行。模块仅支持 arm64，默认监听 `3100` 端口。

## 安装

1. 从 [Releases](https://github.com/wxmyyds/newapi-for-magisk/releases/latest) 下载模块 ZIP。
2. 在 Magisk 中选择“模块 → 从存储安装”，刷入 ZIP 并重启。
3. 打开 `http://localhost:3100`，按首次启动引导创建管理员账号。

## 从源码打包

需要 `curl` 或 `wget`，以及 `zip` 或 `python3`。在仓库目录运行：

```sh
sh update.sh          # 下载上游最新版并准备打包
# sh update.sh v1.0.0-rc.36  # 下载指定版本
sh pack.sh
```

生成的 `newapi-for-magisk.zip` 位于仓库的上一级目录。将其刷入并重启即可。下载时会校验二进制格式和文件大小；镜像下载不提供签名校验。

## 配置与管理

- 面板：`http://localhost:3100`
- 出站代理：编辑 `/data/adb/newapi/proxy.conf`，填写一行 `http://`、`https://`、`socks5://` 或 `socks5h://` 地址；留空或注释表示直连。修改后用 Magisk 模块“操作”按钮先停止、再启动服务。
- 模块“操作”按钮用于启动或停止服务；服务也会在开机后自动启动，并在异常退出时尝试重启。
- 服务日志：`/data/adb/newapi/service.log`；程序输出：`/data/adb/newapi/stdout.log`。

## 数据与卸载

SQLite 数据库、日志和配置保存在 `/data/adb/newapi/`，不会随模块更新或卸载删除。卸载后如需清除数据，可手动删除该目录。

## 验证

```sh
sh tests/verify.sh
sh tests/check-binary.sh  # 需先下载二进制；需要 file、readelf
```

CI 在普通提交时运行脚本验证；发布标签或手动触发时还会下载、校验二进制并打包模块。
