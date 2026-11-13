#!/usr/bin/env bash
# install-keepalive.sh — deploy the GSP keepalive (systemd timer) on an Ubuntu host
# where cmpunlocker is already installed. Run:  sudo bash install-keepalive.sh
# Installs:
#   /usr/local/lib/cmpunlocker/gsp-keepalive.sh
#   /etc/systemd/system/gsp-keepalive.service
#   /etc/systemd/system/gsp-keepalive.timer   (enabled, runs every 2 minutes)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GSPDIR=/usr/local/lib/cmpunlocker

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
[ -x "$GSPDIR/gsp-restore" ] || { echo "cmpunlocker not found ($GSPDIR/gsp-restore missing)"; exit 1; }

install -m 0755 "$here/gsp-keepalive.sh"     "$GSPDIR/gsp-keepalive.sh"
install -m 0644 "$here/gsp-keepalive.service" /etc/systemd/system/gsp-keepalive.service
install -m 0644 "$here/gsp-keepalive.timer"   /etc/systemd/system/gsp-keepalive.timer
systemctl daemon-reload
systemctl enable --now gsp-keepalive.timer

echo '--- timer state ---'
systemctl is-enabled gsp-keepalive.timer
systemctl is-active gsp-keepalive.timer
systemctl list-timers gsp-keepalive.timer --no-pager || true

echo '--- manual run (verify) ---'
"$GSPDIR/gsp-keepalive.sh"
echo "exit=$?"
echo '--- recent keepalive log ---'
tail -5 /var/log/gsp-keepalive.log 2>/dev/null || echo '(no restore events yet — normal if no VFIO card needs re-arming)'
echo 'done.'
