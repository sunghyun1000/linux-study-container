#!/bin/bash
# 컨테이너 생성/재생성 스크립트
# 인자 없음 : 전체 생성 (CONTAINER_COUNT 기준)
# 인자 있음 : 지정한 ID만 생성  예) bash create-containers.sh 0 3 7
set -euo pipefail

CONTAINER_COUNT="${CONTAINER_COUNT:-10}"
CONTAINER_IP_OFFSET="${CONTAINER_IP_OFFSET:-10}"
LXD_BRIDGE_IP="${LXD_BRIDGE_IP:-10.10.0.1}"

# 생성할 컨테이너 ID 목록 결정
if [[ $# -gt 0 ]]; then
  IDS=("$@")
else
  IDS=()
  for i in $(seq 0 $((CONTAINER_COUNT - 1))); do
    IDS+=("$i")
  done
fi

setup_container() {
  local i="$1"
  local IP="10.10.0.$((CONTAINER_IP_OFFSET + i))"
  local PASS="server$i"

  echo "--- server$i 생성 중 (IP: $IP) ---"

  # 기존 컨테이너 및 고아 볼륨 정리
  # 1) CLI 방식 (정상 케이스)
  lxc stop "server$i" --force 2>/dev/null < /dev/null || true
  lxc delete "server$i" --force 2>/dev/null < /dev/null || true
  # 2) REST API 방식 (CLI가 부분 생성 상태를 인식 못할 때 대비)
  lxc query -X DELETE "/1.0/instances/server$i" 2>/dev/null < /dev/null || true
  lxc query -X DELETE "/1.0/storage-pools/default/volumes/container/server$i" 2>/dev/null < /dev/null || true
  # 3) 파일시스템 정리
  sudo rm -rf "/var/snap/lxd/common/lxd/storage-pools/default/containers/server$i" 2>/dev/null || true

  # 컨테이너 생성 및 기본 설정
  lxc launch ubuntu:24.04 "server$i" --quiet < /dev/null
  lxc config set "server$i" boot.autostart true < /dev/null
  lxc config set "server$i" boot.autostart.delay 3 < /dev/null
  lxc config set "server$i" security.nesting true < /dev/null
  lxc config set "server$i" security.syscalls.intercept.mknod true < /dev/null
  lxc config set "server$i" security.syscalls.intercept.setxattr true < /dev/null
  lxc config set "server$i" limits.memory 8GB < /dev/null
  lxc config set "server$i" limits.memory.swap false < /dev/null
  lxc config device add "server$i" eth0 nic nictype=bridged parent=lxdbr0 name=eth0 \
    ipv4.address="$IP" 2>/dev/null < /dev/null || \
  lxc config device set "server$i" eth0 ipv4.address="$IP" < /dev/null

  # 부팅 대기 (최대 60초)
  for attempt in $(seq 1 30); do
    lxc exec "server$i" -- true < /dev/null 2>/dev/null && break
    sleep 2
  done

  # 사용자 생성
  lxc exec "server$i" -- useradd -m -s /bin/bash -G sudo server < /dev/null
  lxc exec "server$i" -- bash -c "echo 'server:${PASS}' | chpasswd" < /dev/null
  lxc exec "server$i" -- bash -c "echo server$i > /etc/hostname && hostname server$i" < /dev/null

  # cloud-init 비활성화
  lxc exec "server$i" -- bash -c \
    "touch /etc/cloud/cloud-init.disabled && \
     systemctl disable cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true" \
    < /dev/null

  # 네트워크 설정
  # 10-lxd.yaml (LXD 자동 생성)도 dhcp4:false로 덮어써서 DHCP 완전 차단
  lxc exec "server$i" -- bash -c \
    "printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n' \
     > /etc/netplan/10-lxd.yaml" < /dev/null

  # 정적 IP netplan 설정 (재부팅 후 유지용)
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

  # ip 명령으로 즉시 적용
  lxc exec "server$i" -- bash -c \
    "ip addr flush dev eth0 2>/dev/null; \
     ip addr add ${IP}/24 dev eth0; \
     ip route add default via ${LXD_BRIDGE_IP} 2>/dev/null || true; \
     printf 'nameserver ${LXD_BRIDGE_IP}\nnameserver 8.8.8.8\n' > /etc/resolv.conf" \
    < /dev/null

  # needrestart 무음 처리
  lxc exec "server$i" -- bash -c \
    "grep -v 'nrconf{restart}' /etc/needrestart/needrestart.conf > /tmp/nr.conf 2>/dev/null; \
     echo '\$nrconf{restart} = q(a);' >> /tmp/nr.conf; \
     mv /tmp/nr.conf /etc/needrestart/needrestart.conf" \
    < /dev/null

  echo "server$i 완료 (IP: $IP, PW: $PASS)"
}

for id in "${IDS[@]}"; do
  setup_container "$id"
done

echo "완료: ${IDS[*]}"
