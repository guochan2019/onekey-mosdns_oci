#!/bin/bash
# ============================================================
# onekey-mosdns_oci — PVE 一键重建 OCI MosDNS CT（OCI-MosDNS）
# 适用环境: PVE 9.1+（OCI 支持），宿主 root 运行
# 功能: 拉 OCI 镜像 → 建特权 CT → 配置持久化/规则数据 → 启动验证
#       国内+国外DNS分流 + 广告屏蔽 + 缓存（配置/规则参照 onekey-mosdns.sh）
# 🔴 隐私: 本地/远程 DNS 上游均首次部署交互输入(LOCAL_DNS_IPS/REMOTE_DNS_IPS), 不写死进仓库
# ============================================================
set -e

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 检测 PVE 环境 ----------
command -v pct &>/dev/null || err "未找到 pct，请确认在 PVE 宿主上运行"
command -v pveam &>/dev/null || err "未找到 pveam"
command -v skopeo &>/dev/null || err "未找到 skopeo（PVE 9.1+ OCI 支持依赖）"
command -v wget &>/dev/null || err "未找到 wget（GEO 数据下载依赖）"
command -v python3 &>/dev/null || err "未找到 python3（GEO 数据解包依赖）"

# ---------- 配置 ----------
CTID=104
CT_NAME="OCI-MosDNS"
CT_IP="192.168.50.5/24"
CT_GW="192.168.50.1"
TPL_REF="docker://irinesistiana/mosdns:latest"
TPL_NAME="mosdns_latest.tar"
VZTPL_DIR="/var/lib/vz/template/cache"
ROOTFS="local:0.25"
DATA_DIR="/opt/mosdns"
RULE_DIR="${DATA_DIR}/rule"
UNPACK_SCRIPT="${DATA_DIR}/geoip-unpack.py"

# 国内 DNS 上游(forward_local, 空格分隔纯 IP) —— 首次部署交互输入, 可预设
# 空 = 交互输入; 交互提示默认 223.5.5.5/223.6.6.6(阿里公共无地域特征), 回车即用
LOCAL_DNS_IPS=""

# 远程 DNS 上游(forward_remote, 空格分隔纯 IP = tailnet VPS dnsmasq 的 100.x)
# 🔴 隐私: 不写死进仓库(暴露 tailnet 拓扑) —— 首次部署必填交互输入, 可预设
REMOTE_DNS_IPS=""

# ---------- 检测 local 存储模板目录 ----------
if [ ! -d "${VZTPL_DIR}" ]; then
  VZTPL_DIR=$(pveam list local 2>/dev/null | awk 'NR==2{print $2}' | sed 's|local:vztmpl/.*||')
  [ -n "${VZTPL_DIR}" ] || err "无法定位 vztmpl 目录，请检查 local 存储配置"
  VZTPL_DIR="${VZTPL_DIR}/vztmpl"
fi

# =================== ① 拉镜像 ===================
info "=== 1/4 拉取 OCI 镜像 ==="
# 重建目的为获取最新版本：模板存在则删除后重新拉取
if [ -f "${VZTPL_DIR}/${TPL_NAME}" ]; then
  info "  删除旧模板 ${TPL_NAME}（重建=拉取最新）"
  pveam remove "local:vztmpl/${TPL_NAME}"
fi
info "  拉取 ${TPL_REF} → ${VZTPL_DIR}/${TPL_NAME}"
skopeo copy "${TPL_REF}" "oci-archive:${VZTPL_DIR}/${TPL_NAME}"
info "  ✓ 模板拉取完成"

# =================== ② 建 CT ===================
info "=== 2/4 创建容器 ==="

# 选择容器 ID
read -p "请输入容器 ID (默认 104): " CTID_INPUT </dev/tty
CTID=${CTID_INPUT:-104}
CONF="/etc/pve/lxc/${CTID}.conf"
info "  容器 ID: ${CTID}"

# 输入 root 密码（不回显）
read -s -p "请输入容器 root 密码: " CT_PASS </dev/tty
echo ""
[ -n "${CT_PASS}" ] || err "密码不能为空"
info "  ✓ root 密码已设置（不回显）"

# 容器 IP / 网关（默认 192.168.50.5/24、192.168.50.1）
read -p "请输入容器 IP (默认 ${CT_IP}): " CT_IP_INPUT </dev/tty
CT_IP=${CT_IP_INPUT:-${CT_IP}}
read -p "请输入网关 IP (默认 ${CT_GW}): " CT_GW_INPUT </dev/tty
CT_GW=${CT_GW_INPUT:-${CT_GW}}
info "  容器 IP: ${CT_IP}（网关 ${CT_GW}）"

if pct status ${CTID} &>/dev/null; then
  warn "CT ${CTID} (${CT_NAME}) 已存在！"
  read -p "确认销毁并重建？(y/n，默认 n): " REBUILD </dev/tty
  if [ "${REBUILD:-n}" != "y" ] && [ "${REBUILD:-n}" != "Y" ]; then
    err "已取消，请手动处理 CT ${CTID}"
  fi
  pct stop ${CTID} 2>/dev/null || true
  pct destroy ${CTID} --purge
  info "  ✓ 旧 CT ${CTID} 已销毁"
fi

# 以 unprivileged 创建（PVE 9.x OCI 特权创建是已知 bug，③ 再删行转特权）
pct create ${CTID} "local:vztmpl/${TPL_NAME}" \
  --hostname "${CT_NAME}" --password "${CT_PASS}" \
  --rootfs "${ROOTFS}" --cores 1 --memory 512 --swap 0 \
  --net0 name=eth0,bridge=lan0,ip=${CT_IP},gw=${CT_GW},firewall=0 \
  --unprivileged 1 --cmode shell --start 0
info "  ✓ CT ${CTID} 已创建"

# =================== ③ 配置 ===================
info "=== 3/4 配置容器 ==="

# 3.1 数据准备（config/规则持久化，宿主侧；以 config.yaml 为准——不存在才新建，
#     目录存在但 config 缺失（如清空/删配置后重建）也会重新准备）
if [ ! -f "${DATA_DIR}/config.yaml" ]; then
  info "  初始化数据目录 ${DATA_DIR} ..."
  mkdir -p "${RULE_DIR}"

  # 下载 GEO 数据（Loyalsoldier/v2ray-rules-dat，与 onekey-mosdns.sh 同源）
  info "  --- 下载 GEO 数据 ---"
  echo -n "    下载 geoip.dat ... "
  wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "${DATA_DIR}/geoip.dat"
  echo "done ($(du -h "${DATA_DIR}/geoip.dat" | cut -f1))"
  echo -n "    下载 geosite.dat ... "
  wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "${DATA_DIR}/geosite.dat"
  echo "done ($(du -h "${DATA_DIR}/geosite.dat" | cut -f1))"

  # 安装 GEO 数据解包工具（与 onekey-mosdns.sh 同一脚本）
  cat > "${UNPACK_SCRIPT}" << 'UNPACKEOF'
#!/usr/bin/env python3
"""从 geoip.dat / geosite.dat 解包指定 tag 到纯文本"""
import struct, sys, ipaddress

def _read_varint(data, offset):
    result = 0; shift = 0
    while offset < len(data):
        byte = data[offset]
        result |= (byte & 0x7F) << shift
        shift += 7; offset += 1
        if not (byte & 0x80): return result, offset
    raise ValueError("truncated varint")

def _read_bytes(data, offset):
    length, offset = _read_varint(data, offset)
    return data[offset:offset + length], offset + length

def unpack_geoip(dat_path, target_tags):
    """解包 geoip.dat → CIDR 列表"""
    target_tags = set(target_tags)
    with open(dat_path, 'rb') as f: raw = f.read()
    offset = 0; results = []
    while offset < len(raw):
        field, offset = _read_varint(raw, offset)
        if (field & 0x7) != 2: continue
        length, offset = _read_varint(raw, offset)
        entry_data = raw[offset:offset + length]; offset += length
        if (field >> 3) != 1: continue
        eo = 0; country_code = None; cidrs = []
        while eo < len(entry_data):
            ef, eo = _read_varint(entry_data, eo)
            ew = ef & 0x7; en = ef >> 3
            if en == 1 and ew == 2:
                country_code, eo = _read_bytes(entry_data, eo)
                country_code = country_code.decode()
            elif en == 2 and ew == 2:
                cl, eo = _read_varint(entry_data, eo)
                cd = entry_data[eo:eo+cl]; eo += cl
                co = 0; ipb = None; pre = None
                while co < len(cd):
                    cf, co = _read_varint(cd, co)
                    cw = cf & 0x7; cn = cf >> 3
                    if cn == 1 and cw == 2:
                        ipb, co = _read_bytes(cd, co)
                    elif cn == 2 and cw == 0:
                        pre, co = _read_varint(cd, co)
                if ipb and pre is not None:
                    cidrs.append(f"{ipaddress.ip_address(ipb)}/{pre}")
        if country_code in target_tags:
            results.extend(cidrs)
    return results

_TYPE_MAP = {0: "keyword", 1: "regexp", 2: None, 3: "full"}

def unpack_geosite(dat_path, target_tags):
    """解包 geosite.dat → 域名列表"""
    target_tags = set(target_tags)
    with open(dat_path, 'rb') as f: raw = f.read()
    offset = 0; results = []
    while offset < len(raw):
        field, offset = _read_varint(raw, offset)
        if (field & 0x7) != 2: continue
        length, offset = _read_varint(raw, offset)
        entry_data = raw[offset:offset + length]; offset += length
        if (field >> 3) != 1: continue
        eo = 0; country_code = None; domains = []
        while eo < len(entry_data):
            ef, eo = _read_varint(entry_data, eo)
            ew = ef & 0x7; en = ef >> 3
            if en == 1 and ew == 2:
                country_code, eo = _read_bytes(entry_data, eo)
                country_code = country_code.decode()
            elif en == 2 and ew == 2:
                dl, eo = _read_varint(entry_data, eo)
                dd = entry_data[eo:eo+dl]; eo += dl
                do = 0; dtype = None; dval = None
                while do < len(dd):
                    df, do = _read_varint(dd, do)
                    dw = df & 0x7; dn = df >> 3
                    if dn == 1 and dw == 0:
                        dtype, do = _read_varint(dd, do)
                    elif dn == 2 and dw == 2:
                        dval, do = _read_bytes(dd, do)
                        dval = dval.decode()
                    else:
                        # skip unknown fields (e.g. attribute)
                        if dw == 0: _read_varint(dd, do)[1]
                        elif dw == 2:
                            sk, do = _read_varint(dd, do); do += sk
                if dval:
                    prefix = _TYPE_MAP.get(dtype)
                    if prefix:
                        domains.append(f"{prefix}:{dval}")
                    else:
                        domains.append(dval)
        if country_code in target_tags:
            results.extend(domains)
    return results

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <geoip|geosite> <dat_file> <tag> [tag...]", file=sys.stderr)
        sys.exit(1)
    mode = sys.argv[1]
    dat_path = sys.argv[2]
    tags = sys.argv[3:]
    if mode == "geoip":
        entries = unpack_geoip(dat_path, tags)
        entries.sort(key=lambda x: int(ipaddress.ip_address(x.split('/')[0])))
    elif mode == "geosite":
        entries = unpack_geosite(dat_path, tags)
        entries.sort()
    else:
        print(f"Unknown mode: {mode}", file=sys.stderr)
        sys.exit(1)
    for e in entries:
        print(e)
UNPACKEOF
  chmod +x "${UNPACK_SCRIPT}"
  info "  ✓ 解包脚本已安装"

  # 解包规则（与 onekey-mosdns.sh 相同的 4 个规则文件）
  info "  --- 解包规则 ---"
  echo -n "    解包 geosite_cn.txt ... "
  python3 "${UNPACK_SCRIPT}" geosite "${DATA_DIR}/geosite.dat" CN > "${RULE_DIR}/geosite_cn.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geosite_cn.txt") 条)"
  echo -n "    解包 geosite_geolocation-!cn.txt ... "
  python3 "${UNPACK_SCRIPT}" geosite "${DATA_DIR}/geosite.dat" GEOLOCATION-!CN > "${RULE_DIR}/geosite_geolocation-!cn.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geosite_geolocation-!cn.txt") 条)"
  echo -n "    解包 geosite_category-ads-all.txt ... "
  python3 "${UNPACK_SCRIPT}" geosite "${DATA_DIR}/geosite.dat" CATEGORY-ADS-ALL > "${RULE_DIR}/geosite_category-ads-all.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geosite_category-ads-all.txt") 条)"
  echo -n "    解包 geoip_cn.txt ... "
  python3 "${UNPACK_SCRIPT}" geoip "${DATA_DIR}/geoip.dat" CN > "${RULE_DIR}/geoip_cn.txt"
  echo "done ($(wc -l < "${RULE_DIR}/geoip_cn.txt") 条)"

  # 创建自定义规则模板文件
  for f in whitelist.txt blocklist.txt hosts.txt; do
    [ -f "${RULE_DIR}/$f" ] || touch "${RULE_DIR}/$f"
  done
  info "  ✓ 自定义规则模板已创建 (whitelist/blocklist/hosts)"

  # 写入 config.yaml（容器内路径 /etc/mosdns/...，参照 onekey-mosdns.sh）
  info "  --- 写入 config.yaml ---"
  cat > "${DATA_DIR}/config.yaml" << 'CONFIGEOF'
log:
  level: info
  file: "/etc/mosdns/mosdns.log"

api:
  http: "127.0.0.1:9091"

plugins:
  # ========== 域名/IP 数据集 ==========
  # 国内域名
  - tag: geosite_cn
    type: domain_set
    args:
      files: ["/etc/mosdns/rule/geosite_cn.txt"]

  # 国外域名
  - tag: geosite_no_cn
    type: domain_set
    args:
      files: ["/etc/mosdns/rule/geosite_geolocation-!cn.txt"]

  # 国内 IP
  - tag: geoip_cn
    type: ip_set
    args:
      files: ["/etc/mosdns/rule/geoip_cn.txt"]

  # 广告域名
  - tag: ad_domain
    type: domain_set
    args:
      files: ["/etc/mosdns/rule/geosite_category-ads-all.txt"]

  - tag: blocklist
    type: domain_set
    args:
      files: ["/etc/mosdns/rule/blocklist.txt"]

  - tag: whitelist
    type: domain_set
    args:
      files: ["/etc/mosdns/rule/whitelist.txt"]

  - tag: hosts
    type: hosts
    args:
      files: ["/etc/mosdns/rule/hosts.txt"]

  # ========== 缓存 ==========
  - tag: lazy_cache
    type: cache
    args:
      size: 20000
      lazy_cache_ttl: 86400
      dump_file: "./cache.dump"
      dump_interval: 600

  # ========== 转发 ==========
  # 转发至本地服务器（国内 DNS, 部署时按 LOCAL_DNS_IPS 生成）
  - tag: forward_local
    type: forward
    args:
      concurrent: 3
      upstreams:
__LOCAL_DNS_UPSTREAMS__

  # 转发至远程服务器（tailnet VPS dnsmasq, 部署时按 REMOTE_DNS_IPS 生成）
  - tag: forward_remote
    type: forward
    args:
      concurrent: 3
      upstreams:
__REMOTE_DNS_UPSTREAMS__

  # ========== 序列 ==========
  # 国内解析
  - tag: local_sequence
    type: sequence
    args:
      - exec: $forward_local

  # 国外解析
  - tag: remote_sequence
    type: sequence
    args:
      - exec: prefer_ipv4
      - exec: $forward_remote

  # 有响应终止返回
  - tag: has_resp_sequence
    type: sequence
    args:
      - matches: has_resp
        exec: accept

  # fallback 用本地服务器 sequence
  # 返回非国内 ip 则 drop_resp
  - tag: query_is_local_ip
    type: sequence
    args:
      - exec: $local_sequence
      - matches: "!resp_ip $geoip_cn"
        exec: drop_resp

  # fallback 用远程服务器 sequence
  - tag: query_is_remote
    type: sequence
    args:
      - exec: $remote_sequence

  # fallback 用远程服务器 sequence
  - tag: fallback
    type: fallback
    args:
      primary: query_is_remote
      secondary: query_is_remote
      threshold: 500
      always_standby: true

  # 查询国内域名
  - tag: query_is_local_domain
    type: sequence
    args:
      - matches: qname $geosite_cn
        exec: $local_sequence

  # 查询国外域名
  - tag: query_is_no_local_domain
    type: sequence
    args:
      - matches: qname $geosite_no_cn
        exec: $remote_sequence

  # ========== 主流程 ==========
  - tag: main_sequence
    type: sequence
    args:
      # 1. 白名单直通国内
      - matches: qname $whitelist
        exec: $forward_local
      - matches: has_resp
        exec: accept
      # 2. 广告拦截
      - matches: qname $ad_domain
        exec: reject 3
      - matches: qname $blocklist
        exec: reject 3
      - matches: qtype 65
        exec: reject 3
      # 3. 缓存命中
      - exec: $lazy_cache
      - matches: has_resp
        exec: accept
      # 4. 国内域名 → 国内 DNS
      - matches: qname $geosite_cn
        exec: $local_sequence
      - matches: has_resp
        exec: accept
      # 5. 非 CN 域名 → 远程 DNS
      - matches: qname $geosite_no_cn
        exec: $remote_sequence
      - matches: has_resp
        exec: accept
      # 6. 剩余域名 → fallback 双检
      - exec: $fallback

  # ========== 服务器 ==========
  - tag: udp_server
    type: udp_server
    args:
      entry: main_sequence
      listen: ":53"

  - tag: tcp_server
    type: tcp_server
    args:
      entry: main_sequence
      listen: ":53"
CONFIGEOF

  # ---- DNS 上游交互收集 + 占位符替换 (仅首次部署; 数据目录已存在的重建场景整段跳过) ----
  # 本地 DNS: 默认 223.5.5.5/223.6.6.6, 回车即用
  if [ -z "${LOCAL_DNS_IPS}" ]; then
    read -p "  国内 DNS 上游 IP(空格分隔, 默认 223.5.5.5 223.6.6.6): " LOCAL_DNS_INPUT </dev/tty
    LOCAL_DNS_IPS=${LOCAL_DNS_INPUT:-"223.5.5.5 223.6.6.6"}
  fi
  # 远程 DNS: 必填(tailnet VPS dnsmasq 的 100.x, 隐私不写死仓库)
  if [ -z "${REMOTE_DNS_IPS}" ]; then
    read -p "  远程 DNS 上游 tailnet IP(空格分隔, 如 100.x.x.x 100.y.y.y): " REMOTE_DNS_INPUT </dev/tty
    REMOTE_DNS_IPS=${REMOTE_DNS_INPUT}
  fi
  [ -n "${REMOTE_DNS_IPS}" ] || err "远程 DNS 上游不能为空(至少一个 VPS dnsmasq 的 tailnet IP)"
  python3 - "${DATA_DIR}/config.yaml" "${LOCAL_DNS_IPS}" "${REMOTE_DNS_IPS}" << 'PYEOF'
import re, sys
path = sys.argv[1]
def gen(ips, proto=""):
    lines = []
    for ip in ips.split():
        if not re.match(r'^\d{1,3}(\.\d{1,3}){3}$', ip):
            print(f"invalid IP: {ip}", file=sys.stderr)
            sys.exit(1)
        lines.append(f'        - addr: "{proto}{ip}"')
    return "\n".join(lines)
local_y = gen(sys.argv[2])           # 本地: 裸 IP (默认 53)
remote_y = gen(sys.argv[3], "udp://") # 远程: udp:// 前缀
s = open(path).read()
for ph, rep in [("__LOCAL_DNS_UPSTREAMS__", local_y), ("__REMOTE_DNS_UPSTREAMS__", remote_y)]:
    if ph not in s:
        print(f"placeholder {ph} not found", file=sys.stderr)
        sys.exit(1)
    s = s.replace(ph, rep)
open(path, "w").write(s)
print(f"  ✓ 本地 DNS {len(sys.argv[2].split())} 个, 远程 DNS {len(sys.argv[3].split())} 个")
PYEOF
  info "  ✓ config.yaml 已写入"

  # 更新脚本（每周 GEO 数据刷新 + 重启重载；crontab 每周一 03:00，与 onekey-mosdns.sh 同步）
  cat > "${DATA_DIR}/update-mosdns_oci.sh" << EOF
#!/bin/bash
set -e
CTID=${CTID}
DATA_DIR="${DATA_DIR}"
RULE_DIR="${RULE_DIR}"
UNPACK="${UNPACK_SCRIPT}"
LOG="${DATA_DIR}/update-mosdns.log"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG"; }
log "=== 开始更新 ==="
log "1/2 更新 GEO 数据..."
wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -O "\${DATA_DIR}/geoip.dat.new" || { log "  ✗ geoip.dat 下载失败"; exit 1; }
mv "\${DATA_DIR}/geoip.dat.new" "\${DATA_DIR}/geoip.dat"
wget -q "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" -O "\${DATA_DIR}/geosite.dat.new" || { log "  ✗ geosite.dat 下载失败"; exit 1; }
mv "\${DATA_DIR}/geosite.dat.new" "\${DATA_DIR}/geosite.dat"
python3 "\$UNPACK" geosite "\${DATA_DIR}/geosite.dat" CN              > "\${RULE_DIR}/geosite_cn.txt" 2>/dev/null
python3 "\$UNPACK" geosite "\${DATA_DIR}/geosite.dat" GEOLOCATION-!CN > "\${RULE_DIR}/geosite_geolocation-!cn.txt" 2>/dev/null
python3 "\$UNPACK" geosite "\${DATA_DIR}/geosite.dat" CATEGORY-ADS-ALL > "\${RULE_DIR}/geosite_category-ads-all.txt" 2>/dev/null
python3 "\$UNPACK" geoip   "\${DATA_DIR}/geoip.dat" CN                 > "\${RULE_DIR}/geoip_cn.txt" 2>/dev/null
CN_CNT=\$(wc -l < "\${RULE_DIR}/geosite_cn.txt")
REMOTE_CNT=\$(wc -l < "\${RULE_DIR}/geosite_geolocation-!cn.txt")
AD_CNT=\$(wc -l < "\${RULE_DIR}/geosite_category-ads-all.txt")
IP_CNT=\$(wc -l < "\${RULE_DIR}/geoip_cn.txt")
log "  ✓ 规则已更新: CN=\${CN_CNT}, Remote=\${REMOTE_CNT}, Ads=\${AD_CNT}, GeoIP_CN=\${IP_CNT}"
log "2/2 重启 CT \${CTID} 重载规则..."
pct reboot \${CTID}
log "✓ mosdns 已重启，更新完成"
EOF
  chmod +x "${DATA_DIR}/update-mosdns_oci.sh"
  # 🔴 子 shell 内必须 set +e：空 crontab 时 `crontab -l | grep -v` 的 grep 退出码 1，
  #    继承的 set -e 会杀死子 shell → echo 不执行 → crontab - 收到空输入（清空/不写入）
  (set +e; crontab -l 2>/dev/null | grep -v update-mosdns_oci; echo "0 3 * * 1 ${DATA_DIR}/update-mosdns_oci.sh >/dev/null 2>&1") | crontab -
  info "  ✓ 已创建 update-mosdns_oci.sh 并添加 crontab（每周一 03:00）"
  info "     📍 定时任务保存位置: root 用户 crontab（/var/spool/cron/crontabs/root），crontab -l 查看"
else
  info "  ${DATA_DIR}/config.yaml 已存在，跳过数据准备（保留配置与规则）"
fi

# 3.2 删除 unprivileged: 1（新建完成后转特权——PVE 9.x OCI 特权创建是已知 bug，
#     必须先以 unprivileged 建成，再删除该行转为特权容器）
sed -i '/^unprivileged: 1$/d' "${CONF}"
info "  ✓ 已删除 unprivileged: 1（转为特权容器）"

# 控制台模式 shell（OCI 创建流程未写入，需显式设置）
pct set ${CTID} --cmode shell
info "  ✓ 控制台模式已设为 shell"

# conf 增加 nameserver: 127.0.0.1（容器内解析走本机 mosdns，不绕过分流）
pct set ${CTID} --nameserver 127.0.0.1
info "  ✓ 已设置 nameserver: 127.0.0.1"

# 开机自启 + 启动顺序（DNS 基础设施：RouterOS order=1 → Tailscale order=2 → frpc order=3 → MosDNS order=4 → Jellyfin order=5）
pct set ${CTID} --onboot 1 --startup order=4,up=10
info "  ✓ 已设置 onboot=1、startup order=4,up=10"

# 挂载点：数据目录 → /etc/mosdns（镜像 VOLUME + CMD 工作目录，配置/规则/日志/缓存全落这里）
pct set ${CTID} --mp0 "${DATA_DIR},mp=/etc/mosdns"
info "  ✓ 挂载点已配置: ${DATA_DIR} → /etc/mosdns"

# =================== ④ 启动 + 验证 ===================
info "=== 4/4 启动并验证 ==="

pct start ${CTID}
info "  ✓ CT ${CTID} 已启动"

# 等容器就绪
for i in $(seq 1 30); do
  pct exec ${CTID} -- true 2>/dev/null && break
  sleep 1
done

# PID1 应为 mosdns（镜像 CMD 自动生效）
PROC1=$(pct exec ${CTID} -- cat /proc/1/comm 2>/dev/null || echo "?")
info "  容器 PID1 进程: ${PROC1}"

# 验证挂载点容器内可见（任一缺失即报错停止）
pct exec ${CTID} -- ls -d /etc/mosdns /etc/mosdns/rule >/dev/null
info "  ✓ 挂载点容器内可见"

# DNS 解析三连验证（镜像无 dig/curl，用宿主 python3 原生 DNS 查询直连容器 :53）
CT_IP_NET=${CT_IP%%/*}
info "  验证 DNS 解析（${CT_IP_NET}:53）..."
python3 - "${CT_IP_NET}" << 'PYEOF'
import socket, struct, random, sys

def build_query(domain):
    tid = random.randint(0, 0xFFFF)
    header = struct.pack('>HHHHHH', tid, 0x0100, 1, 0, 0, 0)
    qname = b''.join(bytes([len(p)]) + p.encode() for p in domain.split('.')) + b'\x00'
    return header + qname + struct.pack('>HH', 1, 1)

def query(server, domain, timeout=10):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(build_query(domain), (server, 53))
    try:
        data, _ = s.recvfrom(4096)
    except socket.timeout:
        return None
    finally:
        s.close()
    if len(data) < 12:
        return None
    flags = struct.unpack('>H', data[2:4])[0]
    rcode = flags & 0xF
    ancount = struct.unpack('>H', data[6:8])[0]
    return rcode, ancount

server = sys.argv[1]
ok = True

r = query(server, 'www.baidu.com')
if r is not None and r[0] == 0 and r[1] > 0:
    print(f"   国内域名 www.baidu.com .... OK (rcode={r[0]}, answers={r[1]})")
else:
    print(f"   国内域名 www.baidu.com .... FAIL (rcode={r[0] if r else 'timeout'})")
    ok = False

r = query(server, 'www.google.com')
if r is not None and r[0] == 0 and r[1] > 0:
    print(f"   国外域名 www.google.com ... OK (rcode={r[0]}, answers={r[1]})")
else:
    print(f"   国外域名 www.google.com ... FAIL (rcode={r[0] if r else 'timeout'})")
    ok = False

r = query(server, 'doubleclick.net')
if r is not None and r[0] == 3:
    print(f"   广告域名 doubleclick.net . OK (rcode=3 NXDOMAIN 已屏蔽)")
else:
    print(f"   广告域名 doubleclick.net . FAIL (rcode={r[0] if r else 'timeout'})")
    ok = False

sys.exit(0 if ok else 1)
PYEOF
info "  ✓ DNS 解析验证全部通过"

# =================== 完成 ===================
echo ""
info "========== 配置信息汇总 =========="
info "  CT ID        : ${CTID}"
info "  容器名称     : ${CT_NAME}"
info "  容器 IP      : ${CT_IP}（网关 ${CT_GW}）"
info "  DNS 服务     : ${CT_IP_NET}:53（udp/tcp）"
info "  API 接口     : http://127.0.0.1:9091（容器内）"
info "  配置目录     : ${DATA_DIR} → /etc/mosdns"
info "  日志文件     : ${DATA_DIR}/mosdns.log（宿主可直接 tail）"
info "  规则更新     : 每周一 03:00 crontab（${DATA_DIR}/update-mosdns_oci.sh）"
echo ""
info "=== 下一步 ==="
info "  LAN 设备 DNS 指向 ${CT_IP_NET} 即启用分流（国内/国外/广告屏蔽）"
info "  手动更新规则: bash ${DATA_DIR}/update-mosdns_oci.sh"
info "  重建升级    : 重跑本脚本（镜像取最新，配置/规则保留）"
