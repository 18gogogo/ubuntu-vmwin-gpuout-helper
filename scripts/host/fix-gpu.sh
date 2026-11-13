#!/usr/bin/env bash
# fix-gpu.sh — recover a passed-through CMP 170HX WITHOUT a host reboot.
# Usage:  sudo bash fix-gpu.sh [domain] [BDF]
#   domain  libvirt domain name           (default: win11)
#   BDF     passthrough card, e.g. 0000:44:00.0
#           (default: auto-detect the first CMP 170HX bound to vfio-pci)
# Env overrides:
#   CMP_GSP_RESTORE    path to gsp-restore        (default /usr/local/lib/cmpunlocker/gsp-restore)
#   CMP_PASSTHROUGH_SH path to passthrough.sh     (default: auto-search)
# Run as root (sudo). Safe whether the VM is running or already off.
set -uo pipefail

DOM="${1:-win11}"
BDF="${2:-}"
GSP="${CMP_GSP_RESTORE:-/usr/local/lib/cmpunlocker/gsp-restore}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- resolve passthrough.sh ---
PTSH="${CMP_PASSTHROUGH_SH:-}"
if [ -z "$PTSH" ]; then
  for cand in \
    "$HOME"/cmpunlocker-*/tools/passthrough.sh \
    /home/*/"cmpunlocker-"*/tools/passthrough.sh \
    /usr/local/lib/cmpunlocker/tools/passthrough.sh \
    /opt/cmpunlocker/tools/passthrough.sh
  do
    [ -x "$cand" ] && { PTSH="$cand"; break; }
  done
fi
if [ -z "$PTSH" ] || [ ! -x "$PTSH" ]; then
  log "ERROR: passthrough.sh not found (set CMP_PASSTHROUGH_SH=...)"; exit 1
fi

# --- resolve BDF (auto-detect vfio-bound CMP 170HX) ---
if [ -z "$BDF" ]; then
  BDF=""
  for dev in /sys/bus/pci/devices/*; do
    [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x10de" ] || continue
    case "$(cat "$dev/device" 2>/dev/null)" in 0x20c2|0x2082) ;; *) continue ;; esac
    drv=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)" 2>/dev/null || echo none)
    if [ "$drv" = "vfio-pci" ]; then BDF=$(basename "$dev"); break; fi
  done
  if [ -z "$BDF" ]; then
    log "ERROR: no CMP 170HX bound to vfio-pci found; pass BDF explicitly"; exit 1
  fi
  log "auto-detected passthrough BDF=$BDF"
fi

log "=== fix-gpu start (domain=$DOM bdf=$BDF ptsh=$PTSH) ==="

log "[0/3] current GSP state:"
"$GSP" show "$BDF" 2>&1 || true

log "[1/3] stopping VM '$DOM' ..."
# NOTE: `virsh domstate` output is LOCALE-DEPENDENT (zh hosts say 執行中, not running),
# so the graceful-stop poll may never match; the destroy fallback below is essential.
st=$(virsh domstate "$DOM" 2>/dev/null || echo unknown)
case "$st" in
  *"shut off"*|*"已關閉"*|*"shut"*) : ;;
  *)
    virsh shutdown "$DOM" 2>&1 || true
    for i in $(seq 1 45); do
      st=$(virsh domstate "$DOM" 2>/dev/null || echo unknown)
      case "$st" in *"shut off"*|*"已關閉"*) break ;; esac
      sleep 2
    done
    ;;
esac
st=$(virsh domstate "$DOM" 2>/dev/null || echo unknown)
case "$st" in
  *"shut off"*|*"已關閉"*) : ;;
  *)
    log "graceful stop not done (state=$st), destroying..."
    virsh destroy "$DOM" 2>&1 || true
    sleep 3
    ;;
esac
log "VM state now: $(virsh domstate "$DOM" 2>/dev/null)"

log "[2/3] passthrough.sh restore $BDF ..."
"$PTSH" restore "$BDF" 2>&1

log "[3/3] starting VM '$DOM' ..."
virsh start "$DOM" 2>&1
sleep 2
log "VM state now: $(virsh domstate "$DOM" 2>/dev/null)"
log "=== fix-gpu done — verify: gsp-restore show $BDF  (no 'needs restore') and nvidia-smi in guest ==="
