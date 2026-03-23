const express = require('express');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');
const http = require('http');
const { execSync, spawnSync, exec } = require('child_process');
const { promisify } = require('util');
const execAsync = (cmd, opts = {}) => promisify(exec)(cmd, { timeout: 120000, ...opts });

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

const DATA_FILE = path.join(__dirname, 'data.json');
const CONTAINER_COUNT = Number.parseInt(process.env.CONTAINER_COUNT || '10', 10);
const CONTAINER_IP_OFFSET = Number.parseInt(process.env.CONTAINER_IP_OFFSET || '10', 10);
const LXD_BRIDGE_IP = process.env.LXD_BRIDGE_IP || '10.10.0.1';

if (!Number.isInteger(CONTAINER_COUNT) || CONTAINER_COUNT < 1 || CONTAINER_COUNT > 100) {
  throw new Error('CONTAINER_COUNT must be an integer between 1 and 100');
}

if (!Number.isInteger(CONTAINER_IP_OFFSET) || CONTAINER_IP_OFFSET < 2 || CONTAINER_IP_OFFSET > 254) {
  throw new Error('CONTAINER_IP_OFFSET must be an integer between 2 and 254');
}

if (CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 > 254) {
  throw new Error('CONTAINER_IP_OFFSET + CONTAINER_COUNT - 1 must be <= 254');
}

function containerIds() {
  return Array.from({ length: CONTAINER_COUNT }, (_, i) => String(i));
}

function isValidContainerId(value) {
  if (!/^\d+$/.test(String(value))) return false;
  const numericId = Number.parseInt(String(value), 10);
  return numericId >= 0 && numericId < CONTAINER_COUNT;
}

function requireValidContainerId(value, errorMessage) {
  const cid = String(value);
  if (!isValidContainerId(cid)) {
    const error = new Error(errorMessage);
    error.status = 400;
    throw error;
  }
  return cid;
}

function containerIp(containerId) {
  return `10.10.0.${CONTAINER_IP_OFFSET + Number.parseInt(containerId, 10)}`;
}

function loadData() {
  if (!fs.existsSync(DATA_FILE)) {
    const init = { teacherPassword: 'admin', nicknames: {} };
    fs.writeFileSync(DATA_FILE, JSON.stringify(init, null, 2));
    return init;
  }
  const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  if (!data.nicknames) data.nicknames = {};
  if (!data.externalIps) data.externalIps = {};
  return data;
}

// 컨테이너 Linux 계정 비밀번호를 /etc/shadow와 대조
function verifyContainerPassword(containerId, password) {
  const script = `
import crypt, sys
pw = sys.stdin.read().strip()
for line in open('/etc/shadow'):
    if line.startswith('server:'):
        h = line.split(':')[1]
        sys.exit(0 if crypt.crypt(pw, h) == h else 1)
sys.exit(1)
`;
  const result = spawnSync('lxc', ['exec', `server${containerId}`, '--', 'python3', '-c', script], {
    input: password,
    encoding: 'utf8',
    timeout: 5000
  });
  return result.status === 0;
}

function saveData(data) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
}

// 세션 저장소 (메모리)
const studentSessions = new Map(); // token -> containerId
const adminSessions = new Set();   // token

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── 학생 인증 ──────────────────────────────────────────────
app.post('/api/auth', (req, res) => {
  const { id, password } = req.body;
  let cid;
  try {
    cid = requireValidContainerId(id, '잘못된 컨테이너 번호');
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  if (!password) return res.status(400).json({ error: '비밀번호를 입력하세요' });
  if (!verifyContainerPassword(cid, password)) return res.status(401).json({ error: '비밀번호가 틀렸습니다' });
  const token = uuidv4();
  studentSessions.set(token, cid);
  res.json({ token, id: cid });
});

// ── 관리자 인증 ────────────────────────────────────────────
app.post('/api/admin/login', (req, res) => {
  const { password } = req.body;
  const data = loadData();
  if (data.teacherPassword !== password) return res.status(401).json({ error: '비밀번호가 틀렸습니다' });
  const token = uuidv4();
  adminSessions.add(token);
  res.json({ token });
});

function requireAdmin(req, res, next) {
  const auth = req.headers.authorization || '';
  const token = auth.replace('Bearer ', '');
  if (!adminSessions.has(token)) return res.status(401).json({ error: '인증 필요' });
  next();
}

// ── 공개 API (학생용) ──────────────────────────────────────
app.get('/api/containers', (req, res) => {
  const data = loadData();
  const result = containerIds().map(cid => ({
    id: cid,
    nickname: data.nicknames[cid] || '',
    externalIp: data.externalIps[cid] || ''
  }));
  res.json(result);
});

// ── 관리자 API ─────────────────────────────────────────────
app.get('/api/admin/containers', requireAdmin, (req, res) => {
  const data = loadData();
  // lxc list를 한 번만 호출해서 전체 상태 파싱
  let stateMap = {};
  try {
    const out = execSync('lxc list "^server[0-9]+$" --format=csv -c n,s', { encoding: 'utf8' });
    out.trim().split('\n').filter(Boolean).forEach(line => {
      const [name, state] = line.split(',');
      const id = name.replace('server', '');
      if (isValidContainerId(id)) stateMap[id] = state.toLowerCase();
    });
  } catch (_) {}
  const result = containerIds().map(cid => ({
    id: cid,
    nickname: data.nicknames[cid] || '',
    externalIp: data.externalIps[cid] || '',
    state: stateMap[cid] || 'stopped'
  }));
  res.json(result);
});

app.put('/api/admin/nickname/:id', requireAdmin, (req, res) => {
  const data = loadData();
  let cid;
  try {
    cid = requireValidContainerId(req.params.id, '잘못된 ID');
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  data.nicknames[cid] = req.body.nickname || '';
  saveData(data);
  res.json({ ok: true });
});

app.put('/api/admin/externalip/:id', requireAdmin, (req, res) => {
  const data = loadData();
  let cid;
  try {
    cid = requireValidContainerId(req.params.id, '잘못된 ID');
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }
  data.externalIps[cid] = req.body.externalIp || '';
  saveData(data);
  res.json({ ok: true });
});

app.put('/api/admin/teacher-password', requireAdmin, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  const data = loadData();
  if (data.teacherPassword !== currentPassword) return res.status(401).json({ error: '현재 비밀번호가 틀렸습니다' });
  data.teacherPassword = newPassword;
  saveData(data);
  res.json({ ok: true });
});

// 초기화 진행 상태 추적
const resetStatus = new Map(); // cid -> 'resetting' | 'done' | 'error'

app.get('/api/admin/reset-status', requireAdmin, (req, res) => {
  const result = {};
  resetStatus.forEach((v, k) => { result[k] = v; });
  res.json(result);
});

app.post('/api/admin/reset', requireAdmin, (req, res) => {
  const { ids, clearNickname } = req.body;
  if (!Array.isArray(ids) || ids.length === 0) return res.status(400).json({ error: 'ids 필요' });
  let normalizedIds;
  try {
    normalizedIds = [...new Set(ids.map(id => requireValidContainerId(id, '잘못된 ID')))];
  } catch (error) {
    return res.status(error.status || 400).json({ error: error.message });
  }

  normalizedIds.forEach(id => resetStatus.set(id, 'resetting'));
  res.json({ ok: true, message: `${normalizedIds.length}개 컨테이너 초기화 시작` });

  // 컨테이너가 exec 가능할 때까지 폴링 (최대 60초)
  async function waitReady(cid) {
    for (let i = 0; i < 30; i++) {
      try {
        await execAsync(`lxc exec server${cid} -- true`);
        return;
      } catch (_) {
        await new Promise(r => setTimeout(r, 2000));
      }
    }
    throw new Error(`server${cid} 부팅 타임아웃`);
  }

  // 컨테이너별 초기화 함수
  async function resetOne(id) {
    const cid = requireValidContainerId(id, '잘못된 ID');
    const initialPassword = 'server' + cid;
    try {
      const x = '< /dev/null';
      await execAsync(`lxc stop server${cid} --force 2>/dev/null || true ${x}`);
      await execAsync(`lxc delete server${cid} --force 2>/dev/null || true ${x}`);
      await execAsync(`lxc storage volume delete default container/server${cid} 2>/dev/null || true ${x}`);
      await execAsync(`sudo rm -rf /var/snap/lxd/common/lxd/storage-pools/default/containers/server${cid} 2>/dev/null || true ${x}`);
      await execAsync(`lxc launch ubuntu:24.04 server${cid} --quiet ${x}`);
      await execAsync(`lxc config set server${cid} boot.autostart true ${x}`);
      await execAsync(`lxc config set server${cid} boot.autostart.delay 3 ${x}`);
      await execAsync(`lxc config set server${cid} security.nesting true ${x}`);
      await execAsync(`lxc config set server${cid} security.syscalls.intercept.mknod true ${x}`);
      await execAsync(`lxc config set server${cid} security.syscalls.intercept.setxattr true ${x}`);
      await execAsync(`lxc config set server${cid} limits.memory 8GB ${x}`);
      await execAsync(`lxc config set server${cid} limits.memory.swap false ${x}`);
      await waitReady(cid);
      await execAsync(`lxc exec server${cid} -- useradd -m -s /bin/bash -G sudo server ${x}`);
      await execAsync(`lxc exec server${cid} -- bash -c "echo 'server:${initialPassword}' | chpasswd" ${x}`);
      await execAsync(`lxc exec server${cid} -- bash -c "echo server${cid} > /etc/hostname && hostname server${cid}" ${x}`);
      await execAsync(`lxc exec server${cid} -- bash -c "touch /etc/cloud/cloud-init.disabled && systemctl disable cloud-init cloud-init-local cloud-config cloud-final 2>/dev/null || true" ${x}`);
      const ip = containerIp(cid);
      const netplanCfg = `network:\\n  version: 2\\n  ethernets:\\n    eth0:\\n      dhcp4: false\\n      addresses:\\n        - ${ip}/24\\n      routes:\\n        - to: default\\n          via: ${LXD_BRIDGE_IP}\\n      nameservers:\\n        addresses: [${LXD_BRIDGE_IP}, 8.8.8.8]\\n`;
      await execAsync(`lxc exec server${cid} -- bash -c "printf '${netplanCfg}' > /etc/netplan/50-cloud-init.yaml" ${x}`);
      await execAsync(`lxc exec server${cid} -- bash -c "ip addr flush dev eth0 2>/dev/null; ip addr add ${ip}/24 dev eth0; ip route add default via ${LXD_BRIDGE_IP} 2>/dev/null || true; printf 'nameserver ${LXD_BRIDGE_IP}\\nnameserver 8.8.8.8\\n' > /etc/resolv.conf" ${x}`);
      await execAsync(`lxc config device add server${cid} eth0 nic nictype=bridged parent=lxdbr0 name=eth0 ipv4.address=${ip} 2>/dev/null || lxc config device set server${cid} eth0 ipv4.address=${ip} ${x}`);
      await execAsync(`lxc exec server${cid} -- bash -c "grep -v 'nrconf{restart}' /etc/needrestart/needrestart.conf > /tmp/nr.conf 2>/dev/null && echo '\\\$nrconf{restart} = q(a);' >> /tmp/nr.conf && mv /tmp/nr.conf /etc/needrestart/needrestart.conf || true" ${x}`);
      if (clearNickname) {
        const data = loadData();
        data.nicknames[cid] = '';
        saveData(data);
      }
      resetStatus.set(cid, 'done');
      console.log(`server${cid} 초기화 완료`);
    } catch (e) {
      resetStatus.set(cid, 'error');
      console.error(`server${cid} 초기화 실패:`, e.message);
    }
  }

  // 모든 컨테이너 병렬 초기화
  Promise.all(normalizedIds.map(resetOne));
});

// ── WebSocket 터미널 ───────────────────────────────────────
wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  const type = url.searchParams.get('type'); // 'student' | 'admin-preview'
  const id = url.searchParams.get('id');

  let containerId;

  if (type === 'admin') {
    // 교사가 특정 컨테이너 미리보기
    if (!adminSessions.has(token)) return ws.close(1008, 'Unauthorized');
    if (!isValidContainerId(id)) return ws.close(1008, 'Unauthorized');
    containerId = String(id);
  } else {
    // 학생
    if (!studentSessions.has(token)) return ws.close(1008, 'Unauthorized');
    containerId = studentSessions.get(token);
  }

  let ptyProcess;
  try {
    ptyProcess = pty.spawn('lxc', ['exec', `server${containerId}`, '--', 'su', '-', 'server'], {
      name: 'xterm-256color',
      cols: 80,
      rows: 24,
      env: process.env
    });
  } catch (e) {
    ws.send('\r\n컨테이너에 연결할 수 없습니다.\r\n');
    ws.close();
    return;
  }

  ptyProcess.onData(data => {
    if (ws.readyState === ws.OPEN) ws.send(data);
  });

  ptyProcess.onExit(() => {
    if (ws.readyState === ws.OPEN) ws.close();
  });

  ws.on('message', msg => {
    try {
      const data = JSON.parse(msg);
      if (data.type === 'resize') {
        ptyProcess.resize(data.cols, data.rows);
      } else if (data.type === 'input') {
        ptyProcess.write(data.data);
      }
    } catch (_) {
      ptyProcess.write(msg);
    }
  });

  ws.on('close', () => {
    try { ptyProcess.kill(); } catch (_) {}
  });
});

const PORT = 3000;
server.listen(PORT, '127.0.0.1', () => {
  console.log(`LXD Classroom running on http://127.0.0.1:${PORT}`);
});
