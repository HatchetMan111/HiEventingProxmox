#!/usr/bin/env bash
#
# Hi.Events – Proxmox VE Community-Scripts Style Installer
# --------------------------------------------------------
# App:     Hi.Events – Open-Source Event-Management & Ticketing (Eventbrite-Alternative)
# Stack:   PHP 8.3 / Laravel + React 19 + PostgreSQL 17 + Redis 7 (Docker All-in-One)
# Upstream: https://github.com/HiEventsDev/hi.events
# Web UI:  http://<LXC-IP>:8123
# Stil:    Proxmox VE Community Scripts (community-scripts.github.io/ProxmoxVE)
# Host:    Auf dem Proxmox-Host als root ausführen:
#          bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"
#
# -E ist Pflicht: ohne -E wird der ERR-Trap NICHT in Funktionen/Subshells vererbt
# (Folge: stiller Abbruch ohne Fehlerkette). Siehe Regressionstest mit Mock-pct.
set -Eeuo pipefail

# ============================================================================
# VARIABLEN (oben, Community-Scripts-konform – alles per ENV/Flag überschreibbar)
# ============================================================================
APP="${APP:-hi-events}"
APP_FRIENDLY="${APP_FRIENDLY:-Hi.Events}"
SCRIPT_VERSION="${SCRIPT_VERSION:-1.2.5}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/HiEventsDev/hi.events}"
HI_EVENTS_IMAGE="${HI_EVENTS_IMAGE:-daveearley/hi.events-all-in-one:latest}"
HI_EVENTS_VERSION="${HI_EVENTS_VERSION:-latest}"   # nur Info/Tag-Doku, Image-Tag steckt in HI_EVENTS_IMAGE

CTID="${CTID:-}"                                   # leer = nächste freie ID via pvesh
HOSTNAME_CT="${HOSTNAME_CT:-hi-events}"
VAR_CPU="${VAR_CPU:-2}"
VAR_RAM="${VAR_RAM:-4096}"                         # All-in-One + Postgres + Redis: 4 GB empfohlen (Min. 2048)
VAR_DISK="${VAR_DISK:-12}"                         # GB, Min. 8
VAR_OS_TEMPLATE="${VAR_OS_TEMPLATE:-debian-12-standard}"  # pveam-Template-Präfix
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
CONTAINER_STORAGE="${CONTAINER_STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
NET_CONFIG="${NET_CONFIG:-dhcp}"                   # "dhcp" oder statisch "192.168.1.50/24,gw=192.168.1.1"
NAMESERVER="${NAMESERVER:-1.1.1.1}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"                  # 1 = unprivileged + nesting (Docker-fähig)
FEATURES="${FEATURES:-nesting=1,keyctl=1}"
ONBOOT="${ONBOOT:-1}"
START_AFTER_CREATE="${START_AFTER_CREATE:-1}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

WEB_PORT="${WEB_PORT:-8123}"                       # Web UI Port (Container + Host-Seite identisch)
APP_DIR="${APP_DIR:-/opt/hi-events}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"         # leer = zufällig generieren (idempotent: bleibt erhalten)
# --- Admin-Zugang (Upstream hat KEIN Default-Login → Installer legt einen Admin an) ---
ADMIN_EMAIL="${ADMIN_EMAIL:-}"                     # leer = interaktiv abfragen (TTY) bzw. Default unten
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"               # leer = abfragen/generieren (Hi.Events-Policy: min. 8 Zeichen)
ADMIN_FIRSTNAME="${ADMIN_FIRSTNAME:-Admin}"
ADMIN_LASTNAME="${ADMIN_LASTNAME:-User}"
ADMIN_DEFAULT_EMAIL="${ADMIN_DEFAULT_EMAIL:-admin@hi-events.local}"
# Standard-Login (öffentlich dokumentiert, bitte nach erstem Login in der UI ändern!):
ADMIN_DEFAULT_PASSWORD="${ADMIN_DEFAULT_PASSWORD:-HiEvents-Admin-123}"
SKIP_ADMIN_SETUP="${SKIP_ADMIN_SETUP:-0}"          # 1 = kein Admin anlegen (nur Stack installieren)
REINSTALL="${REINSTALL:-0}"                        # 1 = Container bei Existenz neu erstellen (DATENVERLUST)
MODE="${MODE:-lxc}"                                # "lxc" (Standard) oder "vm" (leistungshungrig / kein nesting)
VM_CPU="${VM_CPU:-2}"
VM_RAM="${VM_RAM:-4096}"
VM_DISK="${VM_DISK:-20G}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"
VM_IMAGE_URL="${VM_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2}"

LOG_FILE="${LOG_FILE:-/var/log/${APP}-install.log}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
HEALTH_WAIT_SECS="${HEALTH_WAIT_SECS:-240}"

# ============================================================================
# FARBEN / LOGGING (Community-Scripts-Stil)
# ============================================================================
YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"; BGN="\033[4;92m"
# HINWEIS: Alle Fortschrittsmeldungen gehen nach stderr – stdout ist für Daten
# reserviert (z. B. template=$(ensure_template) darf NUR den Pfad enthalten).
msg_info()  { echo -e "${YW} ● $*${CL}" >&2; }
msg_ok()    { echo -e "${GN} ✓ $*${CL}" >&2; }
msg_error() { echo -e "${RD} ✗ $*${CL}" >&2; }

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE" >&2; }

usage() {
  cat <<EOF
${APP_FRIENDLY} Proxmox Installer (Community-Scripts-Stil)

Verwendung:
  bash -c "\$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"
  # oder lokal:
  CTID=101 ./install/hi-events.sh [--ctid 101] [--cpu 2] [--ram 4096] [--disk 12]
                                  [--storage local-lvm] [--bridge vmbr0] [--ip dhcp]
                                  [--vm] [--reinstall] [--skip-admin] [--uninstall] [-h]

ENV-Overrides: CTID HOSTNAME_CT VAR_CPU VAR_RAM VAR_DISK CONTAINER_STORAGE TEMPLATE_STORAGE
               BRIDGE NET_CONFIG HI_EVENTS_IMAGE POSTGRES_PASSWORD MODE=vm REINSTALL=1
               ADMIN_EMAIL ADMIN_PASSWORD ADMIN_FIRSTNAME ADMIN_LASTNAME SKIP_ADMIN_SETUP=1
Admin: Ohne ENV wird interaktiv gefragt (E-Mail + Passwort, min. 8 Zeichen);
       ohne TTY wird generiert und am Ende angezeigt.
EOF
}

# ============================================================================
# FEHLERHANDLER – komplette Fehlermeldungskette (niemals nur letzte Zeile)
# ============================================================================
error_trap() {
  local exit_code=$?
  local failed_cmd="${BASH_COMMAND:-unbekannt}"
  echo "" >&2
  msg_error "INSTALLATION FEHLGESCHLAGEN (Exit-Code: ${exit_code})"
  echo -e "${YW}--- Fehlermeldungskette (vollständig) ---${CL}" >&2
  echo "  Befehl    : ${failed_cmd}" >&2
  echo "  Exit-Code : ${exit_code}" >&2
  echo "  Pipe-Status: ${PIPESTATUS[*]:-n/a} (bei Pipelines: Austrittscodes aller Glieder)" >&2
  echo "  Zeile     : ${BASH_LINENO[0]:-?} (Funktion: ${FUNCNAME[1]:-main})" >&2
  echo "  Stacktrace:" >&2
  local i=0 frame
  while frame=$(caller $i 2>/dev/null); do echo "    #${i} ${frame}" >&2; i=$((i+1)); done
  echo "  Log-Datei : ${LOG_FILE}" >&2
  echo "" >&2
  echo "--- Letzte 40 Log-Zeilen ---" >&2
  tail -n 40 "$LOG_FILE" 2>/dev/null >&2 || true
  echo "" >&2
  if [[ -n "${CTID:-}" ]] && command -v pct >/dev/null 2>&1 && pct status "$CTID" >/dev/null 2>&1; then
    echo "--- Container-Status (pct status $CTID) ---" >&2
    pct status "$CTID" >&2 || true
    echo "--- systemd im Container (hi-events.service) ---" >&2
    pct exec "$CTID" -- systemctl --no-pager status hi-events.service 2>&1 | tail -n 30 >&2 || true
    echo "--- Docker-Container im LXC ---" >&2
    pct exec "$CTID" -- docker ps -a 2>&1 | tail -n 20 >&2 || true
    echo "--- docker compose logs (letzte 30 Zeilen) ---" >&2
    pct exec "$CTID" -- bash -c "cd ${APP_DIR} && docker compose logs --tail=30 --no-color 2>&1" 2>&1 | tail -n 30 >&2 || true
  fi
  echo "" >&2
  msg_error "Re-Run mit Debug-Log:  bash -x ./install/hi-events.sh ${*:-} 2>&1 | tee /tmp/hi-events-debug.log"
  exit "$exit_code"
}
trap 'error_trap' ERR

# ============================================================================
# HOST-CHECKS
# ============================================================================
check_host() {
  [[ "$(id -u)" -eq 0 ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausführen."; exit 1; }
  command -v pct >/dev/null && command -v pvesh >/dev/null \
    || { msg_error "pct/pvesh nicht gefunden – Skript muss auf dem Proxmox VE Host laufen."; exit 1; }
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/${APP}-install.log"
  log "== ${APP_FRIENDLY} Installation startet (MODE=${MODE}, script v${SCRIPT_VERSION}) =="
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid)       CTID="$2"; shift 2 ;;
      --hostname)   HOSTNAME_CT="$2"; shift 2 ;;
      --cpu)        VAR_CPU="$2"; shift 2 ;;
      --ram)        VAR_RAM="$2"; shift 2 ;;
      --disk)       VAR_DISK="$2"; shift 2 ;;
      --storage)    CONTAINER_STORAGE="$2"; shift 2 ;;
      --bridge)     BRIDGE="$2"; shift 2 ;;
      --ip)         NET_CONFIG="$2"; shift 2 ;;
      --vm)         MODE="vm"; shift ;;
      --reinstall)  REINSTALL="1"; shift ;;
      --skip-admin) SKIP_ADMIN_SETUP="1"; shift ;;
      --uninstall)  do_uninstall; exit 0 ;;
      -h|--help)    usage; exit 0 ;;
      *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
    esac
  done
  if [[ -z "$CTID" ]]; then
    CTID="$(pvesh get /cluster/nextid)"
    log "CTID automatisch gewählt: ${CTID}"
  fi
}

do_uninstall() {
  msg_info "Deinstalliere ${APP_FRIENDLY} (CT ${CTID:-?}) – Container wird gestoppt & gelöscht."
  if [[ -z "${CTID:-}" ]]; then msg_error "CTID fehlt: CTID=101 ./install/hi-events.sh --uninstall"; exit 1; fi
  pct stop "$CTID" 2>/dev/null || true
  pct destroy "$CTID" --purge 1 || pct destroy "$CTID"
  msg_ok "Container ${CTID} gelöscht. Volumes auf ${CONTAINER_STORAGE} ggf. prüfen."
}

# ============================================================================
# TEMPLATE / CONTAINER
# ============================================================================
ensure_template() {
  msg_info "Aktualisiere Template-Liste (${TEMPLATE_STORAGE})"
  pveam update 2>&1 | tee -a "$LOG_FILE" >/dev/null || true
  local tpl
  # HINWEIS: [^[:space:]] statt [^\s] – letzteres frisst buchstäblich jedes 's'
  # und verstümmelt den Dateinamen zu '...tar.z' statt '...tar.zst'.
  tpl=$(pveam available --section system 2>/dev/null | grep -o "${VAR_OS_TEMPLATE}[^[:space:]]*amd64[^[:space:]]*" | sort -V | tail -n1 || true)
  if [[ -z "$tpl" ]]; then
    msg_error "Kein Template für '${VAR_OS_TEMPLATE}' gefunden. Verfügbare Debian-Templates:"
    pveam available --section system 2>/dev/null | grep -i debian | tee -a "$LOG_FILE" || true
    exit 1
  fi
  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$tpl"; then
    msg_info "Lade Template ${tpl} (Geduld…)"
    pveam download "$TEMPLATE_STORAGE" "$tpl" 2>&1 | tee -a "$LOG_FILE"
  else
    msg_ok "Template vorhanden: ${tpl}"
  fi
  echo "${TEMPLATE_STORAGE}:vztmpl/${tpl}"
}

net_args() {
  if [[ "$NET_CONFIG" == "dhcp" ]]; then
    echo "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=dhcp"
  else
    # Format: "192.168.1.50/24,gw=192.168.1.1"
    local ip="${NET_CONFIG%%,*}" gw=""
    [[ "$NET_CONFIG" == *"gw="* ]] && gw="${NET_CONFIG##*gw=}"
    if [[ -n "$gw" ]]; then echo "name=eth0,bridge=${BRIDGE},ip=${ip},gw=${gw},ip6=dhcp"
    else echo "name=eth0,bridge=${BRIDGE},ip=${ip},ip6=dhcp"; fi
  fi
}

ct_ip() {
  pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true
}

# Wird von create_container() gesetzt: 1 = Container existierte bereits (Update-Pfad).
# HINWEIS: create_container() MUSS direkt (nicht in if/while/&&/||) aufgerufen werden,
# sonst sind set -e und ERR-Trap im Funktionskörper deaktiviert und Fehler laufen still durch.
CT_ALREADY_EXISTS=0

create_container() {
  local template="$1"
  if pct status "$CTID" >/dev/null 2>&1; then
    if [[ "$REINSTALL" == "1" ]]; then
      msg_info "REINSTALL=1 – lösche existierenden Container ${CTID}"
      pct stop "$CTID" 2>/dev/null || true
      sleep 3
      pct destroy "$CTID" --purge 1 2>&1 | tee -a "$LOG_FILE"
    else
      msg_info "Container ${CTID} existiert bereits → idempotentes Update (kein Neuaufbau)"
      CT_ALREADY_EXISTS=1
      return 0
    fi
  fi
  msg_info "Erstelle LXC-Container ${CTID} (${HOSTNAME_CT}: ${VAR_CPU} vCPU, ${VAR_RAM} MB RAM, ${VAR_DISK} GB Disk)"
  # pipefail ist aktiv: schlägt pct create fehl, bricht das Script hier per ERR-Trap
  # mit kompletter Diagnostik ab (Fail-Fast statt 90s Warteschleife ins Leere).
  pct create "$CTID" "$template" \
    --hostname "$HOSTNAME_CT" \
    --cores "$VAR_CPU" --memory "$VAR_RAM" --swap 512 \
    --rootfs "${CONTAINER_STORAGE}:${VAR_DISK}" \
    --net0 "$(net_args)" \
    --nameserver "$NAMESERVER" \
    --searchdomain local \
    --timezone "$TIMEZONE" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot "$ONBOOT" --start "$START_AFTER_CREATE" \
    --password "$(openssl rand -base64 12)" \
    2>&1 | tee -a "$LOG_FILE"
  # onboot explizit sicherstellen (reboot-sicher)
  pct set "$CTID" --onboot 1 2>&1 | tee -a "$LOG_FILE"
  # Fail-Fast: Config muss jetzt existieren, sonst sofort abbrechen statt Geister-Jagd.
  if ! pct config "$CTID" >/dev/null 2>&1; then
    msg_error "Container ${CTID} hat nach 'pct create' keine Config – Details:"
    pct config "$CTID" || true
    exit 1
  fi
  msg_ok "Container ${CTID} erstellt (onboot=1)"
}

wait_container() {
  # Fail-Fast: ohne Config keine 90s Warteschleife.
  if ! pct config "$CTID" >/dev/null 2>&1; then
    msg_error "Container ${CTID} existiert nicht (keine Config unter nodes/*/lxc/${CTID}.conf). Breche ab."
    pct config "$CTID" || true
    exit 1
  fi
  msg_info "Warte auf Container-IP (DHCP, max. 120s – manche Router/FritzBox brauchen lang)"
  local cip=""
  for _ in $(seq 1 60); do
    cip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
    [[ -n "$cip" ]] && break
    sleep 2
  done
  if [[ -z "$cip" && "$NET_CONFIG" == "dhcp" ]]; then
    msg_info "Keine IP – versuche einmalig DHCP-Renew (dhclient eth0)"
    pct exec "$CTID" -- dhclient -v eth0 2>&1 | tee -a "$LOG_FILE" || true
    sleep 5
    cip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  if [[ -z "$cip" ]]; then
    msg_error "Container ${CTID} bekommt keine IP (DHCP antwortet nicht?). Netzwerk-Dump:"
    pct exec "$CTID" -- ip addr 2>&1 || true
    pct exec "$CTID" -- ip route 2>&1 || true
    msg_error "Prüfen: Router-DHCP Pool frei / MAC-Filter? vmbr0-Uplink ok? PVE-Firewall?"
    msg_error "Workaround statische IP: pct destroy ${CTID} (nach stop), dann Re-Run mit --ip 192.168.1.50/24"
    exit 1
  fi
  log "Container-IP: ${cip}"
  msg_info "Warte auf Internet-Zugang (Ping oder TCP/53, max. 90s)"
  for i in $(seq 1 45); do
    if pct exec "$CTID" -- bash -c "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || timeout 5 bash -c '</dev/tcp/1.1.1.1/53'" 2>/dev/null; then
      msg_ok "Container-Netzwerk bereit (Versuch ${i}, IP ${cip})"
      return 0
    fi
    sleep 2
  done
  msg_error "Container hat IP (${cip}), aber kein Internet. Netzwerk-Dump:"
  pct exec "$CTID" -- ip addr 2>&1 || true
  pct exec "$CTID" -- ip route 2>&1 || true
  pct exec "$CTID" -- cat /etc/resolv.conf 2>&1 || true
  msg_error "Prüfen: Gateway/Routes, PVE-Firewall (FORWARD), Host-Test: ping -c1 1.1.1.1"
  msg_error "DNS-Test im CT: pct exec ${CTID} -- getent hosts github.com"
  exit 1
}

# ============================================================================
# IN-CONTAINER-SETUP (idempotent): Docker + Compose + systemd
# ============================================================================
install_in_container() {
  local container_ip="$1"
  msg_info "Installiere ${APP_FRIENDLY} im Container ${CTID} (idempotent)"

  # Paketliste + Compose-File + systemd-Unit werden per Heredoc übertragen.
  # ENV-Übergabe an den Container via pct exec env-Variablen (kein Eval-Risiko).
  pct exec "$CTID" -- env \
    "DEBIAN_FRONTEND=noninteractive" \
    "APP_DIR=${APP_DIR}" \
    "WEB_PORT=${WEB_PORT}" \
    "HI_EVENTS_IMAGE=${HI_EVENTS_IMAGE}" \
    "CONTAINER_IP=${container_ip}" \
    "TIMEZONE=${TIMEZONE}" \
    bash -s 2>&1 <<'IN_CT_EOF' | tee -a "$LOG_FILE"
# -E wichtig: sonst feuert der ERR-Trap in Funktionen/Subshells nicht (stiller Abbruch).
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "--- [CT] OS-Update ---"
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl git openssl gnupg lsb-release python3

if ! command -v docker >/dev/null 2>&1; then
  echo "--- [CT] Installiere Docker ---"
  curl -fsSL https://get.docker.com | sh
else
  echo "--- [CT] Docker bereits vorhanden: $(docker --version) ---"
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "--- [CT] Installiere docker-compose-plugin ---"
  apt-get install -y docker-compose-plugin
fi
systemctl enable --now docker
docker --version && docker compose version

mkdir -p "$APP_DIR"
cd "$APP_DIR"

# --- .env (idempotent: Secrets bleiben bei Update erhalten) ---
if [[ ! -f .env ]]; then
  echo "--- [CT] Erzeuge .env mit frischen Secrets ---"
  APP_KEY="base64:$(openssl rand -base64 32)"
  JWT_SECRET="$(openssl rand -base64 32)"
  PG_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 24)"
  cat > .env <<EOF2
# Hi.Events All-in-One – erzeugt vom Proxmox-Installer am $(date -u +%FT%TZ)
# Upstream: https://github.com/HiEventsDev/hi.events (docker/all-in-one)
APP_KEY=${APP_KEY}
JWT_SECRET=${JWT_SECRET}
VITE_FRONTEND_URL=http://${CONTAINER_IP}:${WEB_PORT}
VITE_API_URL_CLIENT=http://${CONTAINER_IP}:${WEB_PORT}/api
VITE_API_URL_SERVER=http://localhost:80/api
VITE_STRIPE_PUBLISHABLE_KEY=pk_test_123456789
VITE_APP_NAME=Hi.Events
LOG_CHANNEL=stderr
QUEUE_CONNECTION=redis
# --- Login-Fix für HTTP/IP-Zugriff (Upstream-Issue #472: Login-200, danach 401) ---
# APP_URL speist u. a. Sanctums stateful-Domains; SANCTUM_STATEFUL_DOMAINS explizit
# dazu (Browser-Referer IP:Port muss als stateful gelten, sonst 401 auf /users/me).
# SESSION_SECURE_COOKIE=false: sonst verwirft der Browser Cookies über http.
# SESSION_DOMAIN bewusst NICHT gesetzt (null = Host-only-Cookie; eine IP als
# Cookie-Domain lehnen moderne Browser ab → Session geht verloren).
APP_URL=http://${CONTAINER_IP}:${WEB_PORT}
SANCTUM_STATEFUL_DOMAINS=${CONTAINER_IP}:${WEB_PORT}
SESSION_SECURE_COOKIE=false
APP_CDN_URL=http://${CONTAINER_IP}:${WEB_PORT}/storage
APP_FRONTEND_URL=http://${CONTAINER_IP}:${WEB_PORT}
APP_DISABLE_REGISTRATION=false
APP_SAAS_MODE_ENABLED=false
APP_SAAS_STRIPE_APPLICATION_FEE_PERCENT=0
APP_SAAS_STRIPE_APPLICATION_FEE_FIXED=0
APP_EMAIL_LOGO_URL=
APP_EMAIL_LOGO_LINK_URL=
MAIL_MAILER=log
MAIL_DRIVER=log
MAIL_HOST=mail.local
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_AUTO_TLS=true
MAIL_VERIFY_PEER=true
MAIL_FROM_ADDRESS=test@example.com
MAIL_FROM_NAME="Hi Events"
FILESYSTEM_PUBLIC_DISK=public
FILESYSTEM_PRIVATE_DISK=local
POSTGRES_DB=hi-events
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${PG_PASS}
REDIS_HOST=redis
REDIS_PASSWORD=
REDIS_PORT=6379
STRIPE_PUBLIC_KEY=pk_test_123456789
STRIPE_SECRET_KEY=sk_test_123456789
STRIPE_WEBHOOK_SECRET=whsec_test_123456789
GEO_PROVIDER=google
GOOGLE_MAPS_API_KEY=
API_DOCS_ENABLED=false
EOF2
  chmod 600 .env
  echo "[CT] .env erzeugt (APP_KEY/JWT_SECRET/POSTGRES_PASSWORD zufällig)."
else
  echo "--- [CT] .env existiert bereits → Secrets bleiben erhalten (idempotent) ---"
  # Frontend-/Backend-URLs bei IP-Wechsel nachziehen, Secrets NICHT anfassen:
  upsert_env() { # $1=KEY $2=VALUE – ersetzen oder anhängen (nur für URL-/Flag-Werte!)
    if grep -qE "^${1}=" .env; then sed -i -E "s|^${1}=.*|${1}=${2}|" .env
    else printf '%s=%s\n' "${1}" "${2}" >> .env; fi
  }
  upsert_env VITE_FRONTEND_URL "http://${CONTAINER_IP}:${WEB_PORT}"
  upsert_env VITE_API_URL_CLIENT "http://${CONTAINER_IP}:${WEB_PORT}/api"
  upsert_env APP_CDN_URL "http://${CONTAINER_IP}:${WEB_PORT}/storage"
  upsert_env APP_FRONTEND_URL "http://${CONTAINER_IP}:${WEB_PORT}"
  upsert_env APP_URL "http://${CONTAINER_IP}:${WEB_PORT}"
  upsert_env SANCTUM_STATEFUL_DOMAINS "${CONTAINER_IP}:${WEB_PORT}"
  upsert_env SESSION_SECURE_COOKIE "false"
  # SESSION_DOMAIN ggf. aus Alt-Installationen entfernen (IP als Domain killt Cookies):
  sed -i -E "/^SESSION_DOMAIN=/d" .env
fi

# --- docker-compose.yml (immer auf gewünschtes Image pinnen, Volumes bleiben) ---
echo "--- [CT] Schreibe docker-compose.yml (Image: ${HI_EVENTS_IMAGE}) ---"
cat > docker-compose.yml <<EOF2
# Hi.Events All-in-One – verwaltet vom Proxmox-Installer (idempotent, Volumes bleiben).
# Quelle/Referenz: https://github.com/HiEventsDev/hi.events (docker/all-in-one/docker-compose.yml)
services:
  all-in-one:
    image: ${HI_EVENTS_IMAGE}
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:80"
    env_file: .env
    environment:
      - DATABASE_URL=postgresql://\${POSTGRES_USER:-postgres}:\${POSTGRES_PASSWORD:-secret}@postgres:5432/\${POSTGRES_DB:-hi-events}
      - APP_URL=\${APP_URL}
      - SANCTUM_STATEFUL_DOMAINS=\${SANCTUM_STATEFUL_DOMAINS}
      - SESSION_SECURE_COOKIE=\${SESSION_SECURE_COOKIE:-false}
      - REDIS_HOST=redis
      - REDIS_PASSWORD=
      - REDIS_PORT=6379
      - WEBHOOK_QUEUE_NAME=webhook-queue
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - redisdata:/data
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \$\${POSTGRES_USER:-postgres} -d \$\${POSTGRES_DB:-hi-events}"]
      interval: 10s
      timeout: 5s
      retries: 5
    environment:
      POSTGRES_DB: \${POSTGRES_DB:-hi-events}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-secret}
    volumes:
      - pgdata:/var/lib/postgresql/data
volumes:
  pgdata:
  redisdata:
EOF2

# --- systemd-Unit (reboot-sicher, Restart=always) ---
echo "--- [CT] Installiere systemd-Unit hi-events.service ---"
cat > /etc/systemd/system/hi-events.service <<EOF2
[Unit]
Description=Hi.Events All-in-One (Docker Compose)
Documentation=https://github.com/HiEventsDev/hi.events
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF2
systemctl daemon-reload
systemctl enable hi-events.service
# Firewall-Port im LXC öffnen (falls iptables/ufw aktiv)
if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -p tcp --dport ${WEB_PORT} -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport ${WEB_PORT} -j ACCEPT || true
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow ${WEB_PORT}/tcp || true
fi
echo "--- [CT] Starte hi-events.service ---"
systemctl restart hi-events.service || (journalctl -u hi-events.service --no-pager -n 50; exit 1)
IN_CT_EOF

  msg_ok "In-Container-Setup abgeschlossen"
}

# ============================================================================
# VM-MODUS (Alternative für leistungshungrige Setups / ohne LXC-Nesting)
# ============================================================================
install_vm_mode() {
  msg_info "VM-Modus: erstelle QEMU-VM ${CTID} (${VM_CPU} vCPU, ${VM_RAM} MB RAM, ${VM_DISK})"
  command -v qm >/dev/null || { msg_error "qm nicht gefunden."; exit 1; }
  if qm status "$CTID" >/dev/null 2>&1 && [[ "$REINSTALL" != "1" ]]; then
    msg_info "VM ${CTID} existiert bereits → Update im Gast per qm guest exec / SSH (idempotent)"
  else
    local img="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
    if [[ ! -f "$img" ]]; then
      msg_info "Lade Debian-12-Cloud-Image"
      mkdir -p "$(dirname "$img")"
      wget -O "$img" "$VM_IMAGE_URL" 2>&1 | tee -a "$LOG_FILE"
    fi
    qm create "$CTID" --name "$HOSTNAME_CT" --cores "$VM_CPU" --sockets 1 \
      --memory "$VM_RAM" --net0 "virtio,bridge=${VM_BRIDGE}" \
      --scsihw virtio-scsi-pci --scsi0 "${VM_STORAGE}:0,import-from=${img},format=qcow2" \
      --ide2 "${VM_STORAGE}:cloudinit" --boot order=scsi0 --serial0 socket --vga serial0 \
      --ipconfig0 "ip=dhcp" --ciuser admin --cipassword "$(openssl rand -base64 12)" \
      --onboot 1 --agent 1 2>&1 | tee -a "$LOG_FILE"
    qm resize "$CTID" scsi0 "$VM_DISK" 2>&1 | tee -a "$LOG_FILE" || true
    qm start "$CTID" 2>&1 | tee -a "$LOG_FILE"
    msg_ok "VM ${CTID} erstellt & gestartet – fahre mit Docker-Setup per SSH/qm fort (Cloud-Init abwarten, dann identisches Compose-Setup wie LXC)."
  fi
  msg_error "VM-Modus: bitte nach Cloud-Init per 'qm guest exec ${CTID} -- ...' bzw. SSH das Compose-Setup aus install_in_container() übernehmen (identische .env/compose/systemd-Dateien). LXC bleibt der Standardweg."
  exit 2
}

# ============================================================================
# ADMIN-ZUGANG (Upstream liefert KEIN Default-Login – Installer legt Admin an)
# Ablauf: Zugangsdaten abfragen → per API registrieren (valide Timezone, kein
# 422-Bug) → E-Mail vorab verifizieren (MAIL_MAILER=log!) → SUPERADMIN-Rolle
# via artisan (SQL-Fallback) → Login-Beweis: POST /auth/login 200 + /users/me 200.
# Das Passwort steht NUR auf dem Terminal, nie in Logdateien.
# ============================================================================
ADMIN_EMAIL_FINAL=""; ADMIN_PASSWORD_FINAL=""; ADMIN_ACCOUNT_ID=""; ADMIN_USER_ID=""

prompt_admin_credentials() {
  if [[ "$SKIP_ADMIN_SETUP" == "1" ]]; then
    log "SKIP_ADMIN_SETUP=1 – es wird kein Admin angelegt."
    return 1
  fi
  if [[ -z "${ADMIN_EMAIL:-}" ]]; then
    if [[ -t 0 ]]; then
      local _em=""
      read -r -p "Admin-E-Mail [${ADMIN_DEFAULT_EMAIL}]: " _em < /dev/tty || true
      ADMIN_EMAIL_FINAL="${_em:-$ADMIN_DEFAULT_EMAIL}"
    else
      ADMIN_EMAIL_FINAL="$ADMIN_DEFAULT_EMAIL"
      log "Kein TTY → Admin-Default-E-Mail: ${ADMIN_EMAIL_FINAL}"
    fi
  else
    ADMIN_EMAIL_FINAL="$ADMIN_EMAIL"
  fi
  [[ "$ADMIN_EMAIL_FINAL" == *"@"* && "$ADMIN_EMAIL_FINAL" == *"."* ]] \
    || { msg_error "Ungültige Admin-E-Mail: '${ADMIN_EMAIL_FINAL}'"; exit 1; }
  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    if [[ -t 0 ]]; then
      local _pw=""
      while true; do
        # Standard-Login: einfach Enter drücken (später in der UI änderbar).
        read -r -s -p "Admin-Passwort [Enter = Standard: ${ADMIN_DEFAULT_PASSWORD}]: " _pw < /dev/tty || true
        echo >&2
        [[ -z "$_pw" ]] && _pw="$ADMIN_DEFAULT_PASSWORD"
        if [[ "${#_pw}" -ge 8 ]]; then ADMIN_PASSWORD_FINAL="$_pw"; break; fi
        msg_error "Zu kurz (Hi.Events-Policy: min. 8 Zeichen). Nochmal."
      done
    else
      ADMIN_PASSWORD_FINAL="$ADMIN_DEFAULT_PASSWORD"
      log "Kein TTY → Standard-Passwort (bitte nach Login in der UI ändern)."
    fi
  else
    [[ "${#ADMIN_PASSWORD}" -ge 8 ]] || { msg_error "ADMIN_PASSWORD zu kurz (min. 8 Zeichen)."; exit 1; }
    ADMIN_PASSWORD_FINAL="$ADMIN_PASSWORD"
  fi
  log "Admin-Account: ${ADMIN_EMAIL_FINAL} (Name: ${ADMIN_FIRSTNAME:-Admin} ${ADMIN_LASTNAME:-User})"
  return 0
}

setup_admin() {
  local ip="$1"
  prompt_admin_credentials || return 0   # SKIP → kein Admin, kein Fehler
  msg_info "Lege Admin-Account an (${ADMIN_EMAIL_FINAL}) + Login-Beweis via API"

  local result_line
  # Fortschritt läuft über stderr+Log+Terminal (Passwort nirgends).
  # Ergebnis via DATEI lesen (robust gegen Pipe-Abbrüche) + Exit via prov_rc.
  # Vorher alte Ergebnisdatei löschen (kein False-Positive vom Vorlauf).
  pct exec "$CTID" -- rm -f "${APP_DIR}/.admin-result" 2>/dev/null || true
  local prov_rc=0
  pct exec "$CTID" -- env \
    "APP_DIR=${APP_DIR}" \
    "WEB_PORT=${WEB_PORT}" \
    "API_BASE=http://localhost:${WEB_PORT}/api" \
    "ADMIN_EMAIL=${ADMIN_EMAIL_FINAL}" \
    "ADMIN_PASSWORD=${ADMIN_PASSWORD_FINAL}" \
    "ADMIN_FIRSTNAME=${ADMIN_FIRSTNAME:-Admin}" \
    "ADMIN_LASTNAME=${ADMIN_LASTNAME:-User}" \
    "TIMEZONE=${TIMEZONE}" \
    bash -s 2>&1 <<'PROV_EOF' | tee -a "$LOG_FILE" || prov_rc=$?
set -Eeuo pipefail
# ERR-Falle IM Container: meldet jede stille set -e-Beendigung mit Zeilennummer.
# (Ohne das rät man bei Abbrüchen ohne [ADMIN] FEHLER-Zeile im Dunkeln.)
trap 'echo "[ADMIN] ABBRUCH in Payload-Zeile ${LINENO} (Befehl: ${BASH_COMMAND})" >&2' ERR
cd "$APP_DIR"
log_ct() { echo "--- [ADMIN] $*" >&2; }
fail_ct() { echo "[ADMIN] FEHLER: $*" >&2; exit 1; }

AIO_CID="$(docker compose ps -q all-in-one </dev/null 2>/dev/null)" || fail_ct "all-in-one Container nicht gefunden"
[[ -n "$AIO_CID" ]] || fail_ct "all-in-one Container läuft nicht (docker compose ps -q leer)"
log_ct "Compose-Projektstatus:"; docker compose ps </dev/null >&2 || true
# shellcheck disable=SC1091
set -a; . ./.env; set +a
PSQL=(docker compose exec -T -e "PGPASSWORD=${POSTGRES_PASSWORD}" postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-hi-events}" -tAc)
SQL_EMAIL="${ADMIN_EMAIL//\'/\'\'}"

# --- 1) Registrieren (201) oder existierenden User übernehmen (422 = E-Mail belegt) ---
REQ="$(mktemp)"; RESP="$(mktemp)"
python3 - > "$REQ" <<'PYEOF'
import json, os
print(json.dumps({
    "first_name": os.environ.get("ADMIN_FIRSTNAME", "Admin"),
    "last_name": os.environ.get("ADMIN_LASTNAME", "User"),
    "email": os.environ["ADMIN_EMAIL"],
    "password": os.environ["ADMIN_PASSWORD"],
    "password_confirmation": os.environ["ADMIN_PASSWORD"],
    "timezone": os.environ.get("TIMEZONE", "Europe/Berlin"),
}))
PYEOF
REG_HTTP=$(curl -s -o "$RESP" -w "%{http_code}" --max-time 30 \
  -H 'Content-Type: application/json' -d @"$REQ" "${API_BASE}/auth/register" || echo "000")
log_ct "POST /auth/register → HTTP ${REG_HTTP}"
# IDs grundsätzlich aus der DB lesen (robust gegen Antwort-Formatänderungen):
lookup_ids() {
  USER_ID="$("${PSQL[@]}" "SELECT id FROM users WHERE email='${SQL_EMAIL}' LIMIT 1" </dev/null 2>/dev/null | tr -d '[:space:]')" || true
  if [[ -n "$USER_ID" ]]; then
    ACCOUNT_ID="$("${PSQL[@]}" "SELECT account_id FROM account_users WHERE user_id=${USER_ID} ORDER BY id LIMIT 1" </dev/null 2>/dev/null | tr -d '[:space:]')" || true
  else
    ACCOUNT_ID=""
  fi
}
if [[ "${REG_HTTP}" == "201" ]]; then
  lookup_ids
  [[ -n "${USER_ID:-}" && -n "${ACCOUNT_ID:-}" ]] \
    || fail_ct "Registrierung meldet 201, aber User/Account fehlen in DB. Antwort: $(head -c 500 "$RESP")"
  log_ct "Registrierung ok (User ${USER_ID}, Account ${ACCOUNT_ID})"
elif [[ "${REG_HTTP}" == "422" ]] && grep -qiE 'email|taken|exists' "$RESP"; then
  log_ct "E-Mail bereits registriert → übernehme existierenden User (Passwort wird gesetzt)"
  USER_ID="$("${PSQL[@]}" "SELECT id FROM users WHERE email='${SQL_EMAIL}' LIMIT 1" </dev/null 2>/dev/null | tr -d '[:space:]')" || true
  [[ -n "$USER_ID" ]] || fail_ct "User ${ADMIN_EMAIL} in DB nicht gefunden (psql-Login prüfen)"
  ACCOUNT_ID="$("${PSQL[@]}" "SELECT account_id FROM account_users WHERE user_id=${USER_ID} ORDER BY id LIMIT 1" </dev/null 2>/dev/null | tr -d '[:space:]')" || true
  [[ -n "$ACCOUNT_ID" ]] || fail_ct "Kein Account für User ${USER_ID} gefunden"
  BCRYPT="$(docker exec -e ADMIN_PW="$ADMIN_PASSWORD" "$AIO_CID" php -r 'echo password_hash(getenv("ADMIN_PW"), PASSWORD_BCRYPT), PHP_EOL;' </dev/null)"
  [[ -n "$BCRYPT" ]] || fail_ct "bcrypt-Hash konnte nicht erzeugt werden"
  "${PSQL[@]}" "UPDATE users SET password='${BCRYPT}', updated_at=NOW() WHERE id=${USER_ID}" </dev/null
  log_ct "Passwort für User ${USER_ID} gesetzt"
else
  fail_ct "Registrierung fehlgeschlagen (HTTP ${REG_HTTP}). Antwort: $(cat "$RESP")"
fi
[[ -n "${USER_ID:-}" && -n "${ACCOUNT_ID:-}" ]] || fail_ct "User-/Account-ID leer"
log_ct "User-ID ${USER_ID}, Account-ID ${ACCOUNT_ID}"
export ACCOUNT_ID   # MUSS vor dem Login-Python exportiert sein (os.environ)!

# --- 2) E-Mail vorab verifizieren (MAIL_MAILER=log → Link käme nie an!) ---
if [[ "$("${PSQL[@]}" "SELECT 1 FROM information_schema.columns WHERE table_name='users' AND column_name='email_verified_at'" </dev/null)" == "1" ]]; then
  "${PSQL[@]}" "UPDATE users SET email_verified_at=NOW() WHERE email='${SQL_EMAIL}' AND email_verified_at IS NULL" </dev/null
  log_ct "E-Mail als verifiziert markiert"
else
  log_ct "WARNUNG: Spalte users.email_verified_at fehlt – Verifizierung übersprungen"
fi

# --- 3) SUPERADMIN-Rolle (artisan, SQL-Fallback) ---
if printf 'yes\nyes\n' | docker exec -i "$AIO_CID" php /app/backend/artisan user:make-superadmin "$USER_ID" >&2; then
  log_ct "SUPERADMIN via artisan vergeben"
else
  log_ct "artisan-Befehl fehlgeschlagen → SQL-Fallback"
  "${PSQL[@]}" "UPDATE account_users SET role='SUPERADMIN' WHERE user_id=${USER_ID}" </dev/null
fi
ROLE="$("${PSQL[@]}" "SELECT role FROM account_users WHERE user_id=${USER_ID} ORDER BY id LIMIT 1" </dev/null | tr -d '[:space:]')"
[[ "$ROLE" == "SUPERADMIN" ]] || fail_ct "Rolle ist '${ROLE}', erwartet SUPERADMIN"
log_ct "Rolle bestätigt: ${ROLE}"

# --- 4) Login-Beweis: POST /auth/login 200 + GET /users/me 200 ---
LREQ="$(mktemp)"; LRESP="$(mktemp)"
python3 - > "$LREQ" <<'PYEOF'
import json, os
print(json.dumps({"email": os.environ["ADMIN_EMAIL"],
  "password": os.environ["ADMIN_PASSWORD"], "account_id": int(os.environ["ACCOUNT_ID"])}))
PYEOF
LOGIN_HTTP=$(curl -s -o "$LRESP" -w "%{http_code}" --max-time 30 \
  -H 'Content-Type: application/json' -d @"$LREQ" "${API_BASE}/auth/login" || echo "000")
TOKEN="$(python3 - "$LRESP" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
def deep(o):
    if isinstance(o, dict):
        for k in ("token", "access_token", "accessToken"):
            if o.get(k):
                return o[k]
        for v in o.values():
            r = deep(v)
            if r:
                return r
    if isinstance(o, list):
        for v in o:
            r = deep(v)
            if r:
                return r
    return ""
print(deep(d))
PYEOF
)"
if [[ "${LOGIN_HTTP}" != "200" || -z "$TOKEN" ]]; then
  KEYS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(list(d.keys()) if isinstance(d,dict) else type(d).__name__)' "$LRESP" 2>/dev/null || echo '?')"
  fail_ct "Login-Beweis fehlgeschlagen (HTTP ${LOGIN_HTTP}). Top-Level-Keys: ${KEYS}. Anfang der Antwort: $(head -c 300 "$LRESP")"
fi
ME_HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
  -H "Authorization: Bearer ${TOKEN}" "${API_BASE}/users/me" || echo "000")
[[ "${ME_HTTP}" == "200" ]] \
  || fail_ct "GET /users/me → HTTP ${ME_HTTP} (erwartet 200, Upstream-Issue #472)"
log_ct "Login-Beweis ok: /auth/login 200 + /users/me 200"

# Ergebnis doppelt sichern: stdout (Log) + Datei (robust gegen Pipe-Abbrüche).
echo "ADMIN_RESULT ok account_id=${ACCOUNT_ID} user_id=${USER_ID}" | tee "${APP_DIR}/.admin-result"
PROV_EOF
  log "Provision-Exit (pct-Seite): ${prov_rc}"
  result_line=$(pct exec "$CTID" -- cat "${APP_DIR}/.admin-result" 2>/dev/null || true)
  if [[ "$prov_rc" -ne 0 || "$result_line" != ADMIN_RESULT\ ok* ]]; then
    msg_error "Admin-Provisionierung fehlgeschlagen (pct-Exit ${prov_rc}, Ergebnis: '${result_line:-<leer>}')."
    echo -e "${YW}--- Letzte [ADMIN]-Schritte aus ${LOG_FILE} ---${CL}" >&2
    grep -a "ADMIN" "$LOG_FILE" 2>/dev/null | tail -n 25 >&2 || true
    echo -e "${YW}--- Log-Schwanz (letzte 15 Zeilen, ungefiltert – hier steht auch Verstecktes) ---${CL}" >&2
    tail -n 15 "$LOG_FILE" 2>/dev/null >&2 || true
    echo -e "${YW}--- OOM-Killer? (Host-dmesg) ---${CL}" >&2
    dmesg 2>/dev/null | grep -aiE 'oom|killed process' | tail -n 5 >&2 || true
    echo -e "${YW}--- Compose-Projektstatus ---${CL}" >&2
    pct exec "$CTID" -- bash -c "cd ${APP_DIR} && docker compose ps" 2>&1 | tee -a "$LOG_FILE" >&2 || true
    echo -e "${YW}--- Compose-Logs (gefiltert, letzte 25) ---${CL}" >&2
    pct exec "$CTID" -- bash -c "cd ${APP_DIR} && docker compose logs --tail=60 --no-color 2>/dev/null | grep -av 'box-sizing\|style=' | tail -n 25" 2>&1 | tee -a "$LOG_FILE" >&2 || true
    msg_error "Vollständig: ${LOG_FILE} – Re-Run idempotent möglich."
    exit 1
  fi
  ADMIN_ACCOUNT_ID="$(echo "$result_line" | grep -oE 'account_id=[0-9]+' | cut -d= -f2)"
  ADMIN_USER_ID="$(echo "$result_line" | grep -oE 'user_id=[0-9]+' | cut -d= -f2)"
  msg_ok "Admin bereit: ${ADMIN_EMAIL_FINAL} (User ${ADMIN_USER_ID}, Account ${ADMIN_ACCOUNT_ID}, Rolle SUPERADMIN)"
}

# ============================================================================
# VERIFIKATION
# ============================================================================
verify_install() {
  local ip="$1"
  msg_info "Verifiziere Installation (Service + Web UI + onboot)"

  local svc
  svc=$(pct exec "$CTID" -- systemctl is-active hi-events.service 2>&1 || true)
  log "systemctl is-active hi-events.service → ${svc}"
  [[ "$svc" == "active" ]] || {
    msg_error "hi-events.service ist nicht active (Status: ${svc}). Journal:"
    pct exec "$CTID" -- journalctl -u hi-events.service --no-pager -n 50 || true
    exit 1
  }
  msg_ok "Service läuft (systemctl is-active: active)"

  msg_info "HTTP-Check auf localhost:${WEB_PORT} im Container (max. ${HEALTH_WAIT_SECS}s)"
  local code=""
  for _ in $(seq 1 $((HEALTH_WAIT_SECS / 5))); do
    code=$(pct exec "$CTID" -- curl -s -o /dev/null -w "%{http_code}" --max-time "$CURL_TIMEOUT" "http://localhost:${WEB_PORT}/" 2>/dev/null || echo "000")
    [[ "$code" == "200" || "$code" == "302" || "$code" == "301" ]] && break
    sleep 5
  done
  log "HTTP localhost:${WEB_PORT}/ → ${code}"
  case "$code" in
    200|301|302) msg_ok "Web UI antwortet (HTTP ${code})" ;;
    *) msg_error "Web UI antwortet nicht (HTTP ${code}). Compose-Logs:"
       pct exec "$CTID" -- bash -c "cd ${APP_DIR} && docker compose logs --tail=50 --no-color" || true
       exit 1 ;;
  esac

  local onboot
  onboot=$(pct config "$CTID" | grep -i onboot || echo "onboot: ?")
  log "CT-Config onboot → ${onboot}"
  msg_ok "Reboot-Sicherheit: ${onboot} + systemd enable hi-events.service"
}

print_summary() {
  local ip="$1"
  echo ""
  echo -e "${GN} ✓ ${APP_FRIENDLY} erfolgreich installiert!${CL}"
  echo -e "  Web UI      : ${BGN}http://${ip}:${WEB_PORT}${CL}"
  echo -e "  Container-IP: ${ip}   (CT ${CTID}, hostname ${HOSTNAME_CT})"
  if [[ -n "${ADMIN_EMAIL_FINAL:-}" ]]; then
    echo -e "  Login (Admin): ${BGN}http://${ip}:${WEB_PORT}/auth/login${CL}"
    echo -e "  E-Mail      : ${ADMIN_EMAIL_FINAL}"
    echo -e "  Passwort    : ${ADMIN_PASSWORD_FINAL:-<per ENV gesetzt, siehe ADMIN_PASSWORD>}"
    echo -e "    (Passwort steht NUR hier, nie im Log. Ändern: im Profil oder per Re-Run mit ADMIN_PASSWORD.)"
  else
    echo -e "  Login       : http://${ip}:${WEB_PORT}/auth/register (erst Account anlegen – Upstream hat kein Default-Login)"
  fi
  echo -e "  Events einrichten (Organizer-Dashboard): ${BGN}http://${ip}:${WEB_PORT}/manage/events${CL}"
  echo -e "  Weitere User: http://${ip}:${WEB_PORT}/auth/register"
  echo -e "    Hinweis: Bestätigungs-Mails landen im Compose-Log (MAIL_MAILER=log):"
  echo -e "    pct exec ${CTID} -- bash -c 'cd ${APP_DIR} && docker compose logs -f all-in-one | grep -i verif'"
  echo -e "    Für echte Mails SMTP in ${APP_DIR}/.env setzen (dann: docker compose up -d)."
  echo -e "  Service     : systemctl status hi-events.service  (im Container: pct enter ${CTID})"
  echo -e "  Verzeichnis : ${APP_DIR}  (docker-compose.yml + .env)"
  echo -e "  Update      : pct exec ${CTID} -- bash -c 'cd ${APP_DIR} && docker compose pull && docker compose up -d'"
  echo -e "  Deinstall   : CTID=${CTID} bash ./install/hi-events.sh --uninstall"
  echo -e "  Reboot-Test : pct reboot ${CTID} && sleep 45 && curl -fsS http://${ip}:${WEB_PORT}/ >/dev/null && echo OK"
}

# Letzte Ausgabe: unübersehbarer Zugangsdaten-Block + Creds-Datei (nur root lesbar,
# Community-Scripts-Stil, vgl. paperless-ngx.creds). Passwort steht hier und in der
# Datei – bewusst NICHT im Install-Log.
print_credentials_box() {
  local ip="$1"
  [[ -n "${ADMIN_EMAIL_FINAL:-}" && -n "${ADMIN_PASSWORD_FINAL:-}" ]] || return 0
  local login_url="http://${ip}:${WEB_PORT}/auth/login"
  local dashboard_url="http://${ip}:${WEB_PORT}/manage/events"
  local creds_file="${HOME:-/root}/hi-events-ct${CTID}.creds"
  if {
    echo "Hi.Events Admin-Zugang (CT ${CTID}, Container-IP ${ip}, $(date '+%F %T'))"
    echo "Login:     ${login_url}"
    echo "E-Mail:    ${ADMIN_EMAIL_FINAL}"
    echo "Passwort:  ${ADMIN_PASSWORD_FINAL}"
    echo "Dashboard (Events einrichten): ${dashboard_url}"
  } > "$creds_file" 2>/dev/null && chmod 600 "$creds_file" 2>/dev/null; then
    log "Zugangsdaten gespeichert in ${creds_file} (Modus 600)"
  else
    creds_file="(Konnte nicht geschrieben werden – bitte Zugangsdaten unten notieren!)"
  fi
  echo ""
  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "${GN}  Hi.Events ZUGANGSDATEN – bitte notieren!${CL}"
  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "  Login:     ${BGN}${login_url}${CL}"
  echo -e "  E-Mail:    ${BGN}${ADMIN_EMAIL_FINAL}${CL}"
  echo -e "  Passwort:  ${BGN}${ADMIN_PASSWORD_FINAL}${CL}"
  echo -e "  Events einrichten: ${BGN}${dashboard_url}${CL}"
  echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "  Gespeichert in: ${creds_file} (nur für root lesbar)"
  echo ""
}

# ============================================================================
# MAIN
# ============================================================================
main() {
  for a in "$@"; do
    if [[ "$a" == "-h" || "$a" == "--help" ]]; then usage; exit 0; fi
  done
  check_host
  parse_args "$@"
  if [[ "$MODE" == "vm" ]]; then install_vm_mode; fi
  local template
  template=$(ensure_template)
  # Sanity-Check: stdout von ensure_template() muss EXAKT ein Template-Pfad sein
  # (schützt vor stdout-Verschmutzung: 'can't find file'-Fehler wie in v1.0.0).
  if [[ "$template" != *":vztmpl/"*".tar"* ]]; then
    msg_error "Ungültiger Template-Pfad von ensure_template(): '${template}'"
    msg_error "Erwartet: '<storage>:vztmpl/<name>.tar.zst' in EINER Zeile."
    exit 1
  fi
  log "Template: ${template}"
  # DIREKTER Aufruf (kein if/||-Kontext) – nur so greifen set -e + ERR-Trap (Fail-Fast).
  create_container "$template"
  if [[ "$CT_ALREADY_EXISTS" == "1" ]]; then log "Bestands-Container → Update-Pfad"; else log "Container neu erstellt"; fi
  # Nur starten, wenn nicht bereits laufend ('pct start' auf laufendem CT schlägt fehl).
  if pct status "$CTID" 2>/dev/null | grep -q "running"; then
    msg_ok "Container ${CTID} läuft bereits"
  else
    msg_info "Starte Container ${CTID}"
    pct start "$CTID" 2>&1 | tee -a "$LOG_FILE"
  fi
  wait_container
  sleep 5
  local ip
  for _ in $(seq 1 12); do
    ip=$(ct_ip); [[ -n "$ip" ]] && break; sleep 5
  done
  [[ -n "${ip:-}" ]] || { msg_error "Keine Container-IP ermittelbar (pct exec hostname -I leer)."; pct config "$CTID"; exit 1; }
  log "Container-IP: ${ip}"
  install_in_container "$ip"
  verify_install "$ip"
  setup_admin "$ip"
  print_summary "$ip"
  print_credentials_box "$ip"
  log "== Installation erfolgreich: http://${ip}:${WEB_PORT} =="
}

main "$@"
