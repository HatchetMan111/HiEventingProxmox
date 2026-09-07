# Hi.Events – Proxmox LXC Einzeiler (Community-Scripts-Stil)

> **Installation auf dem Proxmox-Host als root:**
> ```bash
> bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"
> ```
> Install-Script: [`install/hi-events.sh`](install/hi-events.sh) · systemd-Unit: [`systemd/hi-events.service`](systemd/hi-events.service)

**Hi.Events** – Open-Source Event-Management & Ticketing-Plattform
(Eventbrite-/Tickettailor-Alternative für Konzerte, Konferenzen, Workshops).
Läuft **vollständig lokal**, keine Cloud nötig.

- **Tech-Stack:** PHP 8.3 / Laravel · React 19 · PostgreSQL 17 · Redis 7 (Docker All-in-One)
- **Upstream:** https://github.com/HiEventsDev/hi.events
- **Web UI Port:** `8123` → `http://<LXC-IP>:8123`
- **Stil:** [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE)
  (Variablen oben, `set -euo pipefail`, idempotent, Verifikation, `onboot: 1`, systemd `Restart=always`)

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"
```

Mit eigener CT-ID / Ressourcen:

```bash
CTID=101 VAR_CPU=2 VAR_RAM=4096 VAR_DISK=12 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"
```

Alle Optionen:

```bash
wget -qO /tmp/hi-events.sh https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh
chmod +x /tmp/hi-events.sh
/tmp/hi-events.sh --help
# /tmp/hi-events.sh --ctid 101 --cpu 2 --ram 4096 --disk 12 --storage local-lvm --bridge vmbr0 --ip dhcp
# /tmp/hi-events.sh --vm                      # QEMU-VM statt LXC (leistungshungrig / ohne Nesting)
# /tmp/hi-events.sh --reinstall               # Container neu aufbauen (DATENVERLUST)
```

| ENV-Variable | Default | Bedeutung |
|---|---|---|
| `CTID` | nächste freie ID | Container-ID |
| `HOSTNAME_CT` | `hi-events` | Hostname |
| `VAR_CPU` / `VAR_RAM` / `VAR_DISK` | `2` / `4096` / `12` | vCPU / MB RAM / GB Disk |
| `CONTAINER_STORAGE` / `TEMPLATE_STORAGE` | `local-lvm` / `local` | Storages |
| `BRIDGE` / `NET_CONFIG` | `vmbr0` / `dhcp` | Netz (`dhcp` oder `192.168.1.50/24,gw=192.168.1.1`) |
| `HI_EVENTS_IMAGE` | `daveearley/hi.events-all-in-one:latest` | Docker-Image |
| `WEB_PORT` | `8123` | Web UI Port |
| `POSTGRES_PASSWORD` | zufällig | DB-Passwort (bleibt bei Update erhalten) |
| `MODE` | `lxc` | `lxc` oder `vm` |
| `REINSTALL` | `0` | `1` = neu aufbauen |

## Was das Script tut

1. Prüft Root + Proxmox-Host (`pct`/`pvesh`), wählt CT-ID, lädt Debian-12-Template via `pveam`.
2. Erstellt LXC (unprivileged, `nesting=1,keyctl=1` für Docker, `onboot: 1`).
3. Installiert **im Container** (idempotent): Docker + Compose-Plugin, `/opt/hi-events/docker-compose.yml`
   (All-in-One + Postgres 17 + Redis 7, `restart: unless-stopped`, Port `8123:80` → bind `0.0.0.0`),
   `.env` (einmalig `APP_KEY`/`JWT_SECRET`/`POSTGRES_PASSWORD`, danach Secrets-sicher),
   `systemd/hi-events.service` (`enable`, `Restart=always`, `After=network-online.target` + `docker.service`).
4. Öffnet Port 8123 in der Container-Firewall (iptables/ufw, falls aktiv).
5. **Verifiziert selbst:** `systemctl is-active hi-events.service` + HTTP-Check `localhost:8123`
   + `onboot`-Check, gibt finale URL + Container-IP aus.
6. Bei Fehlern: **komplette Kette** (Befehl, Exit-Code, Zeile, Stacktrace via `caller`,
   40 Log-Zeilen, `pct status`, `systemctl status`, `docker ps`, Compose-Logs) + `bash -x`-Hinweis.
   Log: `/var/log/hi-events-install.log`.

## Update / Deinstall

```bash
# Update (Image ziehen, Volumes/SECRETS bleiben):
pct exec <CTID> -- bash -c 'cd /opt/hi-events && docker compose pull && docker compose up -d'

# Re-Run des Installers (idempotent, kein Datenverlust):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"

# Deinstall (Container + Daten weg):
CTID=<CTID> bash /tmp/hi-events.sh --uninstall
# entspricht: pct stop <CTID> && pct destroy <CTID>
```

## Testdurchlauf (Installation → Reboot → Web UI)

```bash
# 1. Installieren (auf dem PVE-Host):
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/HiEventingProxmox/main/install/hi-events.sh)"
# Erwartet u. a.:
#  ✓ Container 101 erstellt (onboot=1)
#  ✓ Service läuft (systemctl is-active: active)
#  ✓ Web UI antwortet (HTTP 200)
#  ✓ Hi.Events erfolgreich installiert!
#    Web UI      : http://192.168.1.101:8123

# 2. Reboot des LXC + Erreichbarkeit belegen:
pct reboot 101
sleep 45
pct exec 101 -- systemctl is-active hi-events.service   # → active
curl -fsS -o /dev/null -w "HTTP %{http_code}\n" http://192.168.1.101:8123/  # → HTTP 200
pct exec 101 -- journalctl -u hi-events.service --no-pager -n 20
```

Erwartete Ausgabe (gekürzt):

```text
 ● Erstelle LXC-Container 101 (hi-events: 2 vCPU, 4096 MB RAM, 12 GB Disk)
 ✓ Container 101 erstellt (onboot=1)
 ● Installiere Hi.Events im Container 101 (idempotent)
 ✓ In-Container-Setup abgeschlossen
 ● Verifiziere Installation (Service + Web UI + onboot)
 ✓ Service läuft (systemctl is-active: active)
 ✓ Web UI antwortet (HTTP 200)
 ✓ Reboot-Sicherheit: onboot: 1 + systemd enable hi-events.service

 ✓ Hi.Events erfolgreich installiert!
   Web UI      : http://192.168.1.101:8123
```

## Debugging

```bash
tail -n 100 /var/log/hi-events-install.log
pct exec <CTID> -- systemctl --no-pager status hi-events.service
pct exec <CTID> -- bash -c 'cd /opt/hi-events && docker compose logs --tail=100 --no-color'
pct exec <CTID> -- journalctl -u hi-events.service --no-pager -n 50
bash -x /tmp/hi-events.sh 2>&1 | tee /tmp/hi-events-debug.log
```

## Dateien in diesem Repo

```text
install/hi-events.sh        # Proxmox-Install-Script (DER Einzeiler, Variablen oben)
systemd/hi-events.service   # systemd-Unit (wird vom Installer in den LXC gelegt)
README.md                   # diese Datei
```

Hinweis: App-Code + Compose-Referenz bleiben bewusst **GitHub-first beim Upstream**
(`HiEventsDev/hi.events`, Image `daveearley/hi.events-all-in-one`) – kein Fork nötig.
Lizenz Hi.Events: AGPL-3.0 + Zusatzbedingungen („Powered by Hi.Events“-Hinweis, siehe Upstream-LICENCE);
white-label nur mit kommerzieller Lizenz (hello@hi.events).
