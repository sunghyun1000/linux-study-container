#!/bin/bash
# 컨테이너 생성 스크립트
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "오류: $ENV_FILE 파일이 없습니다."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

CONTAINER_COUNT="${CONTAINER_COUNT:-10}"
CONTAINER_IP_OFFSET="${CONTAINER_IP_OFFSET:-10}"
LXD_BRIDGE_IP="${LXD_BRIDGE_IP:-10.10.0.1}"

if ! [[ "$CONTAINER_COUNT" =~ ^[0-9]+$ ]] || (( CONTAINER_COUNT < 1 || CONTAINER_COUNT > 100 )); then
  echo "오류: CONTAINER_COUNT는 1~100 범위의 정수여야 합니다."
  exit 1
fi

if ! [[ "$CONTAINER_IP_OFFSET" =~ ^[0-9]+$ ]] || (( CONTAINER_IP_OFFSET < 2 || CONTAINER_IP_OFFSET > 254 )); then
  echo "오류: CONTAINER_IP_OFFSET는 2~254 범위의 정수여야 합니다."
  exit 1
fi

if (( CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 > 254 )); then
  echo "오류: CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 이 254를 초과할 수 없습니다."
  exit 1
fi

for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
  IP="10.10.0.$((CONTAINER_IP_OFFSET + i))"
  PASS="server$i"

  echo "--- server$i 생성 중 ---"
  lxc launch ubuntu:24.04 "server$i" --quiet < /dev/null
  lxc config set "server$i" boot.autostart true
  lxc config set "server$i" boot.autostart.delay 3
  lxc config set "server$i" security.nesting true
  lxc config set "server$i" security.syscalls.intercept.mknod true
  lxc config set "server$i" security.syscalls.intercept.setxattr true
  lxc config set "server$i" limits.memory 8GB
  lxc config set "server$i" limits.memory.swap false
  lxc config device add "server$i" eth0 nic nictype=bridged parent=lxdbr0 name=eth0 ipv4.address="$IP"

  for attempt in $(seq 1 30); do
    lxc exec "server$i" -- true < /dev/null 2>/dev/null && break
    sleep 2
  done

  lxc exec "server$i" -- useradd -m -s /bin/bash -G sudo server < /dev/null
  lxc exec "server$i" -- bash -c "echo 'server:${PASS}' | chpasswd" < /dev/null
  lxc exec "server$i" -- bash -c "echo server$i > /etc/hostname && hostname server$i" < /dev/null
  lxc exec "server$i" -- bash -c "touch /etc/cloud/cloud-init.disabled && systemctl disable cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true" < /dev/null

  lxc exec "server$i" -- bash -c "cat > /etc/netplan/50-cloud-init.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - ${IP}/24
      routes:
        - to: default
          via: ${LXD_BRIDGE_IP}
      nameservers:
        addresses: [${LXD_BRIDGE_IP}, 8.8.8.8]
NETPLAN" < /dev/null
  lxc exec "server$i" -- bash -c "ip addr flush dev eth0 2>/dev/null; ip addr add ${IP}/24 dev eth0; ip route add default via ${LXD_BRIDGE_IP} 2>/dev/null || true" < /dev/null

  lxc exec "server$i" -- bash -c "grep -v 'nrconf{restart}' /etc/needrestart/needrestart.conf > /tmp/nr.conf 2>/dev/null; echo '\$nrconf{restart} = q(a);' >> /tmp/nr.conf; mv /tmp/nr.conf /etc/needrestart/needrestart.conf" < /dev/null

  echo "server$i 완료 (IP: $IP, PW: $PASS)"
done

echo "모든 컨테이너 생성 완료"
