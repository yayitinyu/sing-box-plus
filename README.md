# 🚀 Sing-Box-Plus

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**一键部署 20 节点多协议代理服务的 Bash 管理脚本**，基于 [sing-box](https://github.com/SagerNet/sing-box) 核心。

---

## ✨ 功能亮点

| 类别 | 详情 |
|------|------|
| **20 节点** | 10 直连 + 10 WARP 出口，每种协议各一个，互不冲突 |
| **10 种协议** | VLESS Reality · VLESS gRPC Reality · Trojan Reality · Hysteria2 · VMess WS · Hysteria2 obfs · SS2022 · Shadowsocks · TUIC v5 · AnyTLS |
| **版本智能升级** | 部署或更新时自动比对官方最新 Release，识别旧版自动升级并支持安全回滚 |
| **GeoFiles 更新** | 一键更新 GeoIP / GeoSite 数据库及 SRS 规则集，多 CDN 镜像防封锁自动切换 |
| **运行状态看板** | 实时查看主进程 PID、内存占用、20 节点端口监听监控、DNS 切换与证书到期倒计时 |
| **WARP 出口** | Cloudflare WARP 线路，解锁 Netflix / Disney+ 等流媒体更友好 |
| **DNS 故障切换** | Cloudflare DoH → Google DoH → UDP 1.0.0.1，连续失败确认与恢复冷却避免探测抖动重启 |
| **自定义路由** | 按域名 / geosite 指定出口或 block 阻断，支持同出口规则整理及 JSON 导入、导出 |
| **TLS 证书** | 自签证书 / 手动上传公开有效证书 / ACME 自动申请续期，三种模式一键切换 |
| **连接稳定** | TCP keepalive · 可调 UDP timeout · WARP 保活 · 全参数环境变量覆盖 |
| **彻底卸载** | 一键注销服务、关闭防火墙放行、清理二进制与残留数据，干净无痕 |
| **多发行版** | Debian / Ubuntu · CentOS / RHEL · Arch · openSUSE · 包管理器优先 + 二进制回退 |

---

## 📋 系统要求

- Linux VPS（推荐 Debian 11+ / Ubuntu 20.04+）
- Root 权限
- 20 个可用端口（脚本自动随机分配并配置防火墙）

---

## 🚀 快速开始

方法一：wget（推荐）

```bash
wget -O sbp.sh https://raw.githubusercontent.com/yayitinyu/sing-box-plus/main/sing-box-plus.sh && bash sbp.sh
```

方法二：curl

```bash
curl -fsSL -o sbp.sh https://raw.githubusercontent.com/yayitinyu/sing-box-plus/main/sing-box-plus.sh && bash sbp.sh
```

---

## ♻️ 已有服务器轻量更新

已部署节点的服务器可以只更新管理脚本、DNS 健康检查辅助脚本和定时器配置。

### 一键更新（推荐）

已装过本脚本的机器，直接用管理脚本自己拉取最新版：

```bash
sudo /root/sbp.sh --update-script
```

也可以在管理菜单里选 `11) 从 GitHub 更新管理脚本`。

它会下载最新脚本、校验语法与内容完整性（拒绝 404 页面等异常响应），
比对版本号，再走下面的轻量更新流程应用。版本号相同时会跳过，
需要强制覆盖时加 `SBP_FORCE_UPDATE=1`。默认源可用环境变量覆盖：

```bash
sudo SBP_REPO=yayitinyu/sing-box-plus SBP_BRANCH=main /root/sbp.sh --update-script
```

首次部署、或 `/root/sbp.sh` 已损坏无法执行时，用下面的手动方式。

### 手动更新

```bash
curl -fsSL \
  https://raw.githubusercontent.com/yayitinyu/sing-box-plus/main/sing-box-plus.sh \
  -o /tmp/sbp.sh
bash -n /tmp/sbp.sh
sudo bash /tmp/sbp.sh --update-runtime
```

以上两种方式都会把脚本安装到 `/root/sbp.sh`，并将更新前的文件备份到
`/opt/sing-box/backups/runtime-update-*`。它不会改写 `config.json`、节点凭证或端口，
也不会主动重启 `sing-box.service`；DNS 定时器原本未运行时会保持不运行。
若更新中途失败，会自动回滚到备份状态。

以后可直接运行 `/root/sbp.sh` 打开管理菜单。若要覆盖防抖默认值，可在更新时传入：

```bash
sudo DNS_FAILURE_THRESHOLD=4 DNS_RECOVERY_THRESHOLD=6 \
  DNS_SWITCH_COOLDOWN=900 bash /tmp/sbp.sh --update-runtime
```

---

## 📖 菜单功能

```text
=============================================================
 🚀 Sing-Box-Plus 管理脚本 v3.2.0 🚀
 脚本更新地址: https://github.com/yayitinyu/sing-box-plus
=============================================================
  服务状态: 运行中 (Active)  |  核心版本: sing-box v1.12.7
  系统加速: 已启用 BBR       |  证书模式: 自签证书
=============================================================
  【核心部署与运行】
    1) 安装 / 部署（20 节点，含旧版自动升级）
    2) 查看服务运行状态
    3) 查看节点分享链接
    4) 重启 sing-box 服务

  【配置与网络管理】
    5) 一键更换所有端口
    6) 域名、证书与 SNI 设置
    7) 自定义路由与分流规则
    8) 一键开启 BBR 加速

  【核心与规则维护】
    9) 更新 sing-box 核心版本
   10) 更新 GeoFiles 规则文件 (GeoIP/GeoSite/规则集)
   11) 从 GitHub 更新管理脚本
   12) 一键系统网络诊断
   13) 彻底卸载 Sing-Box-Plus

    0) 退出管理脚本
=============================================================
```

---

## 🔐 域名、证书与 SNI

主菜单 `6) 域名、证书与 SNI 设置` 可随时设置 **Hysteria2 / TUIC / AnyTLS** 的 TLS 证书，或修改 VLESS / Trojan Reality 使用的 SNI。部署流程不再重复询问证书设置；所有创建路径都直接使用已保存的配置。

### 1. 自签证书（默认）

- 无需域名，可直接生成
- AnyTLS、Hysteria2、TUIC v5 导入链接自动包含 `insecure=1`（允许不安全连接 / 跳过证书验证），无需在客户端进行繁琐的证书信任操作即可即开即用

### 2. 手动上传证书

- 将公开 CA 签发的 `fullchain.pem` 和未加密私钥上传到服务器
- 输入证书域名和两个文件的绝对路径
- 脚本自动验证：有效期、域名匹配、证书链完整性、公私钥配对
- **SNI 自动与域名保持一致**，避免域名不匹配报错

### 3. ACME 自动申请

- 输入已解析到服务器公网 IP 的域名（需 DNS only，关闭 CDN 代理）
- 使用 sing-box 内置 ACME 向 Let's Encrypt 申请证书并自动续期
- 优先使用 TCP 80 端口 HTTP-01 验证；若 80 被占用，回退到 TCP 443 TLS-ALPN-01

### Reality SNI

Reality SNI 可独立修改。脚本会同时更新服务端握手目标和 VLESS / Trojan Reality 导入链接；自签模式下还会重新签发与新 SNI 匹配的托管证书。

已部署时，修改域名、证书或 SNI 后，脚本会先校验新配置，再重启正在运行的服务并刷新 `/opt/sing-box/share-links.txt`。生成或重启失败时会恢复原配置和托管证书。

> 手动证书或 ACME 模式下，TLS 节点的地址和 SNI 始终使用证书域名。脚本不会再因证书异常自动降级到“允许不安全连接”。

### 重新签发自签证书

轻量更新（`--update-script` / `--update-runtime`）**不会重签证书**——它按设计不改写 `config.json`、也不重启服务。若曾修改过 Reality SNI，自签证书可能仍停留在旧域名。更新后如检测到不匹配，脚本会给出提示，可用：

```bash
sudo /root/sbp.sh --reissue-cert
```

或在菜单 `6) 域名、证书与 SNI 设置` 里选 `3) 重新签发自签证书`。该命令会重签、校验配置并重启 sing-box，失败时自动恢复原证书。仅对自签模式有效；手动 / ACME 证书不由脚本签发。

手动确认某台机器是否受影响：

```bash
grep ^REALITY_SERVER= /opt/sing-box/env.conf
openssl x509 -in /opt/sing-box/cert/fullchain.pem -noout -subject
```

---

## 🌐 节点说明

### 直连节点（10 个）

通过服务器本机 IP 直接出口访问互联网。

### WARP 节点（10 个，带 `-warp` 后缀）

流量经由 Cloudflare WARP 出口，适用于：

- 解锁 Netflix、Disney+、ChatGPT 等受地域限制的服务
- 规避服务器 IP 被目标网站封锁

### 自定义路由与默认出口

菜单 `7) 自定义路由与分流规则` 支持按目标网站指定出口分流，以及切换非 Warp 协议节点的默认出口 IP：

- **非 Warp 节点默认出口**：支持将 10 个直连协议节点（VLESS-Reality、Hysteria2、TUIC 等）的默认出口 IP 自由切换为已导入的其他 VPS 节点、本机双栈（`direct`）、本机 IPv4（`direct-ipv4`）、本机 IPv6（`direct-ipv6`）或 WARP。
- **自定义分流规则**：支持为特定域名或 geosite 指定专属出口，或选择 `block` 阻断连接。
- **导入与导出**：分流子菜单 `7)` 导入、`8)` 导出，包含规则顺序、关联规则集、远程出口配置和默认出口。
- **整理规则**：分流子菜单 `9)` 选择需要整理的出口（也支持 `block`），预览规则数量变化并确认合并。

> 本机 IPv4 / IPv6 出口通过绑定本机源地址实现。仅 IPv6 出口无法访问没有 AAAA 记录的站点；客户端直接以 IP 地址（而非域名）发起的连接不受解析策略约束。导入的远程节点走哪个 IP 栈出口由对端节点决定，本机无法配置。

| 出口类型 | 用途示例 |
|----------|----------|
| 本机 WARP | `geosite:netflix` 走 WARP 解锁流媒体 |
| 本机双栈直连 | 默认双栈出口，支持 IPv4 + IPv6 |
| 本机 IPv4 | `suffix:openai.com` 固定走 IPv4 出口 |
| 本机 IPv6 | 需要原生 IPv6 的场景 |
| block 阻断 | 添加规则时选择 `5) block`，例如阻断 `suffix:ads.example.com` 或 `geosite:category-ads-all` |
| 远程 VPS 节点 | 粘贴分享链接（VLESS / Trojan / Hy2 / VMess / SS / TUIC / AnyTLS / Socks5 / HTTP 等）或 sing-box outbound JSON 导入，可作为分流出口或设为非 Warp 节点默认出口 |

匹配项支持逗号或空格分隔，支持以下格式：

```text
geosite:netflix, suffix:openai.com, domain:example.com, keyword:google, regex:.*\.example\.org$
```

简写规则：

- `netflix` → 按 `geosite:netflix` 处理
- `example.com` → 按 `suffix:example.com` 处理

规则按列表顺序匹配，先匹配的规则优先；`block` 对直连和 WARP 入站均生效，底层使用 sing-box 的 [`reject` 动作](https://sing-box.sagernet.org/configuration/route/rule_action/#reject)。

整理默认只合并**相邻且目标相同**的规则，不跨过其他规则，保留原有匹配优先级。也可选择将该目标的**全部规则**合并到第一次出现的位置；该方式会提前后面的匹配分支，可能改变与其他出口或 block 规则的优先级，操作前会明确警告并要求确认。

合并结果使用 [`logical / or` 规则](https://sing-box.sagernet.org/configuration/route/rule/#logical-fields)，保留各分支原有的匹配条件和名称，不直接混合域名与规则集条件。未选中的规则、远程出口、规则集定义和默认出口保持不变；合并后的规则可正常显示、删除、导入及导出（需要 v3.2.1 或更新的管理脚本）。应用前自动备份到 `/opt/sing-box/backups/routes-organize-*`，配置检查或服务重启失败时回滚；取消或没有可合并项时不重写配置、不重启服务。

导入时输入本地 JSON 文件路径，然后选择：

- **合并（默认）**：追加新规则，保留现有优先级和默认出口；完全相同的规则不会重复添加。同名远程出口或规则集必须配置一致，否则取消导入。
- **替换**：确认后替换全部分流规则、规则集、远程出口和默认出口。可使用空规则文件清空这些设置。

导入支持本脚本导出的文件，也兼容原有 `routes.json`。导入会校验文件结构和依赖引用，再使用本机 sing-box 检查生成的配置；校验或服务重启失败时回滚。修改前的规则备份保存在 `/opt/sing-box/backups/routes-import-*`。使用 WARP 的配置需要先开启 WARP，本地规则集需要在目标服务器存在对应文件。

导出默认保存为 `/opt/sing-box/routes-export-时间戳.json`，权限为 `600`。**文件包含远程出口的认证信息，请妥善保管。** 以下为只包含一条 block 规则的示例：

```json
{
  "format": "sing-box-plus-routes",
  "version": 1,
  "rules": [
    {
      "name": "屏蔽广告",
      "domain_suffix": ["ads.example.com"],
      "action": "reject"
    }
  ],
  "rule_set": [],
  "outbounds": [],
  "default_outbound": "direct"
}
```

---

## 📂 文件结构

| 文件 | 路径 | 说明 |
|------|------|------|
| 主配置 | `/opt/sing-box/config.json` | sing-box 运行配置 |
| 环境配置 | `/opt/sing-box/env.conf` | 运行参数与功能开关 |
| 凭证信息 | `/opt/sing-box/creds.env` | UUID、密码、密钥 |
| 端口信息 | `/opt/sing-box/ports.env` | 20 个端口分配 |
| 导入链接 | `/opt/sing-box/share-links.txt` | 自动刷新的 20 个链接，仅 root 可读 |
| WARP 配置 | `/opt/sing-box/warp.env` | WireGuard 密钥与端点 |
| 自定义路由 | `/opt/sing-box/routes.json` | 用户自定义路由规则 |
| 证书目录 | `/opt/sing-box/cert/` | TLS 证书与私钥 |
| 规则目录 | `/opt/sing-box/data/` | GeoIP / GeoSite 及 SRS 规则集 |
| 重启记录 | `/opt/sing-box/restart.log` | 服务启停日志 |
| DNS 切换记录 | `/opt/sing-box/dns-health.log` | DNS 上游切换日志 |
| 诊断报告 | `/opt/sing-box/diagnostics/` | 网络诊断快照 |
| 管理脚本 | `/root/sbp.sh` | 轻量更新后安装的脚本入口 |
| 更新备份 | `/opt/sing-box/backups/` | 轻量更新前的运行时文件快照 |

---

## ⚙️ 环境变量

可在运行脚本前通过环境变量自定义行为：

```bash
# 指定 sing-box 版本（推荐 1.13+）
SINGBOX_TAG=v1.13.13 bash sbp.sh

# 跳过启动依赖检查
SBP_SKIP_DEPS=1 bash sbp.sh

# 强制二进制模式（跳过包管理器）
SBP_BIN_ONLY=1 bash sbp.sh

# 调整连接参数
UDP_TIMEOUT=15m TCP_KEEP_ALIVE=30s TCP_KEEP_ALIVE_INTERVAL=30s \
WARP_KEEPALIVE_INTERVAL=25 DNS_HEALTH_INTERVAL=2m \
DNS_FAILURE_THRESHOLD=3 DNS_RECOVERY_THRESHOLD=5 DNS_SWITCH_COOLDOWN=600 bash sbp.sh
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SINGBOX_TAG` | `latest` | sing-box 发行版本号 |
| `SBP_SKIP_DEPS` | `0` | 设为 `1` 跳过启动时依赖检查 |
| `SBP_BIN_ONLY` | `0` | 设为 `1` 强制走二进制下载 |
| `SBP_SOFT` | `0` | 设为 `1` 宽松模式（依赖安装失败时继续） |
| `SBP_REPO` | `yayitinyu/sing-box-plus` | `--update-script` 拉取脚本的 GitHub 仓库 |
| `SBP_BRANCH` | `main` | `--update-script` 拉取脚本的分支 |
| `SBP_FORCE_UPDATE` | `0` | 设为 `1` 时版本号相同也强制覆盖更新 |
| `TCP_KEEP_ALIVE` | `30s` | TCP 保活时间 |
| `TCP_KEEP_ALIVE_INTERVAL` | `30s` | TCP 保活探测间隔 |
| `UDP_TIMEOUT` | `10m` | UDP NAT 过期时间 |
| `WARP_KEEPALIVE_INTERVAL` | `25` | WARP WireGuard 保活间隔（秒） |
| `DNS_HEALTH_INTERVAL` | `2m` | DNS 健康检查周期 |
| `DNS_FAILURE_THRESHOLD` | `3` | 连续多少次探测确认后才切换到备用 DNS |
| `DNS_RECOVERY_THRESHOLD` | `5` | 连续多少次探测确认后才恢复到优先 DNS |
| `DNS_SWITCH_COOLDOWN` | `600` | 故障切换后恢复优先 DNS 的最短冷却时间（秒） |

网络参数会持久保存到 `/opt/sing-box/env.conf`。

---

## 📱 客户端导入

安装完成后会输出并保存 20 个分享链接到 `/opt/sing-box/share-links.txt`，可直接导入以下客户端：

- **v2rayN** / **v2rayNG**
- **Clash Meta** / **Mihomo**
- **NekoBox** / **sing-box 客户端**
- **Shadowrocket** / **Quantumult X**

> 💡 AnyTLS 使用 `h2` / `http/1.1` ALPN，分享链接附带 `fp=chrome`。部分客户端可能不支持直接导入 AnyTLS 链接，可按输出的服务器、端口、SNI、ALPN 和密码手动添加。

---

## 🔧 常见问题

<details>
<summary><b>Hysteria2 / TUIC / AnyTLS 报域名不匹配错误？</b></summary>

确认证书模式和 SNI 设置：
- **自签证书**：导入链接默认允许跳过证书校验（`insecure=1`），可直接连接使用
- **手动证书 / ACME**：确保域名 A 记录指向服务器 IP，脚本会自动将 SNI 设为与证书域名一致

如已部署但仍报错，运行脚本并进入 `6) 域名、证书与 SNI 设置` 修正设置；成功后服务配置和导入链接会自动更新。
</details>

<details>
<summary><b>如何更换端口？</b></summary>

运行脚本选择 `5) 一键更换所有端口`，脚本会重新随机分配 20 个不重复端口、更新配置、放行防火墙并重启服务。
</details>

<details>
<summary><b>WARP 注册失败？</b></summary>

部分 IP 段可能被 Cloudflare 限制注册 WARP。脚本会自动禁用 WARP 节点，直连 10 个节点仍可正常使用。
</details>

<details>
<summary><b>ACME 证书申请失败？</b></summary>

- 确认域名 A 记录已指向服务器公网 IP（DNS only，关闭 CDN 代理）
- 确认 TCP 80 或 443 端口未被其他程序占用
- 云平台安全组中需手动放行对应端口
</details>

---

## 🙏 致谢

- [sing-box](https://github.com/SagerNet/sing-box) — 核心代理引擎
- [wgcf](https://github.com/ViRb3/wgcf) — WARP 账户注册工具

---

## 📄 许可证

[MIT License](LICENSE)
