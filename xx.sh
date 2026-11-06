#!/usr/bin/env bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}错误:${NC} $*" >&2; exit 1; }
warn()  { echo -e "${YELLOW}警告:${NC} $*"; }
info()  { echo -e "${CYAN}>>>${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }

detect_pkg_manager() {
    if command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        INSTALL_CMD="apk add --no-cache"
        UPDATE_CMD="apk update"
    elif command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum makecache"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        UPDATE_CMD="dnf makecache"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
        INSTALL_CMD="zypper install -y"
        UPDATE_CMD="zypper refresh"
    else
        error "不支持的包管理器，请手动安装 wget、tar、curl、openssl"
    fi
}

install_deps() {
    local deps="wget tar curl openssl"
    case $PKG_MANAGER in
        apk) $INSTALL_CMD $deps bash gcompat ;;
        apt) $UPDATE_CMD && $INSTALL_CMD $deps ;;
        yum|dnf|zypper) $UPDATE_CMD && $INSTALL_CMD $deps ;;
    esac
    for cmd in wget tar curl openssl; do
        command -v $cmd &>/dev/null || error "$cmd 安装失败"
    done
}

install_s5_deps() {
    [[ $ENABLE_S5 -eq 1 ]] || return 0
    info "安装 S5 家宽出口依赖 (openvpn, python3)..."
    case $PKG_MANAGER in
        apk) $INSTALL_CMD openvpn python3 ;;
        apt) $UPDATE_CMD && $INSTALL_CMD openvpn python3 ;;
        yum|dnf|zypper) $UPDATE_CMD && $INSTALL_CMD openvpn python3 ;;
    esac
    for cmd in openvpn python3; do
        command -v $cmd &>/dev/null || error "$cmd 安装失败"
    done
}

detect_init() {
    if command -v systemctl &>/dev/null; then
        INIT="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT="openrc"
    else
        error "未检测到 systemd 或 OpenRC"
    fi
    ok "init 系统: $INIT"
}

get_arch() {
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
    ok "系统架构: $ARCH"
}

uninstall_old() {
    local names=("sing-box" "mihomo")
    local dirs=("/etc/sing-box" "/etc/mihomo")
    local i
    for i in 0 1; do
        local svc="${names[$i]}"
        local dir="${dirs[$i]}"
        if [ -d "$dir" ] || [ -f "/etc/init.d/$svc" ] || [ -f "/lib/systemd/system/${svc}.service" ]; then
            warn "检测到已安装的 $svc，执行完整卸载..."
            if [ "$INIT" = "systemd" ]; then
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                rm -f "/lib/systemd/system/${svc}.service"
                systemctl daemon-reload 2>/dev/null || true
            elif [ "$INIT" = "openrc" ]; then
                rc-service "$svc" stop 2>/dev/null || true
                rc-update del "$svc" default 2>/dev/null || true
                rm -f "/etc/init.d/${svc}"
            fi
            rm -rf "$dir" "/var/log/$svc" "/run/${svc}.pid" "/tmp/${svc}"*
            ok "已卸载 $svc"
        fi
    done

    # 清理 S5 家宽出口相关
    if [ "$INIT" = "systemd" ]; then
        for c in jp us; do
            systemctl stop "vpngate-$c" 2>/dev/null || true
            systemctl disable "vpngate-$c" 2>/dev/null || true
            systemctl stop "vpngate-heal-$c.timer" 2>/dev/null || true
            systemctl disable "vpngate-heal-$c.timer" 2>/dev/null || true
            rm -f "/etc/systemd/system/vpngate-$c.service"
            rm -f "/etc/systemd/system/vpngate-heal-$c.service"
            rm -f "/etc/systemd/system/vpngate-heal-$c.timer"
            rm -f "/lib/systemd/system/vpngate-$c.service"
            rm -f "/lib/systemd/system/vpngate-heal-$c.service"
            rm -f "/lib/systemd/system/vpngate-heal-$c.timer"
        done
        systemctl daemon-reload 2>/dev/null || true
    fi
    rm -rf "/etc/sing-box/vpngate" "/etc/mihomo/vpngate" "/var/log/vpngate"
    rm -f /usr/local/bin/vpngate-fetch.sh /usr/local/bin/vpngate-heal.sh

    # 清理可能残留的 iptables NAT 端口跳跃规则（HY2）
    if command -v iptables &>/dev/null; then
        iptables -t nat -S PREROUTING 2>/dev/null | grep -E 'REDIRECT.*to-ports' | while read -r rule; do
            eval "iptables -t nat ${rule/-A/-D}" 2>/dev/null || true
        done
        if command -v ip6tables &>/dev/null; then
            ip6tables -t nat -S PREROUTING 2>/dev/null | grep -E 'REDIRECT.*to-ports' | while read -r rule; do
                eval "ip6tables -t nat ${rule/-A/-D}" 2>/dev/null || true
            done
        fi
    fi

    if [ -d "/etc/iptables" ]; then
        info "删除 iptables 持久化文件与软件包..."
        rm -rf /etc/iptables
        if command -v apk &>/dev/null; then
            apk del iptables ip6tables 2>/dev/null || true
        elif command -v apt-get &>/dev/null; then
            apt-get remove -y iptables iptables-persistent 2>/dev/null || true
        elif command -v dnf &>/dev/null; then
            dnf remove -y iptables iptables-services 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum remove -y iptables iptables-services 2>/dev/null || true
        elif command -v zypper &>/dev/null; then
            zypper remove -y iptables 2>/dev/null || true
        fi
    fi
}

install_core() {
    mkdir -p "$CORE_DIR/bin" "$CONF_DIR" "$LOG_DIR" "$CERT_DIR"

    if [[ "$CLIENT_TYPE" == "0" ]]; then
        local latest_url
        latest_url=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
        [[ -z $latest_url ]] && error "无法获取 sing-box 最新版本，请检查网络或 GitHub API 访问"
        local version=${latest_url#v}
        local download_url="https://github.com/SagerNet/sing-box/releases/download/${latest_url}/sing-box-${version}-linux-${ARCH}.tar.gz"
        info "下载 sing-box: $download_url"
        wget --no-check-certificate -O /tmp/sing-box.tar.gz "$download_url" || error "下载失败"
        tar -xzf /tmp/sing-box.tar.gz -C /tmp/ || error "解压失败"
        cp "/tmp/sing-box-${version}-linux-${ARCH}/sing-box" "$CORE_BIN"
        chmod +x "$CORE_BIN"
        rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${version}-linux-${ARCH}"
        ok "sing-box 安装完成: $($CORE_BIN version | head -n1)"
    else
        local latest_url
        latest_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
        [[ -z $latest_url ]] && error "无法获取 mihomo 最新版本，请检查网络或 GitHub API 访问"
        local download_url="https://github.com/MetaCubeX/mihomo/releases/download/${latest_url}/mihomo-linux-${ARCH}-${latest_url}.gz"
        info "下载 mihomo: $download_url"
        wget --no-check-certificate -O /tmp/mihomo.gz "$download_url" || error "下载失败"
        gunzip -c /tmp/mihomo.gz > "$CORE_BIN" || error "解压失败"
        chmod +x "$CORE_BIN"
        rm -f /tmp/mihomo.gz
        ok "mihomo 安装完成: $($CORE_BIN -v | head -n1)"
    fi
}

generate_cert() {
    local cert_file="$CERT_DIR/cert.pem"
    local key_file="$CERT_DIR/key.pem"
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        info "生成 TLS 证书..."
        if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$key_file" -out "$cert_file" -days 3650 -nodes -subj "/CN=$COMMON_SNI" -addext "subjectAltName=DNS:$COMMON_SNI" 2>/dev/null; then
            ok "证书生成完成（含 SAN）"
        else
            warn "openssl 不支持 -addext，使用不含 SAN 的证书（客户端需跳过验证）"
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$key_file" -out "$cert_file" -days 3650 -nodes -subj "/CN=$COMMON_SNI"
        fi
        chmod 600 "$key_file" "$cert_file"
        ok "证书生成完成: $cert_file"
    else
        ok "证书已存在，跳过生成"
    fi
    CERT_FILE="$cert_file"
    KEY_FILE="$key_file"
}

gen_s5_port() {
    local p
    while :; do
        p=$((RANDOM % 40001 + 10000))
        [[ "$p" == "${WS_PORT:-}" ]] && continue
        [[ "$p" == "${HY2_PORT:-}" ]] && continue
        [[ "$p" == "${REALITY_PORT:-}" ]] && continue
        echo "$p"
        return
    done
}

get_config_all() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo ""
    echo "UUID: $UUID"
    COMMON_SNI="apple.com"
    echo "域名: $COMMON_SNI"
    echo ""

    ENABLE_WS=0; ENABLE_HY2=0; ENABLE_VLESS_REALITY=0

    echo "请选择要安装的协议（可多选，用空格或逗号分隔，例如: 1 3 或 2）:"
    echo "  1) VLESS + WebSocket (无 TLS)"
    echo "  2) Hysteria2"
    echo "  3) VLESS + Reality + Vision"
    read -p "$(echo -e "${CYAN}请输入选项:${NC} ")" PROTO_CHOICE
    for n in ${PROTO_CHOICE//,/ }; do
        case "$n" in
            1) ENABLE_WS=1 ;;
            2) ENABLE_HY2=1 ;;
            3) ENABLE_VLESS_REALITY=1 ;;
        esac
    done
    if [[ $ENABLE_WS -eq 0 && $ENABLE_HY2 -eq 0 && $ENABLE_VLESS_REALITY -eq 0 ]]; then
        error "至少需要选择一个协议"
    fi
    echo "已选择: $([ $ENABLE_WS -eq 1 ] && printf 'WS ') $([ $ENABLE_HY2 -eq 1 ] && printf 'HY2 ') $([ $ENABLE_VLESS_REALITY -eq 1 ] && printf 'VLESS-Reality-Vision ')"

    if [[ $ENABLE_WS -eq 1 ]]; then
        echo ""; info "配置 VLESS + WebSocket (无 TLS)"
        read -p "$(echo -e "${CYAN}域名:${NC} ")" WS_DOMAIN
        [[ -z $WS_DOMAIN ]] && error "域名不能为空"
        echo "域名: $WS_DOMAIN"
        read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" WS_PORT
        [[ -z $WS_PORT ]] && WS_PORT=$((RANDOM % 40001 + 10000))
        echo "端口: $WS_PORT"
    fi

    if [[ $ENABLE_HY2 -eq 1 ]]; then
        echo ""; info "配置 Hysteria2"
        read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" HY2_PORT
        [[ -z $HY2_PORT ]] && HY2_PORT=$((RANDOM % 40001 + 10000))
        echo "端口: $HY2_PORT"
        read -p "$(echo -e "${CYAN}端口跳跃范围 (起始-结束，默认 51250-51259):${NC} ")" HY2_PORTS
        [[ -z $HY2_PORTS ]] && HY2_PORTS="51250-51259"
        if [[ ! "$HY2_PORTS" =~ ^[0-9]+-[0-9]+$ ]]; then
            warn "端口范围格式错误，使用默认 51250-51259"
            HY2_PORTS="51250-51259"
        fi
        echo "端口跳跃: $HY2_PORTS"
    fi

    if [[ $ENABLE_VLESS_REALITY -eq 1 ]]; then
        echo ""; info "配置 VLESS + Reality + Vision"
        read -p "$(echo -e "${CYAN}端口 (回车随机 10000-50000):${NC} ")" REALITY_PORT
        [[ -z $REALITY_PORT ]] && REALITY_PORT=$((RANDOM % 40001 + 10000))
        echo "端口: $REALITY_PORT"
        echo "Reality SNI / 伪装域名: $COMMON_SNI"

        info "生成 Reality 密钥对与 short_id ..."
        local keypair
        keypair=$("$CORE_BIN" generate reality-keypair 2>/dev/null) || error "生成 Reality 密钥对失败"
        REALITY_PRIVATE_KEY=$(echo "$keypair" | awk -F': ' '/PrivateKey/{print $2}' | tr -d '\r')
        REALITY_PUBLIC_KEY=$(echo "$keypair" | awk -F': ' '/PublicKey/{print $2}' | tr -d '\r')
        [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]] && error "解析 Reality 密钥对失败"
        REALITY_SHORT_ID=$("$CORE_BIN" generate rand --hex 8 2>/dev/null | tr -d '\r')
        [[ -z "$REALITY_SHORT_ID" ]] && REALITY_SHORT_ID=$(openssl rand -hex 4)
        ok "Reality 密钥与 short_id 生成完成"
    fi

    ENABLE_S5=0
    S5_PORT_JP=""
    S5_PORT_US=""
    S5_USER=""
    S5_PASS=""
    echo ""
    read -p "$(echo -e "${CYAN}是否添加 S5 日本/美国 VPNGate 家宽出口？[Y/n]:${NC} ")" ADD_S5
    if [[ "$ADD_S5" != "n" && "$ADD_S5" != "N" ]]; then
        if [[ "$INIT" != "systemd" ]]; then
            warn "S5 家宽出口依赖 systemd timer，当前 init=$INIT，已跳过 S5"
        else
            ENABLE_S5=1
            S5_USER="s5$(openssl rand -hex 4)"
            S5_PASS=$(openssl rand -hex 16)
            read -p "$(echo -e "${CYAN}日本 S5 端口 (回车随机 10000-50000):${NC} ")" S5_PORT_JP
            [[ -z "$S5_PORT_JP" ]] && S5_PORT_JP=$(gen_s5_port)
            if [[ ! "$S5_PORT_JP" =~ ^[0-9]+$ ]]; then
                warn "日本端口格式错误，改用随机端口"
                S5_PORT_JP=$(gen_s5_port)
            fi
            read -p "$(echo -e "${CYAN}美国 S5 端口 (回车随机 10000-50000):${NC} ")" S5_PORT_US
            [[ -z "$S5_PORT_US" ]] && S5_PORT_US=$(gen_s5_port)
            if [[ ! "$S5_PORT_US" =~ ^[0-9]+$ ]]; then
                warn "美国端口格式错误，改用随机端口"
                S5_PORT_US=$(gen_s5_port)
            fi
            while [[ "$S5_PORT_US" == "$S5_PORT_JP" ]]; do
                S5_PORT_US=$(gen_s5_port)
            done
            echo "S5 日本端口: $S5_PORT_JP"
            echo "S5 美国端口: $S5_PORT_US"
            echo "S5 用户名: $S5_USER"
            echo "S5 密码: $S5_PASS"
        fi
    fi
    echo ""
}

setup_vpngate() {
    [[ $ENABLE_S5 -eq 1 ]] || return 0
    install_s5_deps

    local work_dir="$CORE_DIR/vpngate"
    mkdir -p "$work_dir" /var/log/vpngate
    local openvpn_bin
    openvpn_bin=$(command -v openvpn)
    printf 'vpn\nvpn\n' > "$work_dir/auth.txt"
    chmod 600 "$work_dir/auth.txt"

    cat > /usr/local/bin/vpngate-fetch.sh <<'FETCHEOF'
#!/usr/bin/env bash
set -euo pipefail

country="$1"
core_dir="$2"
max_try="${3:-15}"
work_dir="$core_dir/vpngate"
mkdir -p "$work_dir"
csv_file="$work_dir/vglist.csv"
candidates_file="$work_dir/candidates.txt"

curl -s --max-time 30 https://www.vpngate.net/api/iphone/ -o "$csv_file" || exit 1

python3 - "$csv_file" "$country" "$max_try" > "$candidates_file" <<'PY'
import csv, sys, io
csv_file, country, max_try = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(csv_file, newline='', encoding='utf-8-sig', errors='ignore') as f:
    lines = f.readlines()
data = ''.join([l for l in lines if not l.startswith('*') and not l.startswith('#')])
reader = csv.DictReader(io.StringIO(data))
rows = []
for r in reader:
    if r.get('CountryShort', '').upper() == country.upper():
        try:
            score = int(r.get('Score', '0') or 0)
        except Exception:
            score = 0
        rows.append((score, r))
rows.sort(key=lambda x: x[0], reverse=True)
for score, r in rows[:max_try]:
    print(f"{r.get('IP','')}\t{score}\t{r.get('OpenVPN_ConfigData_Base64','')}")
PY

exclude_ip=""
for f in "$work_dir"/jp.ip "$work_dir"/us.ip; do
    [ -f "$f" ] && exclude_ip+="$(cat "$f")\n"
done

while IFS=$'\t' read -r ip score b64; do
    [ -z "$ip" ] && continue
    if echo -e "$exclude_ip" | grep -qx "$ip"; then
        continue
    fi
    tmp_ovpn="$work_dir/tmp-${country}.ovpn"
    echo "$b64" | base64 -d > "$tmp_ovpn" 2>/dev/null || continue
    dev="tun-test-${country}-$$"
    authfile="$work_dir/auth-test.txt"
    printf 'vpn\nvpn\n' > "$authfile"
    log="$work_dir/test-${country}.log"
    openvpn --config "$tmp_ovpn" --dev "$dev" --route-nopull \
        --pull-filter ignore "dhcp-option" \
        --auth-user-pass "$authfile" --auth-nocache --verb 3 --log "$log" &
    pid=$!
    ok=0
    for i in $(seq 1 20); do
        if ip -4 addr show dev "$dev" 2>/dev/null | grep -q 'inet '; then
            break
        fi
        sleep 1
    done
    if ip -4 addr show dev "$dev" 2>/dev/null | grep -q 'inet '; then
        out=$(curl -s --max-time 15 --interface "$dev" https://ipinfo.io/json 2>/dev/null || true)
        if echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("country","").upper()==sys.argv[1].upper() else 1)' "$country" 2>/dev/null; then
            ok=1
            mv "$tmp_ovpn" "$work_dir/$country.ovpn"
            echo "$ip" > "$work_dir/$country.ip"
        fi
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    ip link del "$dev" 2>/dev/null || true
    rm -f "$tmp_ovpn" "$authfile" "$log"
    if [ "$ok" = "1" ]; then
        exit 0
    fi
done < "$candidates_file"

exit 1
FETCHEOF
    chmod +x /usr/local/bin/vpngate-fetch.sh

    cat > /usr/local/bin/vpngate-heal.sh <<'HEALEOF'
#!/usr/bin/env bash
set -euo pipefail

country="$1"
core_dir="$2"
work_dir="$core_dir/vpngate"
log_dir="/var/log/vpngate"
mkdir -p "$log_dir"
exec 9>"$work_dir/heal-${country}.lock"
flock -n 9 || exit 0

log="$log_dir/${country}.log"
echo "$(date '+%F %T') 检查 $country" >> "$log"

if curl -s --max-time 15 --interface "tun-$country" https://ipinfo.io/ip >/dev/null 2>&1; then
    echo "$(date '+%F %T') $country 正常" >> "$log"
    exit 0
fi

echo "$(date '+%F %T') $country 不通，重启服务" >> "$log"
systemctl restart "vpngate-$country" 2>/dev/null || true
sleep 15

if curl -s --max-time 15 --interface "tun-$country" https://ipinfo.io/ip >/dev/null 2>&1; then
    echo "$(date '+%F %T') $country 重启后恢复" >> "$log"
    exit 0
fi

echo "$(date '+%F %T') $country 重启无效，换节点" >> "$log"
if /usr/local/bin/vpngate-fetch.sh "$country" "$core_dir" >> "$log" 2>&1; then
    systemctl restart "vpngate-$country" 2>/dev/null || true
    sleep 15
    if curl -s --max-time 15 --interface "tun-$country" https://ipinfo.io/ip >/dev/null 2>&1; then
        echo "$(date '+%F %T') $country 换节点后恢复" >> "$log"
    else
        echo "$(date '+%F %T') $country 换节点后仍不通" >> "$log"
    fi
else
    echo "$(date '+%F %T') $country 拉取新节点失败" >> "$log"
fi
HEALEOF
    chmod +x /usr/local/bin/vpngate-heal.sh

    for c in jp us; do
        info "拉取 VPNGate $c 节点..."
        if /usr/local/bin/vpngate-fetch.sh "$c" "$CORE_DIR"; then
            ok "$c 节点拉取成功"
        else
            warn "$c 节点拉取失败，自愈将在后续尝试"
        fi
    done

    for c in jp us; do
        cat > "/etc/systemd/system/vpngate-$c.service" <<EOF
[Unit]
Description=VPNGate $c tunnel
After=network.target

[Service]
Type=simple
ExecStart=$openvpn_bin --config "$work_dir/$c.ovpn" --dev "tun-$c" --route-nopull --pull-filter ignore "dhcp-option" --auth-user-pass "$work_dir/auth.txt" --auth-nocache --verb 3
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    done
    systemctl daemon-reload

    for c in jp us; do
        if [ -f "$work_dir/$c.ovpn" ]; then
            systemctl enable --now "vpngate-$c" 2>/dev/null || true
            local ready=0
            for i in $(seq 1 20); do
                if ip -4 addr show dev "tun-$c" 2>/dev/null | grep -q 'inet '; then
                    ready=1
                    break
                fi
                sleep 1
            done
            if [ "$ready" = "1" ]; then
                local out
                out=$(curl -s --max-time 15 --interface "tun-$c" https://ipinfo.io/json 2>/dev/null || true)
                if echo "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get("country","").upper()==sys.argv[1].upper() else 1)' "$c" 2>/dev/null; then
                    ok "$c 家宽出口验证通过"
                else
                    warn "$c 隧道已起但出口国家不符"
                fi
            else
                warn "$c 隧道未就绪"
            fi
        else
            warn "$c 无 ovpn，跳过启动"
        fi
    done

    for c in jp us; do
        cat > "/etc/systemd/system/vpngate-heal-$c.service" <<EOF
[Unit]
Description=VPNGate $c heal

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpngate-heal.sh $c $CORE_DIR
EOF
        cat > "/etc/systemd/system/vpngate-heal-$c.timer" <<EOF
[Unit]
Description=VPNGate $c heal timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=vpngate-heal-$c.service

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now "vpngate-heal-$c.timer" 2>/dev/null || true
    done
}

write_config() {
    if [[ "$CONFIG_FORMAT" == "json" ]]; then
        local hy2_tls="{
        \"enabled\": true,
        \"certificate_path\": \"$CERT_FILE\",
        \"key_path\": \"$KEY_FILE\",
        \"server_name\": \"$COMMON_SNI\"
    }"

        local reality_tls="{
        \"enabled\": true,
        \"server_name\": \"$COMMON_SNI\",
        \"reality\": {
            \"enabled\": true,
            \"handshake\": {
                \"server\": \"$COMMON_SNI\",
                \"server_port\": 443
            },
            \"private_key\": \"$REALITY_PRIVATE_KEY\",
            \"short_id\": [\"$REALITY_SHORT_ID\"]
        }
    }"

        local inbounds=()
        if [[ $ENABLE_WS -eq 1 ]]; then
            inbounds+=("    {
      \"type\": \"vless\",
      \"tag\": \"VLESS-WS-in\",
      \"listen\": \"::\",
      \"listen_port\": $WS_PORT,
      \"users\": [
        { \"uuid\": \"$UUID\", \"flow\": \"\" }
      ],
      \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/\",
        \"headers\": { \"Host\": \"$WS_DOMAIN\" }
      }
    }")
        fi
        if [[ $ENABLE_HY2 -eq 1 ]]; then
            inbounds+=("    {
      \"type\": \"hysteria2\",
      \"tag\": \"HY2-in\",
      \"listen\": \"::\",
      \"listen_port\": $HY2_PORT,
      \"users\": [ { \"password\": \"$UUID\" } ],
      \"tls\": $hy2_tls
    }")
        fi
        if [[ $ENABLE_VLESS_REALITY -eq 1 ]]; then
            inbounds+=("    {
      \"type\": \"vless\",
      \"tag\": \"VLESS-Reality-Vision-in\",
      \"listen\": \"::\",
      \"listen_port\": $REALITY_PORT,
      \"users\": [
        { \"uuid\": \"$UUID\", \"flow\": \"xtls-rprx-vision\" }
      ],
      \"tls\": $reality_tls
    }")
        fi
        if [[ $ENABLE_S5 -eq 1 ]]; then
            inbounds+=("    {
      \"type\": \"socks\",
      \"tag\": \"socks-jp-in\",
      \"listen\": \"::\",
      \"listen_port\": $S5_PORT_JP,
      \"users\": [
        { \"username\": \"$S5_USER\", \"password\": \"$S5_PASS\" }
      ]
    }")
            inbounds+=("    {
      \"type\": \"socks\",
      \"tag\": \"socks-us-in\",
      \"listen\": \"::\",
      \"listen_port\": $S5_PORT_US,
      \"users\": [
        { \"username\": \"$S5_USER\", \"password\": \"$S5_PASS\" }
      ]
    }")
        fi

        local inbounds_json="" first=1
        for ib in "${inbounds[@]}"; do
            if [[ $first -eq 1 ]]; then inbounds_json="$ib"; first=0
            else inbounds_json="$inbounds_json,
$ib"; fi
        done

        local outbounds_json='{ "type": "direct", "tag": "direct" }'
        if [[ $ENABLE_S5 -eq 1 ]]; then
            outbounds_json="$outbounds_json,
    { \"type\": \"direct\", \"tag\": \"out-jp\", \"bind_interface\": \"tun-jp\" },
    { \"type\": \"direct\", \"tag\": \"out-us\", \"bind_interface\": \"tun-us\" }"
        fi

        local route_json=""
        if [[ $ENABLE_S5 -eq 1 ]]; then
            route_json=',
  "route": {
    "rules": [
      { "inbound": ["socks-jp-in"], "outbound": "out-jp" },
      { "inbound": ["socks-us-in"], "outbound": "out-us" }
    ],
    "final": "direct"
  }'
        fi

        cat > "$CONFIG_JSON" <<EOF
{
  "log": { "level": "error", "output": "/dev/null", "timestamp": false },
  "inbounds": [
$inbounds_json
  ],
  "outbounds": [
$outbounds_json
  ]$route_json
}
EOF
        ok "sing-box 配置已生成: $CONFIG_JSON"
    else
        local yaml_inbounds=""
        if [[ $ENABLE_WS -eq 1 ]]; then
            yaml_inbounds+="
  - name: vless-ws-in
    type: vless
    port: $WS_PORT
    listen: \"::\"
    users:
      - username: user
        uuid: $UUID
        flow: \"\"
    ws-path: \"/\"
    ws-headers:
      Host: $WS_DOMAIN
    allow-insecure: true
"
        fi
        if [[ $ENABLE_HY2 -eq 1 ]]; then
            yaml_inbounds+="
  - name: hy2-in
    type: hysteria2
    port: $HY2_PORT
    listen: \"::\"
    users:
      user: $UUID
    certificate: $CERT_FILE
    private-key: $KEY_FILE
    sni: $COMMON_SNI
"
        fi
        if [[ $ENABLE_VLESS_REALITY -eq 1 ]]; then
            yaml_inbounds+="
  - name: vless-reality-vision-in
    type: vless
    port: $REALITY_PORT
    listen: \"::\"
    users:
      - username: user
        uuid: $UUID
        flow: xtls-rprx-vision
    reality-config:
      dest: $COMMON_SNI:443
      private-key: $REALITY_PRIVATE_KEY
      short-id:
        - $REALITY_SHORT_ID
      server-names:
        - $COMMON_SNI
"
        fi
        if [[ $ENABLE_S5 -eq 1 ]]; then
            yaml_inbounds+="
  - name: socks-jp-in
    type: socks
    port: $S5_PORT_JP
    listen: \"::\"
    users:
      - username: $S5_USER
        password: $S5_PASS
    proxy: out-jp
  - name: socks-us-in
    type: socks
    port: $S5_PORT_US
    listen: \"::\"
    users:
      - username: $S5_USER
        password: $S5_PASS
    proxy: out-us
"
        fi

        local yaml_proxies="[]"
        if [[ $ENABLE_S5 -eq 1 ]]; then
            yaml_proxies="
  - name: out-jp
    type: direct
    interface-name: tun-jp
  - name: out-us
    type: direct
    interface-name: tun-us
"
        fi

        cat > "$CONFIG_JSON" <<EOF
log-level: error
ipv6: true
allow-lan: true
mode: rule
external-controller: 127.0.0.1:9090

listeners:
$yaml_inbounds

proxies:$yaml_proxies
proxy-groups: []
rules:
  - MATCH,DIRECT
EOF
        ok "mihomo 配置已生成: $CONFIG_JSON"
    fi
}

setup_iptables() {
    local start_port=$(echo "$HY2_PORTS" | cut -d'-' -f1)
    local end_port=$(echo "$HY2_PORTS" | cut -d'-' -f2)

    if ! command -v iptables &>/dev/null; then
        warn "未安装 iptables，正在尝试安装..."
        case $PKG_MANAGER in
            apk)  $INSTALL_CMD iptables ip6tables ;;
            apt)  $UPDATE_CMD && $INSTALL_CMD iptables ip6tables ;;
            yum|dnf) $UPDATE_CMD && $INSTALL_CMD iptables iptables-services ;;
            zypper) $UPDATE_CMD && $INSTALL_CMD iptables ;;
        esac
        command -v iptables &>/dev/null || error "iptables 安装失败，请手动安装"
    fi

    iptables -t nat -D PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT 2>/dev/null || true
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -D PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT 2>/dev/null || true
    fi

    iptables -t nat -A PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -A PREROUTING -p udp --dport $start_port:$end_port -j REDIRECT --to-ports $HY2_PORT
        ok "已添加 IPv4 + IPv6 端口跳跃规则 ($start_port-$end_port -> $HY2_PORT)"
    else
        ok "已添加 IPv4 端口跳跃规则 ($start_port-$end_port -> $HY2_PORT)"
    fi

    iptables -I INPUT -p udp --dport $start_port:$end_port -j ACCEPT
    if command -v ip6tables &>/dev/null; then
        ip6tables -I INPUT -p udp --dport $start_port:$end_port -j ACCEPT
    fi

    info "正在持久化 iptables 规则..."
    if [[ "$INIT" == "systemd" ]]; then
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
            ok "已通过 netfilter-persistent 保存"
        elif command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            [ -f /etc/iptables/rules.v6 ] || ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            systemctl enable iptables-restore 2>/dev/null || true
            systemctl enable ip6tables-restore 2>/dev/null || true
            ok "已保存规则到 /etc/iptables/rules.v4 和 rules.v6"
            warn "请确保系统启动时自动加载这些文件（例如通过 iptables-restore 服务或 rc.local）"
        fi
    elif [[ "$INIT" == "openrc" ]]; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules-save
        if command -v ip6tables &>/dev/null; then
            ip6tables-save > /etc/iptables/rules-save-ip6
        fi
        if [ -f /etc/init.d/iptables ]; then
            rc-update add iptables default 2>/dev/null || true
        fi
        if [ -f /etc/init.d/ip6tables ]; then
            rc-update add ip6tables default 2>/dev/null || true
        fi
        ok "已保存规则到 /etc/iptables/ 并尝试添加启动服务"
    else
        warn "未知 init 系统，请手动持久化 iptables 规则"
    fi
}

create_service() {
    local run_args
    if [[ "$CLIENT_TYPE" == "0" ]]; then
        run_args="run -c $CONFIG_JSON"
    else
        run_args="-d $CORE_DIR"
    fi

    if [[ $INIT == "systemd" ]]; then
        cat > /lib/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=${SERVICE_NAME} Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CORE_BIN $run_args
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
        systemctl start ${SERVICE_NAME}
        ok "systemd 服务已启动"
    else
        cat > /etc/init.d/${SERVICE_NAME} <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="${SERVICE_NAME} proxy service"
command="$CORE_BIN"
command_args="$run_args"
command_user="root"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/${SERVICE_NAME}
        rc-update add ${SERVICE_NAME} default
        rc-service ${SERVICE_NAME} start
        ok "OpenRC 服务已启动"
    fi

    sleep 2
    if [[ $INIT == "systemd" ]] && systemctl is-active --quiet ${SERVICE_NAME}; then
        ok "服务运行正常"
    elif [[ $INIT == "openrc" ]] && rc-service ${SERVICE_NAME} status | grep -q "started"; then
        ok "服务运行正常"
    else
        warn "服务可能未正常启动，请手动运行 '$CORE_BIN $run_args' 检查错误"
    fi
}

urlencode() {
    local string="$1"
    local encoded=""
    local i
    for ((i=0; i<${#string}; i++)); do
        local char="${string:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) encoded+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    echo "$encoded"
}

get_public_ip() {
    echo ""
    echo "$(timeout 5 curl -s4 --connect-timeout 2 --max-time 4 -k https://ipinfo.io 2>/dev/null | grep -E '"country"|"city"' | sed -e 's/.*"country": "\(.*\)".*/国家: \1/' -e 's/.*"city": "\(.*\)".*/城市: \1/')"

    echo ""
    info "正在获取公网 IP ..."

    local ip_v4=""
    local ip_v6=""
    ip_v4=$(timeout 5 curl -s4 --connect-timeout 2 --max-time 4 -k https://icanhazip.com 2>/dev/null | head -n1)
    ip_v6=$(timeout 5 curl -s6 --connect-timeout 2 --max-time 4 -k https://icanhazip.com 2>/dev/null | head -n1)

    ip_v4=$(echo "$ip_v4" | tr -d '\r\n')
    ip_v6=$(echo "$ip_v6" | tr -d '\r\n')

    if [ -n "$ip_v4" ] && [ -z "$ip_v6" ]; then
        PUBLIC_IP="$ip_v4"; IP_VERSION=4
        ok "IPv4: $PUBLIC_IP"
        return 0
    fi
    if [ -z "$ip_v4" ] && [ -n "$ip_v6" ]; then
        PUBLIC_IP="$ip_v6"; IP_VERSION=6
        ok "IPv6: $PUBLIC_IP"
        return 0
    fi
    if [ -n "$ip_v4" ] && [ -n "$ip_v6" ]; then
        echo ""
        echo "IPv4: $ip_v4"
        echo "IPv6: $ip_v6"
        echo "1) 使用 IPv4"
        echo "2) 使用 IPv6"
        read -p "$(echo -e "${CYAN}请选择节点使用的IP [1-2] (默认 1):${NC} ")" IP_CHOICE
        case "$IP_CHOICE" in
            2) PUBLIC_IP="$ip_v6"; IP_VERSION=6; ok "选择 IPv6: $PUBLIC_IP" ;;
            *) PUBLIC_IP="$ip_v4"; IP_VERSION=4; ok "选择 IPv4: $PUBLIC_IP" ;;
        esac
        return 0
    fi

    warn "所有自动获取方式均失败（超时或不可达），请手动输入公网 IP"
    read -p "$(echo -e "${CYAN}请输入公网 IP:${NC} ")" PUBLIC_IP
    if [ -z "$PUBLIC_IP" ]; then
        error "未输入 IP，无法继续"
    fi
    [[ "$PUBLIC_IP" =~ : ]] && IP_VERSION=6 || IP_VERSION=4
    ok "使用手动输入的 IP: $PUBLIC_IP"
}

output_links() {
    echo ""
    echo -e "${GREEN}节点链接(如果使用vless + ws + cdn 请把端口改成443(security=tls)或80(security=none))：${NC}"

    local ip_for_url="$PUBLIC_IP"
    if [[ "$PUBLIC_IP" =~ : ]]; then
        ip_for_url="[$PUBLIC_IP]"
    fi

    if [[ $ENABLE_WS -eq 1 ]]; then
        echo -e "vless://$UUID@$WS_DOMAIN:$WS_PORT?encryption=none&security=none&type=ws&host=$WS_DOMAIN&path=#vless-ws"
        echo ""
    fi
    if [[ $ENABLE_VLESS_REALITY -eq 1 ]]; then
        echo -e "vless://$UUID@$ip_for_url:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$COMMON_SNI&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp#vless-reality-vision"
        echo ""
    fi
    if [[ $ENABLE_HY2 -eq 1 ]]; then
        echo -e "hysteria2://$UUID@$ip_for_url:$HY2_PORT?security=tls&sni=$COMMON_SNI&mport=$HY2_PORTS&ports=$HY2_PORTS#hy2"
        echo ""
    fi
    if [[ $ENABLE_S5 -eq 1 ]]; then
        echo -e "${GREEN}S5 家宽出口（仅 TCP）：${NC}"
        echo -e "socks5://$(urlencode "$S5_USER"):$(urlencode "$S5_PASS")@$ip_for_url:$S5_PORT_JP#日本家宽VPngate"
        echo -e "socks5://$(urlencode "$S5_USER"):$(urlencode "$S5_PASS")@$ip_for_url:$S5_PORT_US#美国家宽VPngate"
        echo ""
        echo -e "${YELLOW}提示：S5 出口依赖 VPNGate 隧道，若某国节点暂不可用，自愈会每 5 分钟尝试恢复。${NC}"
        echo ""
    fi

    echo -e "${YELLOW}复制链接到客户端即可使用${NC}"
    echo ""
}

main() {
    [[ $EUID -ne 0 ]] && error "请以 root 用户执行（使用 sudo -i）"

    detect_pkg_manager
    install_deps
    get_arch
    detect_init

    echo ""
    info "请选择要安装的内核"
    echo "  0) sing-box"
    echo "  1) mihomo"
    read -p "$(echo -e "${CYAN}请输入选项 [0-1] (默认 0):${NC} ")" CLIENT_TYPE
    CLIENT_TYPE=${CLIENT_TYPE:-0}
    if [[ "$CLIENT_TYPE" != "0" && "$CLIENT_TYPE" != "1" ]]; then
        warn "无效选项，使用默认 0 (sing-box)"
        CLIENT_TYPE=0
    fi
    echo "已选择: $([ "$CLIENT_TYPE" = "0" ] && echo "sing-box" || echo "mihomo")"
    echo ""

    if [[ "$CLIENT_TYPE" == "0" ]]; then
        CORE_DIR="/etc/sing-box"
        CORE_BIN="$CORE_DIR/bin/sing-box"
        CONFIG_JSON="$CORE_DIR/config.json"
        SERVICE_NAME="sing-box"
        CONFIG_FORMAT="json"
    else
        CORE_DIR="/etc/mihomo"
        CORE_BIN="$CORE_DIR/bin/mihomo"
        CONFIG_JSON="$CORE_DIR/config.yaml"
        SERVICE_NAME="mihomo"
        CONFIG_FORMAT="yaml"
    fi
    CONF_DIR="$CORE_DIR/conf"
    LOG_DIR="/var/log/$SERVICE_NAME"
    CERT_DIR="$CORE_DIR/cert"

    uninstall_old
    install_core
    get_config_all

    if [[ $ENABLE_S5 -eq 1 ]]; then
        setup_vpngate
    fi

    if [[ $ENABLE_HY2 -eq 1 || $ENABLE_ANYTLS -eq 1 ]]; then
        generate_cert
    fi
    write_config
    [[ $ENABLE_HY2 -eq 1 ]] && setup_iptables
    create_service
    get_public_ip
    output_links
}

main "$@"
