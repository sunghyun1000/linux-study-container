# Linux 실습실

LXD 컨테이너 기반 Linux 실습 환경. 학생마다 독립된 Ubuntu 24.04 서버를 제공하고, 브라우저 터미널과 관리자 대시보드를 제공합니다.

## 구조

```
외부 (공인 IP)              호스트                        컨테이너
공인IP_0:*   ──DNAT──▶  Secondary IP 0  ──SNAT──▶  10.10.0.10 (server0)
공인IP_1:*   ──DNAT──▶  Secondary IP 1  ──SNAT──▶  10.10.0.11 (server1)
...

도메인:443   ──▶  Caddy  ──▶  127.0.0.1:3000 (Node.js 웹앱)
```

- **컨테이너**: `server0`부터 `server{n-1}`까지, 1~100개 설정 가능
- **웹 UI**: 브라우저 터미널(xterm.js), 관리자 대시보드
- **인증**: 컨테이너 리눅스 계정 비밀번호 (`/etc/shadow`) 직접 사용
- **초기 비밀번호**: `server{n}` (학생이 `passwd`로 변경 가능)

## 파일 구조

```
skkuding-linux/
├── README.md
├── app/
│   ├── server.js          # Node.js 백엔드 (Express + WebSocket + node-pty)
│   ├── package.json
│   ├── data.json.example  # 관리자 비밀번호, 별명, 외부 IP 저장 형식
│   └── public/
│       ├── index.html     # 학생 접속 페이지 (서버 선택 → 비밀번호 입력)
│       ├── terminal.html  # xterm.js 터미널
│       └── admin.html     # 관리자 대시보드
├── config/
│   ├── lxd-classroom.service.template  # systemd 서비스 템플릿
│   ├── Caddyfile.template              # Caddy 설정 템플릿
│   └── abuse-block.nft                 # 공통 포트 차단 규칙 (25, 6881-6889)
└── scripts/
    ├── setup.sh               # 전체 설치 스크립트
    └── create-containers.sh   # .env 기준 컨테이너 생성 스크립트
```

## 설치

### 전제 조건

- Oracle Cloud (또는 기타) VM
- RAM 16GB 이상 (컨테이너당 최대 8GB 제한)
- `CONTAINER_COUNT` 개수만큼 Secondary Private IP + 각각 공인 IP 할당
- 도메인 및 DNS 설정 완료
- `apt-get` 또는 `dnf` 사용 가능
- NetworkManager(`nmcli`) 사용 환경
- 설치 및 운영에 사용하는 계정이 `sudo`를 비밀번호 없이 실행할 수 있는 `NOPASSWD` 권한 보유

### 빠른 설치

**1. `.env` 파일 작성**

```bash
cp .env.example .env
nano .env
```

`.env` 예시:

```bash
DOMAIN="linux.example.com"      # 웹 UI 도메인
HOST_IFACE="enp0s6"             # 호스트 외부 NIC 이름 (ip a로 확인)
INSTALL_USER="ubuntu"           # 웹앱을 실행할 서버 사용자
CONTAINER_COUNT="10"            # 1~100
CONTAINER_IP_OFFSET="10"        # 내부 IP 시작 옥텟

SECONDARY_IPS=(
  "10.0.10.100"   # 클라우드에서 할당한 Secondary IP
  "10.0.10.101"
  ...
)
```

**2. 설치 실행**

```bash
chmod +x scripts/setup.sh scripts/create-containers.sh
bash scripts/setup.sh
```

**3. 외부 IP 업데이트**

```bash
# /opt/lxd-classroom/data.json 편집
# externalIps에 클라우드에서 할당받은 공인 IP 입력
sudo nano /opt/lxd-classroom/data.json
```

---

### 수동 설치

#### 1. LXD

```bash
sudo apt-get install -y lxd lxd-client
# 또는
sudo dnf install -y lxd lxd-client

sudo lxd init --minimal
lxc network set lxdbr0 ipv4.address 10.10.0.1/24
lxc network set lxdbr0 ipv4.nat true
```

#### 2. Node.js 22

```bash
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt-get update && sudo apt-get install -y nodejs
```

#### 3. 앱

```bash
sudo cp -r app/ /opt/lxd-classroom
sudo cp app/data.json.example /opt/lxd-classroom/data.json
cd /opt/lxd-classroom && sudo npm install
sed "s/__RUN_USER__/ubuntu/g; s/__RUN_GROUP__/ubuntu/g" config/lxd-classroom.service.template | sudo tee /etc/systemd/system/lxd-classroom.service
sudo systemctl enable --now lxd-classroom
```

#### 4. Caddy

```bash
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
sed "s/__DOMAIN__/linux.example.com/g" config/Caddyfile.template | sudo tee /etc/caddy/Caddyfile
```

#### 5. Secondary IP 추가 (NetworkManager)

```bash
# 각 Secondary IP를 호스트 NIC에 추가
CONN=$(nmcli connection show --active | grep enp0s6 | awk '{print $1}')
for IP in 10.0.10.100 10.0.10.101 ...; do
  sudo nmcli connection modify "$CONN" +ipv4.addresses "${IP}/24"
done
sudo nmcli connection up "$CONN"
```

#### 6. nftables

```bash
sudo cp config/abuse-block.nft /etc/nftables/
# student-nat.nft는 .env 기준으로 자동 생성
sudo nft -f /etc/nftables/abuse-block.nft

# 부팅 시 자동 로드
echo 'include "/etc/nftables/student-nat.nft"' | sudo tee -a /etc/nftables.conf
echo 'include "/etc/nftables/abuse-block.nft"' | sudo tee -a /etc/nftables.conf
sudo systemctl enable nftables

# br_netfilter
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo modprobe br_netfilter
```

#### 7. 컨테이너 생성

```bash
bash scripts/create-containers.sh
```

---

## 환경별 수정 사항

다른 서버 환경에 설치 시 수정이 필요한 파일과 항목:

| 파일 | 수정 항목 |
|------|----------|
| `.env` | `DOMAIN`, `HOST_IFACE`, `INSTALL_USER`, `CONTAINER_COUNT`, `CONTAINER_IP_OFFSET`, `SECONDARY_IPS` |
| `app/data.json` (설치 후) | `externalIps` (공인 IP) |

> **참고**: 컨테이너 내부 네트워크(10.10.0.0/24)와 LXD 브리지는 외부 NIC 대역과 무관하므로 변경 불필요.
> `config/` 안의 템플릿/규칙 파일은 `setup.sh`가 읽어서 실제 설정 파일을 생성합니다.

---

## 관리

### 웹 UI
- 학생 접속: `https://도메인`
- 관리자: `https://도메인/admin.html` (초기 비밀번호: `admin`)

### 컨테이너 직접 접근 (복구용)
```bash
lxc exec server3 -- bash        # 직접 쉘
lxc restart server3             # 재시작
lxc stop server3 && lxc start server3
```

### 서비스 관리
```bash
sudo systemctl status lxd-classroom
sudo journalctl -u lxd-classroom -f    # 실시간 로그
sudo systemctl restart lxd-classroom
```

### 컨테이너 리소스 현황
```bash
btop                            # 전체 리소스
lxc list                        # 컨테이너 상태
```

---

## 기술 스택

- **LXD** — 컨테이너 관리
- **Ubuntu 24.04** — 컨테이너 OS
- **Node.js 22** — 백엔드 (Express, ws, node-pty)
- **xterm.js** — 브라우저 터미널
- **Caddy** — 리버스 프록시 + 자동 TLS
- **nftables** — DNAT/SNAT, 포트 차단
- **NetworkManager** — Secondary IP 관리

## 보안 설정

- 컨테이너당 RAM 8GB 하드 캡 (`limits.memory`)
- swap 사용 금지 (`limits.memory.swap false`)
- 포트 25/465/587 (SMTP) 차단
- 포트 6881-6889 (BitTorrent) 차단
- 컨테이너 격리 — 한 컨테이너 문제가 다른 컨테이너에 영향 없음
