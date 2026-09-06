# MosDNS OCI CT 一键重建脚本（PVE）

在 PVE 9.1+ 宿主机上一键重建 OCI MosDNS 容器（CT）：拉取最新镜像 → 创建特权容器 → 配置持久化 / GEO 规则数据 → 启动验证。国内+国外 DNS 分流 + 广告屏蔽 + 缓存（配置/规则参照 onekey-mosdns.sh）。

## 快速开始

在 PVE 宿主（root）上执行：

```bash
# 下载脚本（-O 强制覆盖，防止同名旧文件被 wget 存为 .N 后缀）
wget -O onekey-mosdns_oci.sh https://raw.githubusercontent.com/guochan2019/onekey-mosdns_oci/main/onekey-mosdns_oci.sh
# 运行（交互：容器 ID + root 密码 + IP/网关）
bash onekey-mosdns_oci.sh
```

## 脚本流程

| 步骤 | 说明 |
|------|------|
| ① 拉取 OCI 镜像 | 删除旧模板 → `skopeo copy` 拉取 `irinesistiana/mosdns:latest`（重建 = 取最新版本） |
| ② 创建容器 | 交互选择容器 ID（默认 104）、root 密码（不回显）、IP/网关；已存在则确认销毁重建；以 unprivileged 创建 |
| ③ 配置容器 | 首次：下载 GEO 数据 + 解包规则 + **交互输入本地/远程 DNS 上游** + 写入 config.yaml + 创建更新脚本/crontab（已存在则跳过保留）；删除 `unprivileged: 1` 转特权、`cmode: shell`、onboot/startup、挂载 `/opt/mosdns → /etc/mosdns` |
| ④ 启动验证 | 启动容器，验证 PID1=mosdns、挂载点容器内可见、DNS 三连（国内/国外解析 + 广告屏蔽） |

## 参数说明（脚本顶部变量，按需修改）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CTID` | 104（运行时交互可改） | 容器 ID |
| `CT_NAME` | OCI-MosDNS | 容器名称 |
| `CT_PASS` | 运行时交互输入（不回显） | 容器 root 密码 |
| `CT_IP` | 运行时交互输入（默认值见脚本） | 容器 IPv4（CIDR） |
| `CT_GW` | 运行时交互输入（默认值见脚本） | 默认网关 |
| `TPL_REF` | `docker://irinesistiana/mosdns:latest` | OCI 镜像（skopeo 源，需 `docker://` 前缀） |
| `ROOTFS` | `local:0.25` | 根磁盘（256 MB，实测镜像解包仅 ~27MB，数据全在挂载点） |
| `DATA_DIR` | `/opt/mosdns` | 配置/规则/日志目录（宿主侧，挂载到容器 `/etc/mosdns`） |
| `LOCAL_DNS_IPS` | 空（交互输入，回车默认 223.5.5.5/223.6.6.6） | 国内 DNS 上游（空格分隔纯 IP），首次部署交互输入 |
| `REMOTE_DNS_IPS` | 空（首次部署**必填**交互输入） | 远程 DNS 上游 tailnet IP（空格分隔，须为已部署 onekey-vps_dns 的 VPS）。🔴 **隐私：不写死仓库** |

## 自动更新

crontab 每周一 03:00 执行 `/opt/mosdns/update-mosdns_oci.sh`（宿主 root 下）：

1. **更新 GEO 数据** — 重下 `geoip.dat` + `geosite.dat`（Loyalsoldier/v2ray-rules-dat 最新 release），解包全部域名规则 + geoip CIDR（实测约 33 万条规则）
2. **重启容器重载** — `pct reboot <CTID>` 使新规则生效

更新日志：`/opt/mosdns/update-mosdns.log`。也可手动执行 `bash /opt/mosdns/update-mosdns_oci.sh`。

## 注意事项

1. **PVE 9.x OCI 特权创建已知 bug**：`--unprivileged 0` 创建必失败（`setgid(0): Invalid argument`，官方确认）。脚本先以 unprivileged 创建成功，再删除 conf 中的 `unprivileged: 1` 转为特权容器。
2. **`--cmode shell` 在 OCI 创建流程不写入 conf**，脚本用 `pct set` 显式设置。
3. **`/opt/mosdns` 存在即保留**：配置/规则持久化，重建容器不丢失（不存在则自动下载数据）。如需全新数据，先删除该目录再重跑。
4. **镜像事实**：`irinesistiana/mosdns:latest` 为 alpine 精简镜像（无 curl/dig），验证走宿主 python3 原生 DNS 查询；镜像 CMD `mosdns start --dir /etc/mosdns` 自动成为容器 PID1。
5. **GEO 数据**：首次运行下载 `geoip.dat`(17M) + `geosite.dat`(11M) 并解包 4 个规则文件（国内域名 / 国外域名 / 广告 / 国内 IP），存储在 `/opt/mosdns/`。
6. **日志**：`/opt/mosdns/mosdns.log`（容器写入挂载点，宿主可直接 tail）。国外上游部分超时 WARN 属正常降级（concurrent 机制首个成功即返回）。
7. **DNS 生效**：LAN 设备 DNS 指向容器 IP 即启用分流（国内域名→本地 DNS、国外域名→**tailnet VPS dnsmasq**（部署时输入的 `udp://100.x` 三台并发）、广告域名 NXDOMAIN 屏蔽）。
8. **IPv6 不配置**（net0 留空）；**DNS 设为 127.0.0.1**（PVE `--nameserver` 机制，容器内 `/etc/resolv.conf` 指向本机 mosdns——容器内程序解析走本地分流/缓存，不绕过）；MAC 由 PVE 随机生成；firewall=0。
9. **远程上游不依赖 daed（2026-09-06 架构变更）**：原 tls/https 直连 1.1.1.1/8.8.8.8 依赖 LinuxGate daed eBPF 劫持出墙；现改为 `udp://<tailnet VPS IP>`（VPS 上部署 dnsmasq，见 `guochan2019/onekey-vps_dns`）。🔴 **隐私：本地/远程 DNS 上游均首次部署交互输入，仓库零私有地址**（tailnet IP/本地运营商 DNS 不进 GitHub）。

## 验证

```bash
pct exec <CTID> -- cat /proc/1/comm          # 应输出 mosdns（镜像 CMD 自动生效）
dig +short @<CT-IP> www.baidu.com    # 国内解析 → 返回 IP
dig +short @<CT-IP> www.google.com   # 国外解析 → 返回 IP
dig +short @<CT-IP> doubleclick.net  # 广告屏蔽 → 空应答（NXDOMAIN）
tail -5 /opt/mosdns/mosdns.log        # 日志（宿主直接查看）
```

重建升级：重跑本脚本（镜像取最新，配置/规则保留）。
