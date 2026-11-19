#!/bin/bash
# Первичная настройка сервера «Бюро» (Ubuntu 24.04). Вставляется в поле cloud-init при создании сервера
# в Timeweb Cloud и выполняется один раз при первом запуске от root.
#
# Здесь нет ни паролей, ни ключей: все секреты сервер создаёт сам и хранит только у себя
# (/etc/buro/secrets.env, права 600). Код берётся из закрытого репозитория gudisigor/buro-server
# по ключу только для чтения, который сервер тоже создаёт сам — его публичную часть
# нужно один раз добавить в GitHub: Settings → Deploy keys. Пока ключ не добавлен,
# на http://<IP-сервера>/ видна страница состояния с этим публичным ключом.
#
# Дальше всё, что лежит в репозитории в deploy/apply.sh, выполняется после каждого обновления кода.
set -euo pipefail
umask 022
exec > >(tee -a /var/log/buro-bootstrap.log) 2>&1
echo "== bootstrap $(date -Is)"

REPO="git@github.com:gudisigor/buro-server.git"
export DEBIAN_FRONTEND=noninteractive

# Свежий сервер сам обновляется при первом запуске: ждём, пока apt освободится.
command -v cloud-init >/dev/null && cloud-init status --wait >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  pgrep -x 'apt|apt-get|dpkg' >/dev/null || break
  [ "$i" = 1 ] && echo "Жду завершения автообновления системы..."
  sleep 5
done
# Зеркало Ubuntu в России (archive.ubuntu.com отсюда отвечает медленно).
for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
  [ -f "$f" ] && sed -i -E 's#https?://([a-z]+\.)?(archive|security)\.ubuntu\.com/ubuntu/?#http://mirror.yandex.ru/ubuntu/#g' "$f"
  true
done
APT="apt-get -o DPkg::Lock::Timeout=900"
$APT update -y
$APT install -y ca-certificates curl gnupg git ufw postgresql debian-keyring debian-archive-keyring apt-transport-https

# Node.js 24 (NodeSource) и Caddy (официальный репозиторий) — Caddy сам получает сертификаты HTTPS.
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
$APT update -y
$APT install -y nodejs caddy

# Брандмауэр: только SSH и веб.
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw --force enable

# Пользователь приложения и ключ для чтения репозитория.
id buro >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/buro --shell /bin/bash buro
install -d -m 700 -o buro -g buro /home/buro/.ssh
[ -f /home/buro/.ssh/id_ed25519 ] || sudo -u buro ssh-keygen -t ed25519 -N '' -C 'buro-server deploy (read-only)' -f /home/buro/.ssh/id_ed25519
ssh-keyscan -t ed25519,rsa github.com 2>/dev/null > /home/buro/.ssh/known_hosts
chown buro:buro /home/buro/.ssh/known_hosts

# База данных: пользователь и пароль создаются здесь и никуда не выводятся.
install -d -m 750 -o root -g buro /etc/buro
if [ ! -f /etc/buro/secrets.env ]; then
  DBPASS=$(openssl rand -hex 24)
  SECRET=$(openssl rand -hex 32)
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE buro LOGIN PASSWORD '${DBPASS}';"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE buro OWNER buro;"
  umask 077
  cat > /etc/buro/secrets.env <<EOF
DATABASE_URL=postgres://buro:${DBPASS}@127.0.0.1:5432/buro
BURO_SECRET=${SECRET}
EOF
  chown root:buro /etc/buro/secrets.env; chmod 640 /etc/buro/secrets.env
  unset DBPASS SECRET
fi

# Скрипт обновления: забирает код и запускает deploy/apply.sh из репозитория.
cat > /usr/local/bin/buro-update <<'EOF'
#!/bin/bash
# Забирает свежий код из gudisigor/buro-server и применяет его (deploy/apply.sh). Запускается таймером.
set -uo pipefail
APP=/opt/buro/app
STATUS=/var/www/status/index.html
REPO="git@github.com:gudisigor/buro-server.git"
status() {
  local state="$1"
  local key; key=$(cat /home/buro/.ssh/id_ed25519.pub)
  local rev="—"; [ -d "$APP/.git" ] && rev=$(sudo -u buro git -C "$APP" rev-parse --short HEAD 2>/dev/null || echo "—")
  cat > "$STATUS" <<HTML
<!doctype html><meta charset="utf-8"><title>Бюро — сервер</title>
<body style="font:16px/1.5 system-ui;max-width:760px;margin:40px auto;padding:0 20px">
<h1>Сервер «Бюро»</h1>
<p><b>Состояние:</b> ${state}</p>
<p><b>Версия кода:</b> ${rev} · <b>проверено:</b> $(date '+%d.%m.%Y %H:%M:%S %Z')</p>
<p><b>Ключ для чтения репозитория</b> (публичный, добавить в GitHub → buro-server → Settings → Deploy keys, без права записи):</p>
<pre style="white-space:pre-wrap;word-break:break-all;background:#f3efe6;padding:12px;border-radius:8px">${key}</pre>
</body>
HTML
}
mkdir -p /var/www/status /opt/buro; chmod 755 /var/www /var/www/status
chown buro:buro /opt/buro
if [ ! -d "$APP/.git" ]; then
  if sudo -u buro git clone -q "$REPO" "$APP" 2>/tmp/buro-clone.err; then
    status "код получен, настраиваю…"
    if bash "$APP/deploy/apply.sh"; then
      mkdir -p /var/lib/buro; sudo -u buro git -C "$APP" rev-parse HEAD > /var/lib/buro/applied; status "работает"
    else
      status "ошибка при настройке (см. /var/log/buro-update.log)"
    fi
  else
    status "жду доступа к репозиторию: добавьте ключ ниже в GitHub"
  fi
  exit 0
fi
sudo -u buro git -C "$APP" fetch -q origin main || { status "не удалось связаться с GitHub"; exit 0; }
LOCAL=$(sudo -u buro git -C "$APP" rev-parse HEAD); REMOTE=$(sudo -u buro git -C "$APP" rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ] || [ ! -f /var/lib/buro/applied ] || [ "$(cat /var/lib/buro/applied)" != "$REMOTE" ]; then
  sudo -u buro git -C "$APP" reset -q --hard origin/main
  status "обновляю…"
  if bash "$APP/deploy/apply.sh"; then
    mkdir -p /var/lib/buro; echo "$REMOTE" > /var/lib/buro/applied; status "работает"
  else
    status "ошибка при обновлении (см. /var/log/buro-update.log)"
  fi
else
  status "работает"
fi
EOF
chmod 755 /usr/local/bin/buro-update

cat > /etc/systemd/system/buro-update.service <<'EOF'
[Unit]
Description=Бюро: обновление кода из GitHub
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/buro-update
StandardOutput=append:/var/log/buro-update.log
StandardError=append:/var/log/buro-update.log
EOF
cat > /etc/systemd/system/buro-update.timer <<'EOF'
[Unit]
Description=Бюро: проверять обновления каждые 2 минуты
[Timer]
OnBootSec=30s
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF

# Пока код не получен — Caddy показывает страницу состояния по IP.
mkdir -p /var/www/status
cat > /etc/caddy/Caddyfile <<'EOF'
:80 {
  root * /var/www/status
  file_server
}
EOF
systemctl daemon-reload
systemctl restart caddy
systemctl enable --now buro-update.timer
/usr/local/bin/buro-update || true
echo "== bootstrap done $(date -Is)"
