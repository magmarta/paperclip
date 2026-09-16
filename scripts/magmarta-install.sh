#!/usr/bin/env bash
#
# Paperclip native kurulum betigi — Debian 12/13, Ubuntu 22.04+
#
# Paperclip'in kendisi bir systemd servisi olarak dogrudan host'ta calisir,
# konteyner icinde DEGIL. Docker yine de kurulur (--no-docker ile kapatilir):
# ajanlarin izole workspace/sandbox saglayicilari ona ihtiyac duyar.
#
# Hedef sanal makinede root olarak calistirilir:
#   curl -fsSLO <bu-dosya> && bash install-paperclip.sh
#
# Uzaktan calistirmak icin:
#   scp install-paperclip.sh root@HEDEF:/root/ && ssh root@HEDEF 'bash /root/install-paperclip.sh'
#
# Yeniden calistirilabilir (idempotent): mevcut kurulumu gunceller, uretilmis
# secret'lari ve veritabanini korur.
#
set -euo pipefail

# ─────────────────────────── Ayarlar ───────────────────────────
REPO_URL="${PAPERCLIP_REPO_URL:-https://github.com/magmarta/paperclip.git}"
UPSTREAM_URL="${PAPERCLIP_UPSTREAM_URL:-https://github.com/paperclipai/paperclip.git}"
REF="${PAPERCLIP_REF:-master}"
APP_DIR="${PAPERCLIP_APP_DIR:-/opt/paperclip}"
DATA_DIR="${PAPERCLIP_DATA_DIR:-/var/lib/paperclip}"
SERVICE_USER="${PAPERCLIP_USER:-paperclip}"
PORT="${PAPERCLIP_PORT:-3100}"
PUBLIC_URL="${PAPERCLIP_PUBLIC_URL:-}"      # bos ise birincil IP'den turetilir
DEPLOYMENT_MODE="${PAPERCLIP_DEPLOYMENT_MODE:-authenticated}"   # authenticated | local_trusted
DEPLOYMENT_EXPOSURE="${PAPERCLIP_DEPLOYMENT_EXPOSURE:-private}" # private | public
TELEMETRY="${PAPERCLIP_TELEMETRY:-off}"     # off | on  (bkz. GIZLILIK notu asagida)
INSTALL_AGENT_CLIS="${PAPERCLIP_INSTALL_AGENT_CLIS:-1}"
INSTALL_DOCKER="${PAPERCLIP_INSTALL_DOCKER:-1}"   # ajan izolasyonu / sandbox saglayicilari icin
UPDATE_ONLY="${PAPERCLIP_UPDATE_ONLY:-0}"

RUSTUP_VERSION=1.29.0
RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792

usage() {
  cat <<'EOF'
Kullanim: install-paperclip.sh [secenekler]

  --repo URL           Git deposu (varsayilan: https://github.com/magmarta/paperclip.git)
  --ref REF            Branch/tag/commit (varsayilan: master)
  --port N             Dinlenecek port (varsayilan: 3100)
  --public-url URL     Kullanicilarin erisecegi taban URL (varsayilan: http://<birincil-ip>:<port>)
  --app-dir DIZIN      Uygulama dizini (varsayilan: /opt/paperclip)
  --data-dir DIZIN     Veri dizini: DB, workspace, yuklemeler (varsayilan: /var/lib/paperclip)
  --mode MOD           authenticated | local_trusted (varsayilan: authenticated)
  --telemetry on|off   Birinci-taraf telemetri (varsayilan: off)
  --no-agent-clis      claude/codex/gemini/opencode/kimi CLI'larini kurma
  --no-docker          Docker Engine kurma (varsayilan: kurulur)
  --update             Sadece guncelle: git pull + yeniden derle + servisi yeniden baslat
  -h, --help           Bu yardim

Ornekler:
  bash install-paperclip.sh
  bash install-paperclip.sh --public-url http://paperclip.sirket.local:3100
  bash install-paperclip.sh --update
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --public-url) PUBLIC_URL="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --mode) DEPLOYMENT_MODE="$2"; shift 2 ;;
    --telemetry) TELEMETRY="$2"; shift 2 ;;
    --no-agent-clis) INSTALL_AGENT_CLIS=0; shift ;;
    --no-docker) INSTALL_DOCKER=0; shift ;;
    --update) UPDATE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Bilinmeyen secenek: $1" >&2; usage; exit 1 ;;
  esac
done

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[HATA] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Bu betik root olarak calistirilmali."
command -v systemctl >/dev/null 2>&1 || die "systemd bulunamadi; bu betik systemd tabanli dagitimlar icindir."

ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
case "$ARCH" in
  amd64) RUST_TARGET=x86_64-unknown-linux-gnu; RUSTUP_SHA256="$RUSTUP_SHA256_AMD64"; NODE_ARCH=x64 ;;
  arm64) RUST_TARGET=aarch64-unknown-linux-gnu; RUSTUP_SHA256="$RUSTUP_SHA256_ARM64"; NODE_ARCH=arm64 ;;
  *) die "Desteklenmeyen mimari: $ARCH (amd64 veya arm64 gerekli)" ;;
esac

if [ -z "$PUBLIC_URL" ]; then
  PRIMARY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  [ -n "$PRIMARY_IP" ] || PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$PRIMARY_IP" ] || die "Birincil IP tespit edilemedi; --public-url ile elle verin."
  PUBLIC_URL="http://${PRIMARY_IP}:${PORT}"
fi
PUBLIC_HOST="$(printf '%s' "$PUBLIC_URL" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"

export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
export PATH=/usr/local/cargo/bin:/usr/local/bin:$PATH

# ───────────────────── 1. Sistem paketleri ─────────────────────
if [ "$UPDATE_ONLY" -eq 0 ]; then
  log "1/8 Sistem paketleri"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # gh bazi dagitimlarda yok; ayri deneyip basarisizligi yutuyoruz.
  apt-get install -y -qq \
    ca-certificates curl wget git jq ripgrep openssh-client \
    gcc g++ make libc6-dev pkg-config xz-utils unzip openssl
  apt-get install -y -qq gh 2>/dev/null || warn "gh (GitHub CLI) paketi bulunamadi, atlandi."

  # ───────────────────── 2. Node.js 24 ─────────────────────
  log "2/8 Node.js 24"
  if ! node --version 2>/dev/null | grep -q '^v24\.'; then
    NODE_TARBALL="$(curl -fsSL https://nodejs.org/dist/latest-v24.x/ \
      | grep -o "node-v24\.[0-9]*\.[0-9]*-linux-${NODE_ARCH}\.tar\.xz" | head -1)"
    [ -n "$NODE_TARBALL" ] || die "Node.js 24 surumu tespit edilemedi."
    curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/latest-v24.x/${NODE_TARBALL}"
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner
    rm -f /tmp/node.tar.xz
  fi
  node --version | sed 's/^/    node /'

  log "3/8 pnpm (corepack)"
  corepack enable
  # Depo kendi pnpm surumunu packageManager alaninda pinliyor; corepack onu uygular.
  corepack prepare pnpm@9.15.4 --activate
  pnpm --version | sed 's/^/    pnpm /'

  # ───────────────────── 4. Rust (runner ikilisi) ─────────────────────
  log "4/8 Rust araç zinciri"
  if ! command -v rustup >/dev/null 2>&1; then
    curl -fsSLo /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUST_TARGET}/rustup-init"
    echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c -
    chmod +x /tmp/rustup-init
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none
    rm -f /tmp/rustup-init
  fi
  cat > /etc/profile.d/rust.sh <<'EOF'
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export PATH=/usr/local/cargo/bin:$PATH
EOF
  chmod 644 /etc/profile.d/rust.sh

  # ───────────────────── 5. Docker Engine ─────────────────────
  # Paperclip'in kendisi Docker'da CALISMAZ (native systemd servisi). Docker,
  # ajanlarin izole workspace/sandbox saglayicilari icin kurulur.
  if [ "$INSTALL_DOCKER" -eq 1 ]; then
    log "5/8 Docker Engine (ajan sandbox'lari icin)"
    if ! command -v docker >/dev/null 2>&1; then
      . /etc/os-release
      DOCKER_DISTRO="$ID"
      case "$ID" in
        debian|ubuntu) : ;;
        *) DOCKER_DISTRO="$(echo "${ID_LIKE:-debian}" | awk '{print $1}')" ;;
      esac
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -qq
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable --now docker
    docker --version | sed 's/^/    /'
  else
    log "5/8 Docker Engine — atlandi (--no-docker)"
  fi
fi

# ───────────────────── 5. Kaynak kod ─────────────────────
log "6/8 Kaynak kod ($REPO_URL @ $REF)"
git config --global --add safe.directory "$APP_DIR" 2>/dev/null || true
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" remote set-url origin "$REPO_URL"
  git -C "$APP_DIR" remote get-url upstream >/dev/null 2>&1 \
    || git -C "$APP_DIR" remote add upstream "$UPSTREAM_URL"
  git -C "$APP_DIR" fetch --prune origin
  git -C "$APP_DIR" checkout -q "$REF"
  # Branch ise ilerlet; tag/commit ise checkout yeterli.
  if git -C "$APP_DIR" symbolic-ref -q HEAD >/dev/null; then
    git -C "$APP_DIR" reset --hard "origin/$REF"
  fi
else
  mkdir -p "$(dirname "$APP_DIR")"
  git clone "$REPO_URL" "$APP_DIR"
  git -C "$APP_DIR" remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
  git -C "$APP_DIR" checkout -q "$REF"
fi
echo "    HEAD: $(git -C "$APP_DIR" rev-parse --short HEAD)"

# Rust surumu depodaki rust-toolchain.toml tarafindan secilir.
( cd "$APP_DIR/packages/paperclip-runner" && rustup show >/dev/null )

# ───────────────────── 6. Derleme ─────────────────────
log "7/8 Derleme (ilk kurulumda 15-30 dk surebilir)"
cd "$APP_DIR"
export NODE_OPTIONS=--max-old-space-size=4096
# CI=1 telemetriyi derleme sirasinda da kapali tutar.
export CI=1
pnpm install --frozen-lockfile
pnpm --filter @paperclipai/ui build
pnpm --filter @paperclipai/plugin-sdk build
pnpm --filter @paperclipai/server build
[ -f "$APP_DIR/server/dist/index.js" ] || die "Derleme ciktisi olusmadi: server/dist/index.js"

# ───────────────────── 7. Kullanici, ortam, servis ─────────────────────
log "8/8 Servis kurulumu"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$DATA_DIR" --shell /bin/bash "$SERVICE_USER"
fi
# Ajanlarin sandbox konteynerleri acabilmesi icin docker grubuna al. Bu, servis
# kullanicisina host uzerinde root-esdeger yetki verir; istemiyorsan --no-docker.
if [ "$INSTALL_DOCKER" -eq 1 ] && getent group docker >/dev/null 2>&1; then
  usermod -aG docker "$SERVICE_USER"
fi
mkdir -p "$DATA_DIR/instances/default"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" "$APP_DIR"

# Mevcut secret'lar korunur; yoksa uretilir.
if [ -f /etc/paperclip.env ]; then
  AUTH_SECRET="$(grep -E '^BETTER_AUTH_SECRET=' /etc/paperclip.env | cut -d= -f2-)"
  SIGN_SECRET="$(grep -E '^PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=' /etc/paperclip.env | cut -d= -f2-)"
fi
[ -n "${AUTH_SECRET:-}" ] || AUTH_SECRET="$(openssl rand -hex 32)"
[ -n "${SIGN_SECRET:-}" ] || SIGN_SECRET="$(openssl rand -hex 32)"

{
  cat <<EOF
NODE_ENV=production
HOME=$DATA_DIR
HOST=0.0.0.0
PORT=$PORT
SERVE_UI=true
PAPERCLIP_HOME=$DATA_DIR
PAPERCLIP_INSTANCE_ID=default
PAPERCLIP_CONFIG=$DATA_DIR/instances/default/config.json
PAPERCLIP_DEPLOYMENT_MODE=$DEPLOYMENT_MODE
PAPERCLIP_DEPLOYMENT_EXPOSURE=$DEPLOYMENT_EXPOSURE
PAPERCLIP_PUBLIC_URL=$PUBLIC_URL
PAPERCLIP_ALLOWED_HOSTNAMES=$PUBLIC_HOST,$(hostname),localhost,127.0.0.1
BETTER_AUTH_SECRET=$AUTH_SECRET
PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$SIGN_SECRET
OPENCODE_ALLOW_ALL_MODELS=true
GEMINI_SANDBOX=false
PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
  # GIZLILIK: telemetri kapaliyken hicbir birinci-taraf ping disari cikmaz.
  if [ "$TELEMETRY" != "on" ]; then
    cat <<'EOF'
PAPERCLIP_TELEMETRY_DISABLED=1
DO_NOT_TRACK=1
PAPERCLIP_ANNOUNCEMENTS_ENABLED=false
EOF
  fi
} > /etc/paperclip.env
chown "root:$SERVICE_USER" /etc/paperclip.env
chmod 640 /etc/paperclip.env

cat > /etc/systemd/system/paperclip.service <<EOF
[Unit]
Description=Paperclip AI agent orchestration server
Documentation=https://docs.paperclip.ing
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/paperclip.env
ExecStart=/usr/local/bin/node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillMode=mixed
# Ajan surecleri alt surec birakabiliyor; pid tavani guvenlik agi.
TasksMax=4096
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paperclip

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable paperclip.service >/dev/null
systemctl restart paperclip.service

# ───────────────────── Agent CLI'lari ─────────────────────
if [ "$INSTALL_AGENT_CLIS" -eq 1 ] && [ "$UPDATE_ONLY" -eq 0 ]; then
  log "Agent CLI araclari"
  npm install --global --omit=dev --no-fund --no-audit \
    @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai \
    @google/gemini-cli@latest @moonshot-ai/kimi-code@latest \
    || warn "Bazi agent CLI'lari kurulamadi; Paperclip yine de calisir."
fi

# ───────────────────── Saglik kontrolu ─────────────────────
log "Saglik kontrolu"
ok=0
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  case "$code" in
    200|302|307|401) ok=1; break ;;
  esac
  if ! systemctl is-active --quiet paperclip.service; then
    journalctl -u paperclip -n 60 --no-pager
    die "Servis baslatilamadi."
  fi
  sleep 3
done
[ "$ok" -eq 1 ] || { journalctl -u paperclip -n 60 --no-pager; die "Sunucu ${PORT} portunda yanit vermedi."; }

cat <<EOF

╭──────────────────────────────────────────────────────────────╮
│  Paperclip calisiyor                                         │
╰──────────────────────────────────────────────────────────────╯

  Arayuz      : $PUBLIC_URL
  Uygulama    : $APP_DIR  ($(git -C "$APP_DIR" rev-parse --short HEAD))
  Veri        : $DATA_DIR  (gomulu PostgreSQL burada)
  Ortam       : /etc/paperclip.env
  Telemetri   : $([ "$TELEMETRY" = "on" ] && echo "ACIK" || echo "KAPALI")
  Docker      : $(command -v docker >/dev/null 2>&1 && docker --version 2>/dev/null | cut -d, -f1 || echo "kurulu degil")

  Servis:
    systemctl status paperclip
    journalctl -u paperclip -f
    systemctl restart paperclip

  Guncelleme:
    bash $0 --update

  Fork'u upstream ile senkronlama (once GitHub'da veya yerelde):
    gh repo sync magmarta/paperclip --source paperclipai/paperclip

EOF
