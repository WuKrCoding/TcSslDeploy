# TcSslDeploy

腾讯云 SSL 证书自动同步工具。对比本地证书与腾讯云 SSL 证书的过期时间，自动下载并部署最新证书。

> **当前版本仅支持 Nginx**（full chain 证书格式）。

## 功能特性

- **过期时间对比**：自动比对本地证书与腾讯云证书的过期时间，云端更新时自动同步
- **首次部署**：本地证书不存在时，可直接从腾讯云拉取证书部署
- **强制更新**：支持跳过对比，强制拉取最新证书部署
- **多证书管理**：单台服务器可管理多个域名的证书，配置自动持久化到 `config.json`
- **计划任务模式**：`--cron` 批量读取配置，定时自动检查并更新所有证书
- **自动注册 Crontab**：首次手动部署成功后，自动添加每日定时任务
- **状态过滤**：仅同步腾讯云上状态为 **已通过** 的有效证书
- **智能排序**：自动选择域名下**最迟过期**的可用证书
- **安全签名**：完整实现腾讯云 TC3-HMAC-SHA256 签名鉴权

## 依赖环境

- Bash
- curl
- openssl
- python3（推荐，用于 JSON 解析；无 python3 时自动回退到 sed）

## 快速安装

```bash
git clone https://github.com/WuKrCoding/TcSslDeploy.git ~/.tcssl_deploy
chmod +x ~/.tcssl_deploy/tcssl_deploy.sh
```

## 快速开始

### 1. 配置腾讯云 API 密钥

```bash
export TENCENTCLOUD_SECRET_ID="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export TENCENTCLOUD_SECRET_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

> 密钥需要具备 SSL 证书服务的查询权限（`QcloudSSLFullAccess` 或包含 `DescribeCertificates`、`DescribeCertificateDetail` 的自定义策略）。

### 2. 测试密钥是否可用

```bash
~/.tcssl_deploy/tcssl_deploy.sh -t
```

### 3. 首次部署证书

本地证书文件可以不存在，但必须指定 `-d` 域名：

```bash
~/.tcssl_deploy/tcssl_deploy.sh \
  -c /etc/nginx/ssl/example.com.crt \
  -k /etc/nginx/ssl/example.com.key \
  -d example.com \
  -r "systemctl restart nginx"
```

首次部署成功后，脚本会自动：
- 将证书配置及 API 密钥写入 `~/.tcssl_deploy/config.json`
- 自动注册 crontab 每日定时任务

### 4. 添加更多证书

为其他域名添加证书，配置会**增量追加**到 `config.json`：

```bash
~/.tcssl_deploy/tcssl_deploy.sh \
  -c /etc/nginx/ssl/another.com.crt \
  -k /etc/nginx/ssl/another.com.key \
  -d another.com
```

### 5. 计划任务模式（由 crontab 自动调用）

无需手动执行，crontab 每天会自动调用。如需手动触发：

```bash
~/.tcssl_deploy/tcssl_deploy.sh --cron
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `-c, --cert-file` | 证书文件路径（full chain 格式） |
| `-k, --key-file` | 私钥文件路径 |
| `-d, --domain` | 域名（不提供则从本地证书中提取；首次部署时必须指定） |
| `-r, --restart` | 证书更新后执行的重启命令（如 `systemctl restart nginx`） |
| `-f, --force` | 强制更新：跳过过期时间对比，直接部署 |
| `-n, --no-backup` | 不备份：直接覆盖现有证书文件 |
| `--cron` | 计划任务模式：读取 `config.json` 批量检查并更新所有证书 |
| `-q, --quiet` | 静默模式：只输出错误信息 |
| `-v, --verbose` | 详细模式：输出 API 原始响应等调试信息 |
| `-t, --test` | 测试腾讯云 API 密钥是否可用 |
| `-h, --help` | 显示帮助信息 |

## 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `TENCENTCLOUD_SECRET_ID` | 是 | 腾讯云 SecretId |
| `TENCENTCLOUD_SECRET_KEY` | 是 | 腾讯云 SecretKey |
| `TENCENTCLOUD_REGION` | 否 | 区域，默认 `ap-guangzhou` |

## 配置文件

脚本同目录下的 `config.json`，自动存储所有证书配置及 API 密钥：

```json
[
  {
    "domain": "example.com",
    "cert_file": "/etc/nginx/ssl/example.com.crt",
    "key_file": "/etc/nginx/ssl/example.com.key",
    "restart_cmd": "systemctl restart nginx",
    "secret_id": "xxx",
    "secret_key": "xxx",
    "region": "ap-guangzhou"
  }
]
```

- 每次手动部署成功后**自动写入/更新**
- 同一域名再次部署时**覆盖**旧记录
- 不同域名**增量追加**
- 文件权限自动设为 `600`

## Crontab 定时任务

首次手动部署成功后，脚本会自动检查并添加 crontab 任务：

```cron
0 2 * * * /path/to/tcssl_deploy/tcssl_deploy.sh --cron >> /var/log/tcssl_deploy_cron.log 2>&1
```

### 查看日志

```bash
tail -f /var/log/tcssl_deploy_cron.log
```

### 手动管理 crontab

如需调整执行时间或删除任务：

```bash
crontab -e
```

## 常见问题

**Q: `--cron` 模式下证书是否备份？**

`--cron` 模式默认**不保留备份**，避免长期运行产生大量备份文件。手动模式默认会自动备份（`.bak.时间戳`），可通过 `-n` 关闭。

**Q: 如何删除已记录的证书？**

直接编辑 `config.json`，删除对应域名的条目即可。

**Q: 能否用于非 Nginx 场景？**

当前版本仅支持 Nginx 的 full chain 证书格式。其他 Web 服务器（如 Apache、Traefik）的证书格式可能不兼容，后续版本会考虑扩展。

## 安全提示

- `config.json` 包含敏感密钥，文件权限已自动设为 `600`，请勿手动放宽权限
- 建议将 `tcssl_deploy` 目录放在非 Web 可访问的路径下
- SecretId/SecretKey 建议分配最小权限（仅 SSL 证书查询与下载权限）

## License

MIT
