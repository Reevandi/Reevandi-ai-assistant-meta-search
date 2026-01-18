!/bin/bash

# ===================================================================
# AI Assistant Setup — Frontend Only (LLM & LibreY deployed manually)
# - UI: GPT/Qwen-like interface (responsive, dark/light mode)
# - Trigger search with: "fly [query]"
# - Assumes:
#     • Ollama running on http://localhost:11434 (with qwen2.5:0.5b pulled)
#     • LibreY accessible at http://localhost:8080 (or custom port)
# - Installs only PHP frontend + proxies under Apache
# ===================================================================

set -e  # Exit on any error

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}
error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# === 1. Periksa dependensi ===
log "Memeriksa dependensi..."
command -v apache2 >/dev/null 2>&1 || error "Apache2 tidak terinstal. Jalankan: sudo apt install apache2"
command -v php >/dev/null 2>&1 || error "PHP tidak terinstal. Jalankan: sudo apt install php libapache2-mod-php"
if ! php -m | grep -q curl; then
    error "Modul PHP 'curl' tidak aktif. Jalankan: sudo apt install php-curl && sudo systemctl restart apache2"
fi

# === 2. Tanya port LibreY (default: 8080) ===
read -p "Port LibreY (default: 8080): " LIBREY_PORT
LIBREY_PORT=${LIBREY_PORT:-8080}

# Uji koneksi ke LibreY
if curl -sf "http://localhost:${LIBREY_PORT}/search.php?q=test" >/dev/null 2>&1; then
    log "✅ LibreY terdeteksi di port ${LIBREY_PORT}"
else
    warn "⚠️ LibreY tidak merespons di port ${LIBREY_PORT}. Pastikan sudah dijalankan secara manual."
    read -p "Lanjutkan? (y/N): " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
fi

# === 3. Buat direktori aplikasi ===
APP_DIR="/var/www/ai"
log "Membuat direktori aplikasi di ${APP_DIR}..."
sudo mkdir -p "$APP_DIR"/{static/css,static/js}

# === 4. Buat file PHP (proxy & index) ===

# ollama-proxy.php
sudo tee "$APP_DIR/ollama-proxy.php" > /dev/null << 'EOF'
<?php
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST');
header('Access-Control-Allow-Headers: Content-Type');

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    http_response_code(405);
    echo json_encode(['error' => 'Method not allowed']);
    exit;
}

$input = json_decode(file_get_contents('php://input'), true);
if (!$input || !isset($input['prompt'])) {
    http_response_code(400);
    echo json_encode(['error' => 'Invalid input']);
    exit;
}

$url = 'http://localhost:11434/api/generate';
$data = [
    'model' => 'qwen2.5:0.5b',
    'prompt' => $input['prompt'],
    'stream' => false
];

$ch = curl_init($url);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_POST, true);
curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
curl_setopt($ch, CURLOPT_TIMEOUT, 120);

$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$error = curl_error($ch);
curl_close($ch);

if ($error) {
    http_response_code(500);
    echo json_encode(['error' => 'Ollama connection failed']);
    exit;
}

if ($httpCode !== 200) {
    http_response_code(500);
    echo json_encode(['error' => 'Ollama error']);
    exit;
}

echo $response;
?>
EOF

# librey-proxy.php (dengan port dinamis)
sudo tee "$APP_DIR/librey-proxy.php" > /dev/null << EOF
<?php
header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');

\$query = \$_GET['q'] ?? '';
if (!\$query) {
    http_response_code(400);
    echo json_encode(['error' => 'Missing query']);
    exit;
}

// Gunakan port LibreY dari setup
\$libreyUrl = 'http://localhost:${LIBREY_PORT}/search.php?q=' . urlencode(\$query);

\$ch = curl_init(\$libreyUrl);
curl_setopt(\$ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt(\$ch, CURLOPT_TIMEOUT, 10);
curl_setopt(\$ch, CURLOPT_USERAGENT, 'AI-Assistant/1.0');

\$response = curl_exec(\$ch);
\$httpCode = curl_getinfo(\$ch, CURLINFO_HTTP_CODE);
curl_close(\$ch);

if (\$httpCode !== 200) {
    http_response_code(502);
    echo json_encode(['error' => 'LibreY unreachable']);
    exit;
}

// Parse HTML untuk ekstrak hasil (karena LibreY tidak punya API JSON native)
libxml_use_internal_errors(true);
\$doc = new DOMDocument();
\$doc->loadHTML(\$response);

\$results = [];
\$items = \$doc->getElementsByTagName('div');
foreach (\$items as \$item) {
    if (\$item->getAttribute('class') === 'result') {
        \$a = \$item->getElementsByTagName('a')->item(0);
        \$title = \$a ? trim(\$a->textContent) : '';
        \$url = \$a ? \$a->getAttribute('href') : '';
        \$snippet = '';
        foreach (\$item->childNodes as \$child) {
            if (\$child->nodeType === XML_TEXT_NODE && trim(\$child->textContent)) {
                \$snippet = trim(\$child->textContent);
                break;
            }
        }
        if (\$title || \$url) {
            \$results[] = ['title' => \$title, 'url' => \$url, 'description' => \$snippet];
        }
    }
    if (count(\$results) >= 3) break;
}

echo json_encode(['results' => \$results]);
?>
EOF

# index.php
sudo tee "$APP_DIR/index.php" > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>AI Assistant</title>
    <link rel="stylesheet" href="/static/css/style.css?v=1.0" />
</head>
<body class="dark">
    <button id="theme-toggle" onclick="toggleTheme()">🌓</button>

    <div id="chat"></div>

    <div id="input-area">
        <input type="text" id="message" placeholder="Ketik pesan atau 'fly [pertanyaan]'..." autocomplete="off" />
        <button id="send" onclick="sendMessage()">➤</button>
    </div>

    <script src="/static/js/main.js?v=1.0"></script>
</body>
</html>
EOF

# === 5. CSS ===
sudo tee "$APP_DIR/static/css/style.css" > /dev/null << 'EOF'
:root {
  --bg: #000;
  --fg: #fff;
  --user-bg: #333;
  --ai-bg: #222;
  --border: #444;
  --button: #555;
  --hover: #666;
}

body.light {
  --bg: #fff;
  --fg: #000;
  --user-bg: #e0e0e0;
  --ai-bg: #f0f0f0;
  --border: #ccc;
  --button: #ddd;
  --hover: #bbb;
}

* { margin:0; padding:0; box-sizing:border-box; }
body {
  background: var(--bg);
  color: var(--fg);
  font-family: system-ui, sans-serif;
  height: 100vh;
  display: flex;
  flex-direction: column;
}
#chat {
  flex:1; overflow-y:auto; padding:1rem; display:flex; flex-direction:column; gap:1rem;
}
.msg {
  max-width:90%; padding:0.75rem 1rem; border-radius:12px; line-height:1.5; word-break:break-word;
}
.user { background:var(--user-bg); align-self:flex-end; }
.ai { background:var(--ai-bg); align-self:flex-start; }
.thinking { opacity:0.7; font-style:italic; }
.search { margin-top:0.5rem; font-size:0.9em; }
#input-area {
  display:flex; padding:1rem; gap:0.5rem; background:var(--bg); border-top:1px solid var(--border);
}
#message {
  flex:1; padding:0.75rem; border:1px solid var(--border); border-radius:24px;
  background:var(--bg); color:var(--fg); outline:none;
}
#message:focus { border-color:var(--hover); }
button {
  background:var(--button); border:none; border-radius:50%; width:44px; height:44px;
  color:var(--fg); cursor:pointer; display:flex; align-items:center; justify-content:center;
}
button:hover { background:var(--hover); }
#theme-toggle {
  position:absolute; top:1rem; right:1rem; border-radius:8px; width:auto; padding:0 12px;
}
@media (max-width:600px) { .msg { max-width:95%; } }
EOF

# === 6. JavaScript ===
sudo tee "$APP_DIR/static/js/main.js" > /dev/null << 'EOF'
document.addEventListener('DOMContentLoaded', () => {
  const chatBox = document.getElementById('chat');
  const input = document.getElementById('message');
  const sendBtn = document.getElementById('send');
  const themeToggle = document.getElementById('theme-toggle');

  // Load theme
  const savedTheme = localStorage.getItem('theme') || 'dark';
  document.body.className = savedTheme;

  const toggleTheme = () => {
    const newTheme = document.body.classList.contains('dark') ? 'light' : 'dark';
    document.body.className = newTheme;
    localStorage.setItem('theme', newTheme);
  };
  window.toggleTheme = toggleTheme;

  // Load history
  const loadHistory = () => {
    const hist = JSON.parse(localStorage.getItem('chatHistory') || '[]');
    hist.forEach(msg => addMessage(msg.text, msg.role));
  };
  loadHistory();

  const addMessage = (html, role) => {
    const div = document.createElement('div');
    div.className = `msg ${role}`;
    div.innerHTML = html;
    chatBox.appendChild(div);
    chatBox.scrollTo(0, chatBox.scrollHeight);
  };

  const showThinking = () => {
    const div = document.createElement('div');
    div.className = 'msg ai thinking';
    div.id = 'thinking';
    div.textContent = 'Mengetik...';
    chatBox.appendChild(div);
    chatBox.scrollTo(0, chatBox.scrollHeight);
  };

  const hideThinking = () => {
    const el = document.getElementById('thinking');
    if (el) el.remove();
  };

  const sendMessage = async () => {
    const userMsg = input.value.trim();
    if (!userMsg) return;
    input.value = '';

    addMessage(userMsg, 'user');
    const hist = JSON.parse(localStorage.getItem('chatHistory') || '[]');
    hist.push({ text: userMsg, role: 'user' });

    // Perintah pencarian: "fly ..."
    if (userMsg.toLowerCase().startsWith('fly ')) {
      const query = userMsg.substring(4).trim();
      if (!query) {
        addMessage('🔍 Gunakan: <code>fly [pertanyaan]</code>', 'ai');
        hist.push({ text: 'Instruksi pencarian', role: 'ai' });
        localStorage.setItem('chatHistory', JSON.stringify(hist));
        return;
      }

      addMessage(`🔍 Mencari: <b>${query}</b>`, 'ai');
      try {
        const res = await fetch(`/librey-proxy.php?q=${encodeURIComponent(query)}`);
        const data = await res.json();
        if (data.results && data.results.length > 0) {
          let reply = '';
          data.results.forEach(r => {
            reply += `<div class="search">📄 <a href="${r.url}" target="_blank">${r.title}</a><br>${r.description}</div><br>`;
          });
          addMessage(reply, 'ai');
        } else {
          addMessage('❌ Tidak ada hasil ditemukan.', 'ai');
        }
      } catch (e) {
        addMessage('❌ Gagal menghubungi LibreY.', 'ai');
      }
      hist.push({ text: 'Hasil pencarian', role: 'ai' });
      localStorage.setItem('chatHistory', JSON.stringify(hist));
      return;
    }

    // Kirim ke LLM
    showThinking();
    try {
      const resp = await fetch('/ollama-proxy.php', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ prompt: userMsg })
      });
      const data = await resp.json();
      hideThinking();
      const aiMsg = data.response?.trim() || 'Maaf, saya tidak mengerti.';
      addMessage(aiMsg, 'ai');
      hist.push({ text: aiMsg, role: 'ai' });
      localStorage.setItem('chatHistory', JSON.stringify(hist));
    } catch (e) {
      hideThinking();
      addMessage('❌ Gagal terhubung ke AI.', 'ai');
    }
  };

  sendBtn.onclick = sendMessage;
  input.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      sendMessage();
    }
  });
});
EOF

# === 7. Atur permission ===
sudo chown -R www-www-data "$APP_DIR"
sudo chmod -R 755 "$APP_DIR"

# === 8. Restart Apache ===
log "Restart Apache..."
sudo systemctl restart apache2

# === 9. Selesai ===
IP=$(hostname -I | awk '{print $1}' | head -n1)
log ""
log "✅ SETUP SELESAI!"
log ""
log "Buka di browser: http://$IP"
log ""
log "Fitur:"
log "- Chat dengan Qwen2.5:0.5b (pastikan Ollama jalan)"
log "- Ketik 'fly [query]' untuk cari via LibreY"
log "- Riwayat tersimpan di browser"
log "- Tema gelap/terang (tombol 🌓)"
log "- Responsif untuk semua perangkat"
