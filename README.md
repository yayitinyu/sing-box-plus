# Sing-Box-Plus

一键部署 18 节点代理服务的 Bash 脚本，基于 [Sing-Box](https://github.com/SagerNet/sing-box) 核心。

## 功能特点

- **18 个代理节点**：9 个直连 + 9 个 WARP 出口（解锁流媒体更友好）
- **支持协议**：VLESS Reality、VLESS gRPC、Trojan Reality、Hysteria2、VMess WS、SS2022、SS、TUIC v5
- **全自动化**：依赖安装、证书生成、防火墙配置、BBR 加速
- **多发行版支持**：Debian/Ubuntu、CentOS/RHEL、Arch、openSUSE

## 系统要求

- Linux VPS（推荐 Debian 11+ / Ubuntu 20.04+）
- Root 权限
- 开放 18 个随机端口（脚本自动配置防火墙）

## 快速开始

```bash
# 方法一：wget 下载后运行（推荐）
wget -O sbp.sh https://raw.githubusercontent.com/yayitinyu/sing-box-plus/main/sing-box-plus.sh
bash sbp.sh

# 方法二：curl 下载后运行
curl -fsSL -o sbp.sh https://raw.githubusercontent.com/yayitinyu/sing-box-plus/main/sing-box-plus.sh
bash sbp.sh
```

> ⚠️ **注意**：本脚本为交互式菜单，不支持 `curl | bash` 管道方式运行。

## 菜单选项

| 选项 | 功能 |
|------|------|
| 1 | 安装/部署（18 节点） |
| 2 | 查看分享链接 |
| 3 | 重启服务 |
| 4 | 一键更换所有端口 |
| 5 | 一键开启 BBR |
| 8 | 卸载 |
| 0 | 退出 |

## 节点说明

### 直连节点（9 个）
直接通过服务器 IP 出口访问互联网。

### WARP 节点（9 个，带 `-warp` 后缀）
流量经由 Cloudflare WARP 出口，适用于：
- 解锁 Netflix、Disney+ 等流媒体
- 规避服务器 IP 被封锁

## 配置文件位置

| 文件 | 路径 |
|------|------|
| 主配置 | `/opt/sing-box/config.json` |
| 凭证信息 | `/opt/sing-box/creds.env` |
| 端口信息 | `/opt/sing-box/ports.env` |
| WARP 配置 | `/opt/sing-box/warp.env` |
| 证书 | `/opt/sing-box/cert/` |

## 环境变量

可通过环境变量自定义部分配置：

```bash
# 指定 sing-box 版本
SINGBOX_TAG=v1.12.7 bash sbp.sh

# 跳过启动依赖检查
SBP_SKIP_DEPS=1 bash sbp.sh

# 强制二进制模式（跳过包管理器）
SBP_BIN_ONLY=1 bash sbp.sh
```

## 客户端导入

安装完成后会输出 18 个分享链接，可直接导入：
- v2rayN / v2rayNG
- Clash Meta / Mihomo
- NekoBox / sing-box 客户端
- Shadowrocket / Quantumult X

## 致谢

- [Sing-Box](https://github.com/SagerNet/sing-box) - 核心代理程序
- [wgcf](https://github.com/ViRb3/wgcf) - WARP 账户注册工具
- 原作者 Alvin9999

## 许可证

MIT License