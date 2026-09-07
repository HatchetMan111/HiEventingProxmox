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
SCRIPT_VERSION="${SCRIPT_VERSION:-1.0.1}"
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
                                  [--vm] [--reinstall] [--uninstall] [-h]

ENV-Overrides: CTID HOSTNAME_CT VAR_CPU VAR_RAM VAR_DISK CONTAINER_STORAGE TEMPLATE_STORAGE
               BRIDGE NET_CONFIG HI_EVENTS_IMAGE POSTGRES_PASSWORD MODE=vm REINSTALL=1
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
  msg_info "Warte auf Container-Netzwerk (max. 90s)"
  for i in $(seq 1 45); do
    if pct exec "$CTID" -- bash -c "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1"; then
      msg_ok "Container-Netzwerk bereit (Versuch ${i})"
      return 0
    fi
    sleep 2
  done
  msg_error "Container hat kein Netzwerk (DNS/Ping zu 1.1.1.1 schlägt fehl). pct config:"
  pct config "$CTID" || true
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
apt-get install -y ca-certificates curl git openssl gnupg lsb-release

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
  # Frontend-URL bei IP-Wechsel nachziehen, Secrets NICHT anfassen:
  sed -i -E "s|^VITE_FRONTEND_URL=.*|VITE_FRONTEND_URL=http://${CONTAINER_IP}:${WEB_PORT}|" .env
  sed -i -E "s|^VITE_API_URL_CLIENT=.*|VITE_API_URL_CLIENT=http://${CONTAINER_IP}:${WEB_PORT}/api|" .env
  sed -i -E "s|^APP_CDN_URL=.*|APP_CDN_URL=http://${CONTAINER_IP}:${WEB_PORT}/storage|" .env
  sed -i -E "s|^APP_FRONTEND_URL=.*|APP_FRONTEND_URL=http://${CONTAINER_IP}:${WEB_PORT}|" .env
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

  echo ""
  echo -e "${GN} ✓ ${APP_FRIENDLY} erfolgreich installiert!${CL}"
  echo -e "  Web UI      : ${BGN}http://${ip}:${WEB_PORT}${CL}"
  echo -e "  Container-IP: ${ip}   (CT ${CTID}, hostname ${HOSTNAME_CT})"
  echo -e "  Service     : systemctl status hi-events.service  (im Container: pct enter ${CTID})"
  echo -e "  Verzeichnis : ${APP_DIR}  (docker-compose.yml + .env)"
  echo -e "  Update      : pct exec ${CTID} -- bash -c 'cd ${APP_DIR} && docker compose pull && docker compose up -d'"
  echo -e "  Deinstall   : CTID=${CTID} bash ./install/hi-events.sh --uninstall"
  echo -e "  Reboot-Test : pct reboot ${CTID} && sleep 45 && curl -fsS http://${ip}:${WEB_PORT}/ >/dev/null && echo OK"
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
  log "== Installation erfolgreich: http://${ip}:${WEB_PORT} =="
}

main "$@"
