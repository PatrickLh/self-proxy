#!/usr/bin/env bash
# Debian 12+/Ubuntu 22.04+, root. Creates a new dedicated Xray installation.
set -Eeuo pipefail
umask 077
PORT=443
SNI=www.apple.com
SERVER_IP=
IMAGE=ghcr.io/xtls/xray-core:latest
INSTALL_DIR=/etc/xray-reality
usage() {
  echo "Usage: sudo bash $0 --server-ip PUBLIC_IP [--port 443] [--sni www.apple.com] [--image IMAGE]"
}
die() { echo "Error: $*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --server-ip|--port|--sni|--image)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --server-ip) SERVER_IP=$2;; --port) PORT=$2;;
        --sni) SNI=$2;; --image) IMAGE=$2;;
      esac
      shift 2;;
    -h|--help) usage; exit 0;;
    *) usage; die "Unknown argument: $1";;
  esac
done
[[ $(uname -s) == Linux ]] || die "Run on the Linux VPS, not your local Mac."
[[ $EUID == 0 ]] || die "Run as root (sudo bash ...)."
[[ -n $SERVER_IP ]] || die "--server-ip is required (use the VPS public IP)."
[[ $PORT =~ ^[0-9]+$ && ${#PORT} -le 5 ]] || die "Invalid port"
PORT=$((10#$PORT))
((PORT >= 1 && PORT <= 65535)) || die "Invalid port"
[[ $SNI =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $SNI == *.* ]] || die "Invalid SNI hostname"
[[ ! -e $INSTALL_DIR ]] || die "$INSTALL_DIR already exists; refusing to replace credentials. See test.md."
command -v apt-get >/dev/null || die "Only Debian/Ubuntu with apt-get are supported."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl python3 iproute2
python3 - "$SERVER_IP" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
if not ip.is_global:
    raise SystemExit('Use a globally routable public IPv4 or IPv6 address')
PY
if ! command -v docker >/dev/null; then
  apt-get install -y docker.io
fi
systemctl enable --now docker
if docker container inspect xray-reality >/dev/null 2>&1; then
  die "Container xray-reality already exists"
fi
if [[ -n $(ss -H -ltn "sport = :$PORT") ]]; then
  die "TCP port $PORT is already occupied"
fi
# Pull once, then lock this installation to the immutable registry digest.
docker pull "$IMAGE"
PINNED_IMAGE=$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE")
[[ $PINNED_IMAGE == *@sha256:* ]] || die "Could not resolve image digest"
KEYS=$(docker run --rm "$PINNED_IMAGE" x25519)
PRIVATE_KEY=$(printf '%s\n' "$KEYS" | awk -F ': *' 'tolower($1) ~ /^private[ ]*key$/ {print $2; exit}')
PUBLIC_KEY=$(printf '%s\n' "$KEYS" | awk -F ': *' 'tolower($1) ~ /^(public[ ]*key|password( \(publickey\))?)$/ {print $2; exit}')
[[ $PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]] || die "Unexpected x25519 output; check Xray version"
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
# Check the camouflage destination from the VPS before installing.
curl --fail --silent --show-error --connect-timeout 10 --max-time 20 \
  --tlsv1.3 --tls-max 1.3 --http2 "https://$SNI/" -o /dev/null
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
export PORT SNI SERVER_IP PRIVATE_KEY PUBLIC_KEY UUID SHORT_ID PINNED_IMAGE STAGE
python3 <<'PY'
import ipaddress, json, os
from pathlib import Path
e = os.environ
p = Path(e['STAGE'])
server = {
    'log': {'loglevel': 'warning'},
    'inbounds': [{'listen': '0.0.0.0' if ipaddress.ip_address(e['SERVER_IP']).version == 4 else '::',
        'port': int(e['PORT']), 'protocol': 'vless',
        'settings': {'clients': [{'id': e['UUID'], 'flow': 'xtls-rprx-vision'}], 'decryption': 'none'},
        'streamSettings': {'network': 'raw', 'security': 'reality', 'realitySettings': {
            # Mihomo sends REALITY client version 1.8.2 independently of its release version.
            'show': False, 'minClientVer': '1.8.2',
            'target': e['SNI'] + ':443', 'serverNames': [e['SNI']],
            'privateKey': e['PRIVATE_KEY'], 'shortIds': [e['SHORT_ID']]}}}],
    'outbounds': [{'protocol': 'freedom'}]}
(p / 'config.json').write_text(json.dumps(server, indent=2) + '\n')
# JSON scalars are valid YAML scalars; quote all user-controlled strings.
q = json.dumps
server_ip = ipaddress.ip_address(e['SERVER_IP'])
client = f'''# Import as a Local profile in Clash Verge Rev (Mihomo).
# Contains credentials. Do not publish or upload to subscription converters.
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
find-process-mode: strict
proxies:
  - name: VPS
    type: vless
    server: {q(e['SERVER_IP'])}
    port: {e['PORT']}
    uuid: {q(e['UUID'])}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: {q(e['SNI'])}
    client-fingerprint: chrome
    reality-opts:
      public-key: {q(e['PUBLIC_KEY'])}
      short-id: {q(e['SHORT_ID'])}
      support-x25519mlkem768: true
proxy-groups:
  - name: PROXY
    type: select
    proxies: [VPS]
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - 'localhost'
  default-nameserver: [223.5.5.5, 119.29.29.29]
  # Resolve DIRECT outbound domains without depending on the VPS.
  direct-nameserver:
    - '223.5.5.5#DIRECT'
    - '119.29.29.29#DIRECT'
  nameserver:
    - 'https://1.1.1.1/dns-query#PROXY'
    - 'https://8.8.8.8/dns-query#PROXY'
tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  strict-route: true
  dns-hijack:
    - any:53
    - tcp://any:53
  route-exclude-address:
    - {q(str(server_ip) + ('/32' if server_ip.version == 4 else '/128'))}
rules:
  - DOMAIN,localhost,DIRECT
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,lan,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - DOMAIN-SUFFIX,cn,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,tmall.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - MATCH,PROXY
'''
(p / 'client.yaml').write_text(client)
(p / 'image.txt').write_text(e['PINNED_IMAGE'] + '\n')
PY
# Validate before persisting files or opening a port.
docker run --rm --user 0:0 -v "$STAGE/config.json:/etc/xray/config.json:ro" \
  "$PINNED_IMAGE" run -test -c /etc/xray/config.json
install -d -m 700 "$INSTALL_DIR"
install -m 600 "$STAGE/config.json" "$STAGE/client.yaml" "$STAGE/image.txt" "$INSTALL_DIR/"
docker run -d --name xray-reality --restart unless-stopped --network host \
  --user 0:0 --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges \
  --log-opt max-size=10m --log-opt max-file=3 \
  -v "$INSTALL_DIR/config.json:/etc/xray/config.json:ro" \
  "$PINNED_IMAGE" run -c /etc/xray/config.json
sleep 2
[[ $(docker inspect --format '{{.State.Running}}' xray-reality) == true ]] || {
  docker logs --tail 50 xray-reality >&2
  die "Xray failed; files retained in $INSTALL_DIR for diagnosis"
}
[[ -n $(ss -H -ltn "sport = :$PORT") ]] || die "Xray is running but TCP $PORT is not listening; inspect docker logs"
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow "$PORT/tcp"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT/tcp"
  firewall-cmd --add-port="$PORT/tcp"
fi
printf '\nXray is listening on TCP %s.\nClient profile: %s/client.yaml\nImage lock: %s/image.txt\n' "$PORT" "$INSTALL_DIR" "$INSTALL_DIR"
echo 'Allow this TCP port in the cloud security group. Download client.yaml securely; do not publish it.'
