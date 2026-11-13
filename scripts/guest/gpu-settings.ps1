# gpu-settings.ps1 — guest-side GPU stability settings for a passed-through CMP 170HX.
# All changes are reversible. Run ELEVATED:
#   powershell -NoProfile -ExecutionPolicy Bypass -File gpu-settings.ps1
# (or: Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "<this file>"' -Wait)
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'gpu-settings.log'
function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Tee-Object -FilePath $log -Append }

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "=== gpu-settings start (admin=$isAdmin) ==="
if (-not $isAdmin) { Log 'ERROR: not elevated — re-run elevated'; exit 1 }

# (a) TDR delay 60s (default is 2s). Gives the GPU driver more time before Windows
#     declares a TDR timeout — reduces transient stutters being escalated to driver errors.
$gk = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$props = (Get-Item $gk).Property
$td = if ($props -contains 'TdrDelay') { (Get-Item $gk).TdrDelay } else { 'unset' }
$tl = if ($props -contains 'TdrLevel') { (Get-Item $gk).TdrLevel } else { 'unset' }
Log "(a) TDR before: TdrDelay=$td TdrLevel=$tl"
New-ItemProperty -Path $gk -Name 'TdrDelay' -Value 60 -PropertyType DWord -Force | Out-Null
Log "(a) TdrDelay=60 set -> now $(Get-Item $gk | Select-Object -ExpandProperty TdrDelay)"

# (b) NVIDIA persistence mode. NOTE: on this platform (GA100 passthrough) nvidia-smi
#     reports "not supported" — that is a platform limitation, not an error. Kept for completeness.
$pm = & nvidia-smi -pm 1 2>&1 | Out-String
Log "(b) nvidia-smi -pm 1 => $pm"
$pmq = (& nvidia-smi -q 2>&1 | Select-String 'Persistence Mode' | Select-Object -First 1).ToString().Trim()
Log "(b) persistence now: $pmq"

# (c) Power management mode = Prefer maximum performance (NvDLIS 18022).
#     NOTE: written successfully, but datacenter drivers may not apply it (idle clocks
#     stay low). Harmless to set; don't expect a change.
$nv = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvDLIS'
if (-not (Test-Path $nv)) { New-Item -Path $nv -Force | Out-Null; Log '(c) created NvDLIS key' }
$nvprops = (Get-Item $nv).Property
if ($nvprops -contains '18022') { Log "(c) NvDLIS 18022 pre-existing = $((Get-Item $nv).('18022'))" }
New-ItemProperty -Path $nv -Name '18022' -Value 1 -PropertyType DWord -Force | Out-Null
Log "(c) NvDLIS 18022=1 set -> now $((Get-Item $nv).('18022'))"

# (d) PCIe Link State Power Management = Off (power plan).
#     NOTE: on Windows 11 24H2 the PCI Express subgroup / this setting has been removed
#     from the power plans, so the query fails — in that case skip (platform N/A).
$guidline = (powercfg /getactivescheme) | Select-String -Pattern '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
if ($guidline) { $scheme = $guidline.Matches[0].Groups[1].Value } else { $scheme = 'SCHEME_CURRENT' }
Log "(d) active scheme: $scheme"
$sub = '501a4d13-42af-4429-9fd1-a8218c268e20'   # PCI Express subgroup
$set = '0f238704-7fa7-4e15-bc97-ef5e17d2d37d'   # Link State Power Management
$q = (powercfg /q $scheme $sub $set 2>&1) | Out-String
if ($LASTEXITCODE -eq 0) {
    powercfg /setacvalueindex $scheme $sub $set 0 | Out-Null
    powercfg /setdcvalueindex $scheme $sub $set 0 | Out-Null
    powercfg /setactive $scheme | Out-Null
    Log '(d) PCIe Link State PM = Off (AC+DC) applied, scheme re-activated'
} else {
    Log "(d) WARNING: PCI Express link state PM setting not found in active scheme - skipped (platform N/A, e.g. Win11 24H2). query was: $q"
}

# Reboot applies (a) fully. (b)/(c)/(d) are immediate where supported.
Log "=== gpu-settings done (reboot the VM to fully apply TDR settings) ==="
