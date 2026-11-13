#!/usr/bin/env bash
# gsp-keepalive.sh — re-arm the cmpunlocker GSP unlock of whichever CMP 170HX is
# currently bound to vfio-pci (i.e. passed through to a VM).
# Idempotent, safe to run often. Does NOTHING when no CMP card is on vfio-pci
# (e.g. VM off, all cards on the host nvidia driver).
#
# Env override: CMP_GSP_RESTORE (default /usr/local/lib/cmpunlocker/gsp-restore)
GSP="${CMP_GSP_RESTORE:-/usr/local/lib/cmpunlocker/gsp-restore}"
LOG="/var/log/gsp-keepalive.log"
for dev in /sys/bus/pci/devices/*; do
  bdf=$(basename "$dev")
  [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x10de" ] || continue
  case "$(cat "$dev/device" 2>/dev/null)" in
    0x20c2|0x2082) ;;
    *) continue ;;
  esac
  drv=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)" 2>/dev/null || echo none)
  [ "$drv" = "vfio-pci" ] || continue
  st=$("$GSP" show "$bdf" 2>&1)
  if echo "$st" | grep -q "needs restore"; then
    "$GSP" restore "$bdf" >/dev/null 2>&1
    echo "[$(date '+%F %T')] RESTORED $bdf" >> "$LOG"
  fi
done
exit 0
