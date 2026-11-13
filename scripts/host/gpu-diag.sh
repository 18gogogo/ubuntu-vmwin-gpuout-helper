#!/usr/bin/env bash
# gpu-diag.sh — one-shot diagnostics for GPU passthrough drops (run on the HOST as root).
# Collects: per-card driver/PCIe/GSP state, dmesg Xid/AER/retrain/Booter, nvidia-smi,
# keepalive timer status, VM list. Output is safe to paste into a support request
# (no hostnames/IPs/passwords are printed).
set -uo pipefail

GSP="${CMP_GSP_RESTORE:-/usr/local/lib/cmpunlocker/gsp-restore}"

echo "=== date: $(date '+%F %T %Z') ==="
echo
echo "=== NVIDIA PCIe devices (lspci) ==="
lspci -nn 2>/dev/null | grep -i nvidia || echo '(none found)'
echo
echo "=== per-card detail ==="
for d in /sys/bus/pci/devices/*; do
  bdf=$(basename "$d")
  [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
  drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || echo none)
  echo "--- $bdf  (driver=$drv)"
  lspci -s "$bdf" 2>/dev/null | sed 's/^/    /'
  lspci -vvv -s "$bdf" 2>/dev/null | grep -E 'LnkCap|LnkSta' | sed 's/^[[:space:]]*/    /'
  if [ -x "$GSP" ]; then
    "$GSP" show "$bdf" 2>&1 | sed 's/^/    /'
  fi
done
echo
echo "=== dmesg: Xid / AER / retrain / Booter (tail 40) ==="
dmesg 2>/dev/null | grep -iE 'xid|aer|retrain|booter' | tail -40 || echo '(no matches)'
echo
echo "=== nvidia-smi (host-bound cards) ==="
nvidia-smi --query-gpu=index,pci.bus_id,name,memory.total,temperature.gpu,utilization.gpu,ecc.errors.uncorrected.volatile.total --format=csv 2>&1 || true
echo
echo "=== GSP keepalive ==="
systemctl is-active gsp-keepalive.timer 2>/dev/null || echo 'gsp-keepalive.timer: not installed'
tail -10 /var/log/gsp-keepalive.log 2>/dev/null || echo '(no keepalive log yet)'
echo
echo "=== libvirt domains ==="
virsh list --all 2>/dev/null || echo '(virsh unavailable)'
echo
echo "=== done ==="
