#!/bin/bash
# Linux 실습실 설치 스크립트
# Ubuntu / Debian / Oracle Linux / Amazon Linux / Rocky Linux / Fedora 기준
# 실행 전에 .env 작성 필요

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "오류: $ENV_FILE 파일이 없습니다."
  echo "먼저 .env.example을 복사해 .env를 작성하세요."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

DOMAIN="${DOMAIN:-}"
HOST_IFACE="${HOST_IFACE:-}"
INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-$USER}}"
CONTAINER_COUNT="${CONTAINER_COUNT:-10}"
CONTAINER_IP_OFFSET="${CONTAINER_IP_OFFSET:-10}"
LXD_BRIDGE_IP="${LXD_BRIDGE_IP:-10.10.0.1}"
LXD_BRIDGE_SUBNET="${LXD_BRIDGE_SUBNET:-10.10.0.0/24}"

if [[ -z "$DOMAIN" || -z "$HOST_IFACE" || -z "$INSTALL_USER" ]]; then
  echo "오류: DOMAIN, HOST_IFACE, INSTALL_USER는 .env에 반드시 설정해야 합니다."
  exit 1
fi

if ! id "$INSTALL_USER" >/dev/null 2>&1; then
  echo "오류: INSTALL_USER '$INSTALL_USER' 사용자가 서버에 없습니다."
  exit 1
fi

if ! [[ "$CONTAINER_COUNT" =~ ^[0-9]+$ ]] || (( CONTAINER_COUNT < 1 || CONTAINER_COUNT > 100 )); then
  echo "오류: CONTAINER_COUNT는 1~100 범위의 정수여야 합니다."
  exit 1
fi

if ! [[ "$CONTAINER_IP_OFFSET" =~ ^[0-9]+$ ]] || (( CONTAINER_IP_OFFSET < 2 || CONTAINER_IP_OFFSET > 254 )); then
  echo "오류: CONTAINER_IP_OFFSET는 2~254 범위의 정수여야 합니다."
  exit 1
fi

if [[ ${#SECONDARY_IPS[@]} -ne $CONTAINER_COUNT ]]; then
  echo "오류: SECONDARY_IPS 개수는 CONTAINER_COUNT와 같아야 합니다. 현재 ${#SECONDARY_IPS[@]}개 / 설정값 ${CONTAINER_COUNT}개입니다."
  exit 1
fi

CONTAINER_IPS=()
for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
  CONTAINER_IPS+=("10.10.0.$((CONTAINER_IP_OFFSET + i))")
done

if (( CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 > 254 )); then
  echo "오류: CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 이 254를 초과할 수 없습니다."
  exit 1
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
else
  echo "오류: /etc/os-release를 찾을 수 없습니다."
  exit 1
fi

PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
else
  echo "오류: apt-get 또는 dnf를 찾을 수 없습니다."
  exit 1
fi

if [[ ":$PATH:" != *":/snap/bin:"* ]]; then
  export PATH="$PATH:/snap/bin"
fi

LXD_BIN=""
LXC_BIN=""

NFTABLES_CONF="/etc/sysconfig/nftables.conf"
if [[ "$PKG_MGR" == "apt" ]]; then
  NFTABLES_CONF="/etc/nftables.conf"
fi

APT_UPDATED=0
DNF_UPDATED=0

apt_update() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    sudo apt-get update
    APT_UPDATED=1
  fi
}

dnf_makecache() {
  if [[ "$DNF_UPDATED" -eq 0 ]]; then
    sudo dnf -y makecache
    DNF_UPDATED=1
  fi
}

pkg_install() {
  if [[ "$PKG_MGR" == "apt" ]]; then
    apt_update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  else
    dnf_makecache
    sudo dnf install -y "$@"
  fi
}

ensure_snapd() {
  if command -v snap >/dev/null 2>&1; then
    return
  fi

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install snapd
  else
    pkg_install snapd
  fi
}

ensure_snap_path() {
  if [[ ! -e /snap ]]; then
    sudo ln -s /var/lib/snapd/snap /snap
  fi
}

wait_for_lxc() {
  local tries=0
  while (( tries < 30 )); do
    if command -v lxc >/dev/null 2>&1; then
      return
    fi
    sleep 1
    tries=$((tries + 1))
  done

  echo "오류: lxc 명령을 찾을 수 없습니다. snap 기반 LXD 설치가 완료되지 않았습니다."
  exit 1
}

resolve_lxd_binaries() {
  local candidate

  for candidate in \
    "$(command -v lxd 2>/dev/null || true)" \
    /snap/bin/lxd \
    /var/lib/snapd/snap/bin/lxd
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      LXD_BIN="$candidate"
      break
    fi
  done

  for candidate in \
    "$(command -v lxc 2>/dev/null || true)" \
    /snap/bin/lxc \
    /var/lib/snapd/snap/bin/lxc
  do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      LXC_BIN="$candidate"
      break
    fi
  done

  if [[ -z "$LXD_BIN" || -z "$LXC_BIN" ]]; then
    echo "오류: LXD 바이너리 경로를 찾을 수 없습니다."
    exit 1
  fi
}

enable_extra_repos() {
  if [[ "$PKG_MGR" != "dnf" ]]; then
    return
  fi

  case "${ID:-}" in
    oracle|ol)
      sudo dnf install -y oracle-epel-release-el9 2>/dev/null || true
      sudo dnf config-manager --set-enabled ol9_codeready_builder 2>/dev/null || true
      sudo dnf config-manager --enable ol9_developer_EPEL 2>/dev/null || true
      ;;
    rocky|almalinux|rhel|centos)
      sudo dnf install -y epel-release 2>/dev/null || true
      sudo dnf config-manager --set-enabled crb 2>/dev/null || \
      sudo dnf config-manager --set-enabled powertools 2>/dev/null || true
      ;;
    amzn)
      sudo dnf config-manager --set-enabled crb 2>/dev/null || true
      ;;
    fedora)
      :
      ;;
  esac
}

install_lxd() {
  if snap list lxd >/dev/null 2>&1 && command -v lxc >/dev/null 2>&1; then
    return
  fi

  echo "=== 1. LXD 설치 ==="

  ensure_snapd
  sudo systemctl enable --now snapd.socket
  ensure_snap_path

  if ! snap list lxd >/dev/null 2>&1; then
    sudo snap install lxd
  fi

  if systemctl list-unit-files | grep -q '^snap\.lxd\.daemon\.service'; then
    sudo systemctl enable --now snap.lxd.daemon
  fi

  sudo usermod -aG lxd "$INSTALL_USER" 2>/dev/null || true
  wait_for_lxc
  resolve_lxd_binaries
}

install_node() {
  if command -v node >/dev/null 2>&1; then
    return
  fi

  echo "=== 2. Node.js 설치 ==="

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install ca-certificates curl gnupg
    if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
      sudo mkdir -p /etc/apt/keyrings
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | \
      sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    APT_UPDATED=0
    pkg_install nodejs
  else
    pkg_install ca-certificates curl gnupg2 dnf-plugins-core
    curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
    DNF_UPDATED=0
    pkg_install nodejs
  fi
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    return
  fi

  echo "=== 4. Caddy 설치 ==="

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
      sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    APT_UPDATED=0
    pkg_install caddy
  else
    pkg_install dnf-plugins-core
    if ! sudo dnf copr list --enabled 2>/dev/null | grep -q '@caddy/caddy'; then
      sudo dnf copr enable -y @caddy/caddy
    fi
    DNF_UPDATED=0
    pkg_install caddy
  fi
}

install_platform_tools() {
  echo "=== 3. 기본 패키지 설치 ==="

  if [[ "$PKG_MGR" == "apt" ]]; then
    pkg_install build-essential curl gawk jq make nftables network-manager python3 snapd
  else
    enable_extra_repos
    pkg_install curl gcc gcc-c++ gawk jq make nftables NetworkManager python3 snapd
  fi
}

configure_lxd() {
  resolve_lxd_binaries
  sudo "$LXD_BIN" init --minimal
  sudo "$LXC_BIN" network set lxdbr0 ipv4.address "${LXD_BRIDGE_IP}/24"
  sudo "$LXC_BIN" network set lxdbr0 ipv4.nat true
  sudo "$LXC_BIN" network set lxdbr0 ipv4.dhcp true
  sudo usermod -aG lxd "$INSTALL_USER" 2>/dev/null || true

  if [[ -d "/home/$INSTALL_USER" ]]; then
    sudo install -d -o "$INSTALL_USER" -g "$INSTALL_USER" "/home/$INSTALL_USER/.config"
  fi
}

install_app() {
  echo "=== 5. 앱 설치 ==="
  sudo mkdir -p /opt/lxd-classroom/public /opt/lxd-classroom/scripts
  sudo cp "$SCRIPT_DIR/app/server.js" /opt/lxd-classroom/
  sudo cp "$SCRIPT_DIR/app/package.json" /opt/lxd-classroom/
  sudo cp "$SCRIPT_DIR/app/public/"* /opt/lxd-classroom/public/
  sudo cp "$SCRIPT_DIR/app/scripts/create-containers.sh" /opt/lxd-classroom/scripts/
  sudo chmod +x /opt/lxd-classroom/scripts/create-containers.sh
  if [[ ! -f /opt/lxd-classroom/data.json ]]; then
    sudo cp "$SCRIPT_DIR/app/data.json.example" /opt/lxd-classroom/data.json
  fi

  (cd /opt/lxd-classroom && sudo npm install)
  sudo chown -R "$INSTALL_USER:$INSTALL_USER" /opt/lxd-classroom
}

configure_caddy() {
  sudo mkdir -p /var/lib/caddy /.config/caddy 2>/dev/null || true
  sudo useradd -r -s /usr/sbin/nologin caddy 2>/dev/null || \
  sudo useradd -r -s /sbin/nologin caddy 2>/dev/null || true

  sed \
    -e "s/__DOMAIN__/$DOMAIN/g" \
    "$SCRIPT_DIR/config/Caddyfile.template" | sudo tee /etc/caddy/Caddyfile >/dev/null
}

configure_networkmanager() {
  echo "=== 6. Secondary IP 설정 ==="

  if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
    sudo systemctl enable --now NetworkManager
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "오류: nmcli를 찾을 수 없습니다. 이 서버는 NetworkManager 기반이어야 합니다."
    exit 1
  fi

  CONN=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v iface="$HOST_IFACE" '$2 == iface { print $1; exit }')
  if [[ -z "$CONN" ]]; then
    echo "오류: 활성 NetworkManager connection을 찾을 수 없습니다. HOST_IFACE=$HOST_IFACE"
    exit 1
  fi

  for IP in "${SECONDARY_IPS[@]}"; do
    sudo nmcli connection modify "$CONN" +ipv4.addresses "${IP}/24"
  done
  sudo nmcli connection up "$CONN"
}

configure_nftables() {
  echo "=== 7. nftables 설정 ==="
  sudo mkdir -p /etc/nftables
  sudo cp "$SCRIPT_DIR/config/abuse-block.nft" /etc/nftables/

  cat > /tmp/student-nat-gen.nft << 'NFTEOF'
table inet student-nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
NFTEOF

  for i in "${!SECONDARY_IPS[@]}"; do
    echo "        iifname != \"lxdbr0\" ip daddr ${SECONDARY_IPS[$i]} dnat to ${CONTAINER_IPS[$i]}" >> /tmp/student-nat-gen.nft
  done

  cat >> /tmp/student-nat-gen.nft << 'NFTEOF'
    }
    chain postrouting {
        type nat hook postrouting priority 95; policy accept;
NFTEOF

  for i in "${!SECONDARY_IPS[@]}"; do
    echo "        ip saddr ${CONTAINER_IPS[$i]} ip daddr != ${LXD_BRIDGE_SUBNET} snat to ${SECONDARY_IPS[$i]}" >> /tmp/student-nat-gen.nft
  done

  echo "    }
}" >> /tmp/student-nat-gen.nft

  sudo cp /tmp/student-nat-gen.nft /etc/nftables/student-nat.nft
  sudo nft -f /etc/nftables/student-nat.nft
  sudo nft -f /etc/nftables/abuse-block.nft

  sudo touch "$NFTABLES_CONF"
  sudo grep -q 'student-nat' "$NFTABLES_CONF" 2>/dev/null || \
    sudo bash -c "echo 'include \"/etc/nftables/student-nat.nft\"' >> '$NFTABLES_CONF'"
  sudo grep -q 'abuse-block' "$NFTABLES_CONF" 2>/dev/null || \
    sudo bash -c "echo 'include \"/etc/nftables/abuse-block.nft\"' >> '$NFTABLES_CONF'"
  sudo systemctl enable --now nftables

  echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf >/dev/null
  sudo modprobe br_netfilter

  # firewalld가 활성 상태면 lxdbr0을 trusted 존에 추가
  # (미설정 시 firewalld가 호스트↔컨테이너 트래픽을 차단함)
  if command -v firewall-cmd >/dev/null 2>&1 && sudo firewall-cmd --state >/dev/null 2>&1; then
    sudo firewall-cmd --zone=trusted --add-interface=lxdbr0 --permanent
    sudo firewall-cmd --reload
  fi
}

configure_services() {
  echo "=== 8. systemd 서비스 등록 ==="

  sed \
    -e "s/__RUN_USER__/$INSTALL_USER/g" \
    -e "s/__RUN_GROUP__/$INSTALL_USER/g" \
    -e "s/__CONTAINER_COUNT__/$CONTAINER_COUNT/g" \
    -e "s/__CONTAINER_IP_OFFSET__/$CONTAINER_IP_OFFSET/g" \
    -e "s/__LXD_BRIDGE_IP__/$LXD_BRIDGE_IP/g" \
    "$SCRIPT_DIR/config/lxd-classroom.service.template" | sudo tee /etc/systemd/system/lxd-classroom.service >/dev/null

  sudo systemctl daemon-reload
  sudo systemctl enable --now lxd-classroom
  sudo systemctl enable --now caddy
}

create_containers() {
  echo "=== 9. 컨테이너 생성 (약 5~10분) ==="
  sudo env \
    CONTAINER_COUNT="$CONTAINER_COUNT" \
    CONTAINER_IP_OFFSET="$CONTAINER_IP_OFFSET" \
    LXD_BRIDGE_IP="$LXD_BRIDGE_IP" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin" \
    bash /opt/lxd-classroom/scripts/create-containers.sh
}

install_lxd
install_node
install_platform_tools
install_caddy
configure_lxd
install_app
configure_caddy
configure_networkmanager
configure_nftables
configure_services
create_containers

echo ""
echo "✓ 설치 완료!"
echo "  패키지 관리자: $PKG_MGR"
echo "  컨테이너 수: $CONTAINER_COUNT"
echo "  웹 UI: https://${DOMAIN}"
echo "  관리자 초기 비밀번호: admin"
echo ""
echo "※ data.json에서 externalIps를 실제 공인 IP로 업데이트하세요."
