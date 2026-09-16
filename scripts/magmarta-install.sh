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
# Kurum ic DNS alan adlari. "*.suffix" o suffix'in tum alt alan adlarini kabul
# eder (apex haric). Fork yamasi (f) bunu hem hostname guard'inda hem de
# Better Auth trustedOrigins tarafinda calistirir.
ALLOWED_HOSTNAMES="${PAPERCLIP_ALLOWED_HOSTNAMES:-*.c-prot.local,*.marta.tr}"
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
  --allowed-hostnames L Virgullu ek hostname listesi; "*.ornek.local" wildcard
                       kabul eder (varsayilan: *.c-prot.local,*.marta.tr)
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
    --allowed-hostnames) ALLOWED_HOSTNAMES="$2"; shift 2 ;;
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
PAPERCLIP_ALLOWED_HOSTNAMES=$PUBLIC_HOST,$(hostname),localhost,127.0.0.1${ALLOWED_HOSTNAMES:+,$ALLOWED_HOSTNAMES}
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

# ── Yardimci betikler: izin tamiri + model girisi ────────────────
# Paperclip'in "Connect a model" ekrani operatore host'ta calistirilacak bir
# kabuk komutu veriyor. O komut root ile calistirilirsa CLI, kimlik dosyalarini
# root sahipli birakiyor; servis (paperclip kullanicisi) sonra onlari silemiyor
# ve akis "Internal server error" ile oluyor. Iki betik bunu kalici olarak
# engelliyor: giris her zaman servis kullanicisi olarak calisir, ve servis her
# baslayista sahipligi onarir.

cat > /usr/local/bin/paperclip-repair-perms <<REPAIR
#!/bin/sh
# Veri dizininde servis kullanicisine ait olmayan ilk dosyayi arar; bulursa
# tum agaci onarir. Tam eslesen bir agacta maliyeti tek bir metadata taramasi.
set -e
DATA_DIR="\${PAPERCLIP_HOME:-$DATA_DIR}"
SERVICE_USER="$SERVICE_USER"
[ -d "\$DATA_DIR" ] || exit 0
if [ -n "\$(find "\$DATA_DIR" \\( ! -user "\$SERVICE_USER" -o ! -group "\$SERVICE_USER" \\) -print -quit 2>/dev/null)" ]; then
  echo "paperclip-repair-perms: \$DATA_DIR icinde yabanci sahiplik bulundu, onariliyor"
  chown -R "\$SERVICE_USER:\$SERVICE_USER" "\$DATA_DIR"
fi
REPAIR
chmod 755 /usr/local/bin/paperclip-repair-perms

cat > /usr/local/bin/paperclip-login <<'LOGIN'
#!/usr/bin/env bash
# Paperclip model girisini DOGRU kullanici ile calistirir.
#
#   paperclip-login                 # etkilesimli (terminal yapistirma calisiyorsa)
#   paperclip-login --start         # URL'yi bas ve kodu beklemeye gec
#   paperclip-login --code <KOD>    # kodu ver, girisi tamamla
#   paperclip-login --cancel        # bekleyen girisi iptal et
#
# Saglayici ikinci arguman olarak verilir: claude (varsayilan) | codex | grok
#
# --start/--code ikilisi, kodu CLI'in tam ekran arayuzu yerine normal kabuk
# satirina yapistirmanizi saglar. Bazi SSH istemcileri TUI'ye yapistirmayi
# iletmiyor; kabuk satirina yapistirma genelde calisiyor.
set -euo pipefail

ENV_FILE=/etc/paperclip.env
[ -r "$ENV_FILE" ] || { echo "HATA: $ENV_FILE okunamadi (root olarak calistirin)." >&2; exit 1; }
get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-; }

DATA_DIR="$(get PAPERCLIP_HOME)"; DATA_DIR="${DATA_DIR:-/var/lib/paperclip}"
INSTANCE="$(get PAPERCLIP_INSTANCE_ID)"; INSTANCE="${INSTANCE:-default}"
SERVICE_USER="$(stat -c %U "$DATA_DIR" 2>/dev/null || echo paperclip)"
ROOT="$DATA_DIR/instances/$INSTANCE/ai-local-logins"
STATE=/run/paperclip-login

MODE=interactive
CODE=""
case "${1:-}" in
  --start)  MODE=start;  shift ;;
  --code)   MODE=code; CODE="${2:-}"; shift 2 || true ;;
  --cancel) MODE=cancel; shift ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
esac

PROVIDER="${1:-claude}"
case "$PROVIDER" in
  claude|anthropic) BIN=claude ;;
  codex|openai)     BIN=codex ;;
  grok)             BIN=grok ;;
  *) echo "Bilinmeyen saglayici: $PROVIDER (claude | codex | grok)" >&2; exit 1 ;;
esac

cleanup_state() {
  # setsid ile baslatildiklari icin her biri kendi surec grubunun lideri;
  # gruba sinyal gondermek alt surecleri de kapatir.
  for f in pid holder; do
    [ -f "$STATE/$f" ] || continue
    kill -- "-$(cat "$STATE/$f")" 2>/dev/null || kill "$(cat "$STATE/$f")" 2>/dev/null || true
  done
  rm -rf "$STATE"
}

if [ "$MODE" = cancel ]; then
  cleanup_state; echo "Bekleyen giris iptal edildi."; exit 0
fi

run_as() { runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" "$@"; }

login_cmd() {
  case "$PROVIDER" in
    claude|anthropic) run_as CLAUDE_CONFIG_DIR="$DIR" claude auth login ;;
    codex|openai)     run_as CODEX_HOME="$DIR" codex -c 'cli_auth_credentials_store="file"' login --device-auth ;;
    grok)             run_as GROK_HOME="$DIR" grok login --device-auth ;;
  esac
}

# ── --code: bekleyen girise kodu ilet ───────────────────────────
if [ "$MODE" = code ]; then
  [ -p "$STATE/fifo" ] || { echo "HATA: Bekleyen bir giris yok. Once: paperclip-login --start" >&2; exit 1; }
  [ -n "$CODE" ] || { echo "HATA: Kod bos. Kullanim: paperclip-login --code <KOD>" >&2; exit 1; }
  DIR="$(cat "$STATE/dir")"
  printf '%s\n' "$CODE" > "$STATE/fifo"
  echo "Kod iletildi, sonuc bekleniyor..."
  for _ in $(seq 1 60); do
    kill -0 "$(cat "$STATE/pid")" 2>/dev/null || break
    sleep 1
  done
  chown -R "$SERVICE_USER:$SERVICE_USER" "$DIR"
  echo "--- CLI ciktisi ---"; tail -6 "$STATE/log" 2>/dev/null
  echo
  if ls -A "$DIR" 2>/dev/null | grep -q credentials; then
    echo "BASARILI. Kimlik dosyalari:"; ls -1A "$DIR" | sed 's/^/  /'
    echo; echo "Paperclip sekmesine donup 'Connect' butonuna basin."
    cleanup_state
  else
    echo "Giris tamamlanmadi. Kodun suresi dolmus olabilir; bastan deneyin:"
    echo "  paperclip-login --cancel && paperclip-login --start"
    exit 1
  fi
  exit 0
fi

# ── Oturum dizinini bul (start + interactive) ───────────────────
UUID="$(ls -1t "$ROOT" 2>/dev/null | head -1 || true)"
if [ -z "$UUID" ]; then
  echo "HATA: Aktif bir giris oturumu yok." >&2
  echo "Paperclip arayuzunde once 'Connect a model' ekranini acin, sonra tekrar calistirin." >&2
  exit 1
fi
DIR="$ROOT/$UUID"
mkdir -p "$DIR"; chown -R "$SERVICE_USER:$SERVICE_USER" "$DIR"
command -v "$BIN" >/dev/null 2>&1 || { echo "HATA: '$BIN' PATH uzerinde yok." >&2; exit 1; }

echo "Oturum   : $UUID"
echo "Kullanici: $SERVICE_USER"
echo

# ── --start: arka planda baslat, URL'yi bas, kodu bekle ─────────
if [ "$MODE" = start ]; then
  cleanup_state
  mkdir -p "$STATE"; chown "$SERVICE_USER:$SERVICE_USER" "$STATE"; chmod 755 "$STATE"
  mkfifo -m 600 "$STATE/fifo"; chown "$SERVICE_USER:$SERVICE_USER" "$STATE/fifo"
  : > "$STATE/log"; chown "$SERVICE_USER:$SERVICE_USER" "$STATE/log"
  printf '%s' "$DIR" > "$STATE/dir"

  # Her ikisi de setsid ile baslatilir: SSH oturumu kapandiginda SIGHUP ile
  # olmezler. Tum fd'ler yonlendirilir, boylece "ssh ... --start" komutu
  # arka plandaki sureci bekleyip asili kalmaz.
  #
  # FIFO'yu acik tutan yazar, CLI'in open() cagrisinin beklememesi ve kod
  # gelene kadar okuma ucunun EOF gormemesi icin gerekli.
  setsid bash -c 'exec 9>"$1"; sleep 3600' _ "$STATE/fifo" </dev/null >/dev/null 2>&1 &
  echo $! > "$STATE/holder"

  case "$PROVIDER" in
    claude|anthropic)
      setsid runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" CLAUDE_CONFIG_DIR="$DIR" \
        claude auth login < "$STATE/fifo" > "$STATE/log" 2>&1 & ;;
    codex|openai)
      setsid runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" CODEX_HOME="$DIR" \
        codex -c 'cli_auth_credentials_store="file"' login --device-auth < "$STATE/fifo" > "$STATE/log" 2>&1 & ;;
    grok)
      setsid runuser -u "$SERVICE_USER" -- env HOME="$DATA_DIR" GROK_HOME="$DIR" \
        grok login --device-auth < "$STATE/fifo" > "$STATE/log" 2>&1 & ;;
  esac
  echo $! > "$STATE/pid"

  for _ in $(seq 1 40); do
    grep -qE 'https?://' "$STATE/log" && break
    sleep 1
  done
  URL="$(grep -oE 'https?://[^ ]+' "$STATE/log" | head -1 || true)"
  if [ -z "$URL" ]; then
    echo "HATA: CLI bir URL basmadi. Ciktisi:" >&2; cat "$STATE/log" >&2; cleanup_state; exit 1
  fi
  cat <<MSG
1) Su adresi tarayicinizda acin ve yetkilendirin:

$URL

2) Donen kodu kopyalayin ve BU kabuk satirina yapistirip calistirin:

   paperclip-login --code <KOD>

Vazgecmek icin: paperclip-login --cancel
MSG
  exit 0
fi

# ── Etkilesimli mod ─────────────────────────────────────────────
set +e
login_cmd
status=$?
set -e
chown -R "$SERVICE_USER:$SERVICE_USER" "$DIR"
echo
if [ "$status" -eq 0 ] && ls -A "$DIR" 2>/dev/null | grep -q credentials; then
  echo "BASARILI. Kimlik dosyalari:"; ls -1A "$DIR" | sed 's/^/  /'
  echo; echo "Paperclip sekmesine donup 'Connect' butonuna basin."
else
  echo "Giris tamamlanmadi (cikis kodu $status)."
  echo "Terminaliniz yapistirmaya izin vermiyorsa iki adimli modu deneyin:"
  echo "  paperclip-login --start"
  exit 1
fi
LOGIN
chmod 755 /usr/local/bin/paperclip-login

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
# Yanlislikla root ile calistirilmis bir CLI, veri dizininde root sahipli dosya
# birakabiliyor; servis onlari silemeyince model baglama akisi patliyor.
# Bu, servisi acmadan once sahipligi onarir ("+" = root olarak calistir).
ExecStartPre=+/usr/local/bin/paperclip-repair-perms
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
  Hostname    : $PUBLIC_HOST, $(hostname), localhost${ALLOWED_HOSTNAMES:+, $ALLOWED_HOSTNAMES}
  Telemetri   : $([ "$TELEMETRY" = "on" ] && echo "ACIK" || echo "KAPALI")
  Docker      : $(command -v docker >/dev/null 2>&1 && docker --version 2>/dev/null | cut -d, -f1 || echo "kurulu degil")

  Model baglama (Connect a model ekranini actiktan sonra):
    paperclip-login          # Claude
    paperclip-login codex    # OpenAI Codex
    ("claude auth login" komutunu ELLE root ile calistirmayin; dosyalar root
     sahipli kalir ve baglanti akisi hata verir.)

  Servis:
    systemctl status paperclip
    journalctl -u paperclip -f
    systemctl restart paperclip

  Guncelleme:
    bash $0 --update

  Fork'u upstream ile senkronlama:
    Gunluk otomatik — .github/workflows/sync-upstream.yml (03:00 UTC).
    Elle tetikleme:  gh workflow run sync-upstream.yml -R magmarta/paperclip
    ("gh repo sync" KULLANMA: fork kendi gizlilik commit'lerini tasiyor,
     fast-forward reddedilir, --force ise o commit'leri siler.)

  Gizlilik: (a) telemetri (b) feedback trace (c) duyuru akisi (d) Sentry
  (e) Paperclip Cloud — depoda kalici kapali. Bkz. .github/FORK-POLICY.md

EOF
