const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const cors = require('cors');
const bodyParser = require('body-parser');
const http = require('http');
const WebSocket = require('ws');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

const PORT = process.env.PORT || 3000;
const DATA_FILE = path.join(__dirname, '../data/config.json');
const USERS_FILE = path.join(__dirname, '../data/users.json');
const SECRET_FILE = path.join(__dirname, '../data/.session_secret');

const dataDir = path.join(__dirname, '../data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

// ─────────────────────────────────────────────
//  SECURITY HELPERS
// ─────────────────────────────────────────────

function getOrCreateSessionSecret() {
  if (fs.existsSync(SECRET_FILE)) {
    return fs.readFileSync(SECRET_FILE, 'utf8').trim();
  }
  const secret = crypto.randomBytes(32).toString('hex');
  fs.writeFileSync(SECRET_FILE, secret, { mode: 0o600 });
  return secret;
}

// Proxy user credentials must be plain-text for Caddy forward_proxy basic_auth.
// Validate format to prevent Caddyfile injection.
function validateProxyCredentials(username, password) {
  if (!username || !password) return false;
  if (!/^[a-zA-Z0-9_\-.]{1,64}$/.test(username)) return false;
  // Disallow whitespace, quotes, backslashes — all Caddy config-breaking chars
  if (/[\s"'\\{}\n\r]/.test(password)) return false;
  if (password.length < 1 || password.length > 128) return false;
  return true;
}

const SENSITIVE_PATTERNS = [
  /NAIVE_PASSWORD=\S+/gi,
  /NAIVE_LOGIN=\S+/gi,
  /password[=:]\S+/gi,
  /passwd[=:]\S+/gi,
];

function sanitizeLine(line) {
  return SENSITIVE_PATTERNS.reduce((s, p) =>
    s.replace(p, (m) => m.split(/[=:]/)[0] + '=***'), line);
}

function logSecurity(event, req, extra = '') {
  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  console.log(`[SECURITY] ${new Date().toISOString()} ${event} ip=${ip}${extra ? ' ' + extra : ''}`);
}

// ─────────────────────────────────────────────
//  DATA HELPERS
// ─────────────────────────────────────────────

function loadConfig() {
  if (!fs.existsSync(DATA_FILE)) {
    const defaultConfig = {
      installed: false,
      naiveDomain: '',
      domain: '',
      panelDomain: '',
      adminDomain: '',
      email: '',
      serverIp: '',
      proxyUsers: [],
      hysteriaEnabled: false,
      hysteriaPassword: '',
      traefikUser: ''
    };
    fs.writeFileSync(DATA_FILE, JSON.stringify(defaultConfig, null, 2));
    return defaultConfig;
  }
  const cfg = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  // backcompat: naiveDomain falls back to domain
  if (!cfg.naiveDomain) cfg.naiveDomain = cfg.domain || '';
  return cfg;
}

function saveConfig(config) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(config, null, 2));
}

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    const randomPassword = crypto.randomBytes(16).toString('base64url').slice(0, 20);
    console.log('\n╔══════════════════════════════════════════════════╗');
    console.log('║  ПЕРВЫЙ ЗАПУСК — сохраните учётные данные!       ║');
    console.log(`║  Логин:  admin                                   ║`);
    console.log(`║  Пароль: ${randomPassword.padEnd(38)}  ║`);
    console.log('║  Смените пароль сразу после входа!               ║');
    console.log('╚══════════════════════════════════════════════════╝\n');
    const defaultUsers = {
      admin: {
        password: bcrypt.hashSync(randomPassword, 10),
        role: 'admin',
        forcePasswordChange: true
      }
    };
    fs.writeFileSync(USERS_FILE, JSON.stringify(defaultUsers, null, 2));
    return defaultUsers;
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));
}

// ─────────────────────────────────────────────
//  SESSION STORE (shared with WebSocket auth)
// ─────────────────────────────────────────────

const sessionStore = new session.MemoryStore();

// ─────────────────────────────────────────────
//  MIDDLEWARE
// ─────────────────────────────────────────────

// Panel is served same-origin — no cross-origin requests needed.
// Restrict to same-origin only (cors() with no options would allow all).
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS ? process.env.ALLOWED_ORIGINS.split(',') : false,
  credentials: true
}));

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: true }));
app.use(session({
  secret: getOrCreateSessionSecret(),
  resave: false,
  saveUninitialized: false,
  store: sessionStore,
  cookie: {
    secure: false,
    httpOnly: true,
    sameSite: 'strict',
    maxAge: 24 * 60 * 60 * 1000
  }
}));
app.use(express.static(path.join(__dirname, '../public')));

// ─────────────────────────────────────────────
//  AUTH MIDDLEWARE
// ─────────────────────────────────────────────

function requireAuth(req, res, next) {
  if (req.session && req.session.authenticated) {
    return next();
  }
  res.status(401).json({ error: 'Unauthorized' });
}

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { success: false, message: 'Слишком много попыток входа. Попробуйте через 15 минут.' }
});

// ─────────────────────────────────────────────
//  AUTH ROUTES
// ─────────────────────────────────────────────

app.post('/api/login', loginLimiter, (req, res) => {
  const { username, password } = req.body;

  if (!username || !password ||
      typeof username !== 'string' || typeof password !== 'string' ||
      username.length > 64 || password.length > 128) {
    return res.status(400).json({ success: false, message: 'Неверный запрос' });
  }

  const users = loadUsers();
  const user = users[username];

  if (!user || !bcrypt.compareSync(password, user.password)) {
    logSecurity('LOGIN_FAIL', req, `user=${username}`);
    return res.json({ success: false, message: 'Неверный логин или пароль' });
  }

  req.session.authenticated = true;
  req.session.username = username;
  req.session.role = user.role;
  logSecurity('LOGIN_OK', req, `user=${username}`);
  res.json({ success: true, forcePasswordChange: user.forcePasswordChange || false });
});

app.post('/api/logout', (req, res) => {
  const username = req.session?.username;
  req.session.destroy();
  if (username) logSecurity('LOGOUT', req, `user=${username}`);
  res.json({ success: true });
});

app.get('/api/me', requireAuth, (req, res) => {
  const users = loadUsers();
  const user = users[req.session.username] || {};
  res.json({
    username: req.session.username,
    role: req.session.role,
    forcePasswordChange: user.forcePasswordChange || false
  });
});

// ─────────────────────────────────────────────
//  CONFIG ROUTES
// ─────────────────────────────────────────────

app.get('/api/config', requireAuth, (req, res) => {
  const config = loadConfig();
  const safe = { ...config };
  res.json(safe);
});

app.post('/api/config/change-password', requireAuth, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword ||
      typeof currentPassword !== 'string' || typeof newPassword !== 'string') {
    return res.json({ success: false, message: 'Заполните все поля' });
  }
  if (newPassword.length < 12) {
    return res.json({ success: false, message: 'Новый пароль минимум 12 символов' });
  }
  if (newPassword.length > 128) {
    return res.json({ success: false, message: 'Пароль слишком длинный' });
  }
  const users = loadUsers();
  const user = users[req.session.username];
  if (!user) {
    return res.json({ success: false, message: 'Пользователь не найден' });
  }
  if (!bcrypt.compareSync(currentPassword, user.password)) {
    logSecurity('PASSWORD_CHANGE_FAIL', req, `user=${req.session.username}`);
    return res.json({ success: false, message: 'Текущий пароль неверен' });
  }
  users[req.session.username].password = bcrypt.hashSync(newPassword, 10);
  delete users[req.session.username].forcePasswordChange;
  saveUsers(users);
  logSecurity('PASSWORD_CHANGED', req, `user=${req.session.username}`);
  res.json({ success: true, message: 'Пароль успешно изменён' });
});

// ─────────────────────────────────────────────
//  PROXY USERS ROUTES
// ─────────────────────────────────────────────

app.get('/api/proxy-users', requireAuth, (req, res) => {
  const config = loadConfig();
  res.json({ users: config.proxyUsers || [] });
});

app.post('/api/proxy-users/add', requireAuth, (req, res) => {
  const { username, password } = req.body;

  if (!validateProxyCredentials(username, password)) {
    return res.json({
      success: false,
      message: 'Логин (только a-z A-Z 0-9 _ - ., макс 64) и пароль (без пробелов/кавычек, макс 128) обязательны'
    });
  }

  const config = loadConfig();
  if (!config.proxyUsers) config.proxyUsers = [];

  if (config.proxyUsers.find(u => u.username === username)) {
    return res.json({ success: false, message: 'Пользователь уже существует' });
  }

  // NOTE: Caddy forward_proxy basic_auth requires plaintext credentials.
  // Passwords are stored as-is and written to Caddyfile.
  // Mitigate by: strict format validation above + restrictive file permissions on Caddyfile.
  config.proxyUsers.push({ username, password, createdAt: new Date().toISOString() });
  saveConfig(config);

  logSecurity('PROXY_USER_ADD', req, `user=${req.session.username} proxy=${username}`);

  if (config.installed) {
    updateCaddyfile(config, res, () => {
      res.json({ success: true, link: `naive+https://${username}:${password}@${config.domain}:443` });
    });
  } else {
    res.json({ success: true, link: username + ':' + password });
  }
});

app.delete('/api/proxy-users/:username', requireAuth, (req, res) => {
  const { username } = req.params;

  if (!/^[a-zA-Z0-9_\-.]{1,64}$/.test(username)) {
    return res.status(400).json({ error: 'Invalid username' });
  }

  const config = loadConfig();
  const before = (config.proxyUsers || []).length;
  config.proxyUsers = (config.proxyUsers || []).filter(u => u.username !== username);
  if (config.proxyUsers.length === before) {
    return res.json({ success: false, message: 'Пользователь не найден' });
  }
  saveConfig(config);

  logSecurity('PROXY_USER_DEL', req, `user=${req.session.username} proxy=${username}`);

  if (config.installed) {
    updateCaddyfile(config, res, () => {
      res.json({ success: true });
    });
  } else {
    res.json({ success: true });
  }
});

// ─────────────────────────────────────────────
//  SERVER STATUS
// ─────────────────────────────────────────────

function checkServiceStatus(serviceName, callback) {
  const child = spawn('systemctl', ['is-active', serviceName]);
  let output = '';
  child.stdout.on('data', d => output += d.toString().trim());
  child.on('close', () => callback(output.trim() === 'active'));
  child.on('error', () => callback(false));
}

app.get('/api/status', requireAuth, (req, res) => {
  const config = loadConfig();
  if (!config.installed) {
    return res.json({ installed: false, status: 'not_installed' });
  }

  checkServiceStatus('caddy', (caddyRunning) => {
    checkServiceStatus('hysteria-server', (hy2Running) => {
      res.json({
        installed: true,
        status: caddyRunning ? 'running' : 'stopped',
        domain: config.naiveDomain || config.domain,
        panelDomain: config.panelDomain || '',
        adminDomain: config.adminDomain || '',
        serverIp: config.serverIp,
        email: config.email,
        usersCount: (config.proxyUsers || []).length,
        hysteria: {
          enabled: config.hysteriaEnabled || false,
          status: hy2Running ? 'running' : 'stopped'
        }
      });
    });
  });
});

// ─────────────────────────────────────────────
//  HYSTERIA2 ROUTES
// ─────────────────────────────────────────────

app.get('/api/hysteria/status', requireAuth, (req, res) => {
  const config = loadConfig();
  checkServiceStatus('hysteria-server', (running) => {
    res.json({
      enabled: config.hysteriaEnabled || false,
      status: running ? 'running' : 'stopped',
      domain: config.naiveDomain || config.domain,
      password: config.hysteriaPassword || ''
    });
  });
});

app.post('/api/hysteria/restart', requireAuth, (req, res) => {
  logSecurity('HYSTERIA_RESTART', req, `user=${req.session.username}`);
  const child = spawn('systemctl', ['restart', 'hysteria-server']);
  child.on('close', (code) => {
    res.json({ success: code === 0, message: code === 0 ? 'Hysteria2 перезапущен' : 'Ошибка перезапуска' });
  });
  child.on('error', () => {
    res.json({ success: false, message: 'systemctl недоступен' });
  });
});

app.post('/api/service/:action', requireAuth, (req, res) => {
  const { action } = req.params;
  if (!['start', 'stop', 'restart'].includes(action)) {
    return res.status(400).json({ error: 'Invalid action' });
  }
  logSecurity('SERVICE_ACTION', req, `user=${req.session.username} action=${action}`);
  const child = spawn('systemctl', [action, 'caddy']);
  child.on('close', (code) => {
    res.json({ success: code === 0, message: code === 0 ? `Caddy ${action} выполнен` : 'Ошибка управления сервисом' });
  });
  child.on('error', () => {
    res.json({ success: false, message: 'systemctl недоступен (вы не на сервере?)' });
  });
});

// ─────────────────────────────────────────────
//  WEBSOCKET — INSTALL (requires valid session)
// ─────────────────────────────────────────────

function getSessionFromWsRequest(req, callback) {
  const cookieHeader = req.headers.cookie || '';
  const sidMatch = cookieHeader.match(/connect\.sid=([^;]+)/);
  if (!sidMatch) return callback(null);

  const rawSid = decodeURIComponent(sidMatch[1]);
  // express-session signs as "s:<id>.<signature>"
  const sid = rawSid.startsWith('s:') ? rawSid.slice(2).split('.')[0] : rawSid;

  sessionStore.get(sid, (err, sessionData) => {
    if (err || !sessionData) return callback(null);
    callback(sessionData);
  });
}

wss.on('connection', (ws, req) => {
  getSessionFromWsRequest(req, (sessionData) => {
    if (!sessionData || !sessionData.authenticated) {
      ws.close(4001, 'Unauthorized');
      return;
    }

    ws.on('message', (message) => {
      try {
        const data = JSON.parse(message);
        if (data.type === 'install') {
          console.log(`[SECURITY] ${new Date().toISOString()} WS_INSTALL user=${sessionData.username}`);
          handleInstall(ws, data);
        }
      } catch (e) {
        ws.send(JSON.stringify({ type: 'error', message: 'Invalid message' }));
      }
    });
  });
});

function sendLog(ws, text, step = null, progress = null, level = 'info') {
  ws.send(JSON.stringify({ type: 'log', text, step, progress, level }));
}

function updateCaddyfile(config, res, callback) {
  let basicAuthLines = '';
  if (config.proxyUsers && config.proxyUsers.length > 0) {
    basicAuthLines = config.proxyUsers
      .filter(u => validateProxyCredentials(u.username, u.password))
      .map(u => `    basic_auth ${u.username} ${u.password}`)
      .join('\n');
  }

  const naiveDomain = config.naiveDomain || config.domain || '';
  const certDir = `/etc/ssl/traefik-certs/${naiveDomain}`;
  const tlsLine = `  tls ${certDir}/certificate.crt ${certDir}/privatekey.key`;

  const caddyfileContent = `{
  order forward_proxy before file_server
}

127.0.0.1:10443 {
${tlsLine}

  forward_proxy {
${basicAuthLines}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
`;

  try {
    fs.writeFileSync('/etc/caddy/Caddyfile', caddyfileContent, { encoding: 'utf8', mode: 0o640 });
  } catch (e) {
    // Not running as root or Caddy not installed — skip silently
  }

  const reload = spawn('bash', ['-c',
    'caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl restart caddy 2>/dev/null || true'
  ]);
  reload.on('close', () => { if (callback) callback(); });
  reload.on('error', () => { if (callback) callback(); });
}

function handleInstall(ws, data) {
  const { domain, email, adminLogin, adminPassword } = data;

  if (!domain || !email || !adminLogin || !adminPassword) {
    sendLog(ws, '❌ Заполните все поля!', null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: 'Заполните все поля' }));
    return;
  }

  if (!validateProxyCredentials(adminLogin, adminPassword)) {
    sendLog(ws, '❌ Недопустимый формат логина или пароля прокси', null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: 'Недопустимый формат учётных данных' }));
    return;
  }

  const config = loadConfig();
  config.naiveDomain = domain;
  config.domain = domain;
  config.email = email;
  if (!config.proxyUsers) config.proxyUsers = [];

  const existingUser = config.proxyUsers.find(u => u.username === adminLogin);
  if (!existingUser) {
    config.proxyUsers.push({ username: adminLogin, password: adminPassword, createdAt: new Date().toISOString() });
  }
  saveConfig(config);

  const getIp = spawn('bash', ['-c', "curl -4 -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'"]);
  let serverIp = '';
  getIp.stdout.on('data', d => serverIp += d.toString().trim());
  getIp.on('close', () => {
    config.serverIp = serverIp;
    saveConfig(config);
  });

  const scriptPath = path.join(__dirname, '../scripts/install_naiveproxy.sh');

  if (!fs.existsSync(scriptPath)) {
    sendLog(ws, '❌ Скрипт установки не найден!', null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: 'install_naiveproxy.sh не найден' }));
    return;
  }

  sendLog(ws, '🚀 Начинаем установку NaiveProxy...', 'init', 2, 'info');

  const env = {
    ...process.env,
    NAIVE_DOMAIN: domain,
    NAIVE_EMAIL: email,
    NAIVE_LOGIN: adminLogin,
    NAIVE_PASSWORD: adminPassword,
    PANEL_DOMAIN: config.panelDomain || '',
    ADMIN_DOMAIN: config.adminDomain || '',
    TRAEFIK_USER: config.traefikUser || '',
    DEBIAN_FRONTEND: 'noninteractive'
  };

  const install = spawn('bash', [scriptPath], { env });

  install.stdout.on('data', (data) => {
    const lines = data.toString().split('\n').filter(l => l.trim());
    lines.forEach(line => {
      const sanitized = sanitizeLine(line);
      const parsed = parseLogLine(sanitized);
      sendLog(ws, parsed.text, parsed.step, parsed.progress, parsed.level);
    });
  });

  install.stderr.on('data', (data) => {
    const lines = data.toString().split('\n').filter(l => l.trim());
    lines.forEach(line => {
      if (!line.includes('WARNING') && line.trim()) {
        sendLog(ws, sanitizeLine(line), null, null, 'warn');
      }
    });
  });

  install.on('close', (code) => {
    if (code === 0) {
      config.installed = true;
      saveConfig(config);
      const finalConfig = loadConfig();
      sendLog(ws, '✅ Установка завершена успешно!', 'done', 100, 'success');
      const naiveDomain = finalConfig.naiveDomain || domain;
      const hy2Pass = finalConfig.hysteriaPassword;
      ws.send(JSON.stringify({
        type: 'install_done',
        link: `naive+https://${adminLogin}:${adminPassword}@${naiveDomain}:443`,
        hy2Link: hy2Pass ? `hysteria2://${hy2Pass}@${naiveDomain}:443` : null
      }));
    } else {
      sendLog(ws, `❌ Установка завершилась с ошибкой (код ${code})`, null, null, 'error');
      ws.send(JSON.stringify({ type: 'install_error', message: `Exit code: ${code}` }));
    }
  });

  install.on('error', (err) => {
    sendLog(ws, `❌ Ошибка запуска скрипта: ${err.message}`, null, null, 'error');
    ws.send(JSON.stringify({ type: 'install_error', message: err.message }));
  });
}

function parseLogLine(line) {
  const stepMap = [
    { pattern: /STEP:1/, step: 'update', progress: 8, text: '📦 Обновление системы и зависимостей...' },
    { pattern: /STEP:2/, step: 'bbr', progress: 14, text: '⚡ Включение BBR...' },
    { pattern: /STEP:3/, step: 'firewall', progress: 20, text: '🔥 Настройка файрволла...' },
    { pattern: /STEP:4/, step: 'golang', progress: 30, text: '🐹 Установка Go...' },
    { pattern: /STEP:5/, step: 'caddy', progress: 55, text: '🔨 Сборка Caddy с naive-плагином (это займёт 3-7 мин)...' },
    { pattern: /STEP:6/, step: 'caddyfile', progress: 68, text: '📝 Создание конфигурации Caddy...' },
    { pattern: /STEP:7/, step: 'service', progress: 75, text: '⚙️ Настройка systemd сервиса...' },
    { pattern: /STEP:8/, step: 'start', progress: 82, text: '🟢 Запуск Caddy...' },
    // Traefik steps (from install_traefik.sh)
    { pattern: /STEP:traefik$/, step: 'traefik', progress: 5, text: '🔀 Установка Traefik...' },
    { pattern: /STEP:traefikconfig/, step: 'traefikconfig', progress: 10, text: '🔀 Конфигурация Traefik...' },
    { pattern: /STEP:traefikservice/, step: 'traefikservice', progress: 14, text: '🔀 Запуск Traefik...' },
    { pattern: /STEP:traefikstart/, step: 'traefikstart', progress: 18, text: '🔀 Traefik запускается...' },
    // Hysteria2 steps (from install_hysteria2.sh)
    { pattern: /STEP:hysteria$/, step: 'hysteria', progress: 88, text: '⚡ Установка Hysteria2...' },
    { pattern: /STEP:hysteriaconfig/, step: 'hysteriaconfig', progress: 91, text: '⚡ Конфигурация Hysteria2...' },
    { pattern: /STEP:hysteriaservice/, step: 'hysteriaservice', progress: 94, text: '⚡ Запуск Hysteria2...' },
    { pattern: /STEP:hysteriastart/, step: 'hysteriastart', progress: 97, text: '⚡ Hysteria2 стартует...' },
    { pattern: /STEP:DONE/, step: 'done', progress: 100, text: '✅ Готово!' },
  ];

  for (const s of stepMap) {
    if (s.pattern.test(line)) {
      return { text: s.text, step: s.step, progress: s.progress, level: 'step' };
    }
  }

  if (/error|ошибка|failed|fail/i.test(line)) {
    return { text: line, step: null, progress: null, level: 'error' };
  }
  if (/warn|warning/i.test(line)) {
    return { text: line, step: null, progress: null, level: 'warn' };
  }
  if (/ok|done|success|✅|✓/i.test(line)) {
    return { text: line, step: null, progress: null, level: 'success' };
  }

  return { text: line, step: null, progress: null, level: 'info' };
}

// Serve index for all non-api routes (SPA)
app.get('*', (req, res) => {
  if (!req.path.startsWith('/api')) {
    res.sendFile(path.join(__dirname, '../public/index.html'));
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`\n╔══════════════════════════════════════╗`);
  console.log(`║   Panel NaiveProxy by RIXXX          ║`);
  console.log(`║   Running on http://0.0.0.0:${PORT}     ║`);
  console.log(`╚══════════════════════════════════════╝\n`);
});
