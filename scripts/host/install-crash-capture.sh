#!/usr/bin/env bash
# install-crash-capture.sh — 讓下一次 host 硬掛死「有證據可查」
#
# 背景：本案例 host（Ubuntu 26.04 + 4×CMP 170HX + nvidia 615）曾兩度靜默硬掛死
# （journal 戛然而止、無 kernel panic/Xid/lockup），掛死時零證據。本腳本套用：
#   1) rasdaemon            — MCE / PCIe AER 硬體錯誤收集（常駐）
#   2) softlockup_panic=1   — soft lockup 直接 panic（不再靜默掛死）
#      hung_task_panic=1    — D 態 >120s 直接 panic
#   3) kdump-tools + GRUB   — crashkernel=256M（下次開機後生效，panic 存 vmcore 到 /var/crash）
#
# 用法：sudo bash install-crash-capture.sh   （冪等，可重跑；不碰 vLLM/容器）
# 注意：GRUB 那行用 python3 重寫——sed 經「PowerShell here-string → ssh → bash」
#       的引號層會被啃掉引號，\042 在替換段又會變 \0 反向引用（見 pitfall-log 坑 10）。
set -uo pipefail
CK="crashkernel=256M"

# 1) rasdaemon
if ! dpkg -s rasdaemon >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y rasdaemon
fi
systemctl enable --now rasdaemon

# 2) hang -> panic（立即生效 + 持久）
mkdir -p /etc/sysctl.d
printf 'kernel.softlockup_panic=1\nkernel.hung_task_panic=1\n' > /etc/sysctl.d/99-hangpanic.conf
sysctl -w kernel.softlockup_panic=1 kernel.hung_task_panic=1

# 3) kdump：GRUB crashkernel（python3 改行，避開引號坑）
python3 - <<PYEOF
p = '/etc/default/grub'
ck = '${CK}'
lines = open(p).read().splitlines(True)
out = []
for l in lines:
    if l.startswith('GRUB_CMDLINE_LINUX='):
        val = l.split('=', 1)[1].strip().strip('"')
        if ck not in val:
            val = (val + ' ' + ck).strip()
        out.append('GRUB_CMDLINE_LINUX="%s"\n' % val)
    else:
        out.append(l)
open(p, 'w').writelines(out)
for l in open(p).read().splitlines():
    if l.startswith('GRUB_CMDLINE_LINUX'):
        print(l)
PYEOF
grub-mkconfig -o /boot/grub/grub.cfg

# 4) kdump 服務（unit 名是 kdump-tools，不是 kdump）
systemctl enable kdump-tools

echo '=== crash-capture 完成 ==='
echo "rasdaemon:    $(systemctl is-enabled rasdaemon 2>/dev/null) / $(systemctl is-active rasdaemon 2>/dev/null)"
echo "kdump-tools:  $(systemctl is-enabled kdump-tools 2>/dev/null)（vmcore 能力下次開機後生效）"
echo "sysctl:       softlockup_panic=$(sysctl -n kernel.softlockup_panic) hung_task_panic=$(sysctl -n kernel.hung_task_panic)"
echo '下次掛死查證：sudo ras-mc-ctl --errors ; ls /var/crash ; journalctl -b -1 | grep -iE "xid|lockup|panic|Call Trace"'
