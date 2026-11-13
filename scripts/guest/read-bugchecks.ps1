# read-bugchecks.ps1 — read recent BSOD (bugcheck) codes + parameters from the event log.
# Use this INSTEAD of minidump parsers: on this stack the files in C:\Windows\Minidump
# start with "PAGEDU64" (kernel dump container), NOT "MDMP", so MDMP tools fail
# (bad signature 0x45474150). The System event log has the full bugcheck data.
#
# Usage:  powershell -NoProfile -File read-bugchecks.ps1 [-Days 3]
param([int]$Days = 3)
$since = (Get-Date).AddDays(-$Days)
$events = Get-WinEvent -FilterHashtable @{
    LogName = 'System'
    Id = 1001
    ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
    StartTime = $since
} -ErrorAction SilentlyContinue
if (-not $events) {
    Write-Output "No bugcheck (WER Id 1001) events in the last $Days days."
    exit 0
}
$NAMES = @{
    '0x0000001a' = 'MEMORY_MANAGEMENT'
    '0x000000d1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA'
    '0x0000007e' = 'SYSTEM_SERVICE_EXCEPTION'
    '0x0000007f' = 'UNEXPECTED_KERNEL_MODE_TRAP'
    '0x0000009f' = 'CRITICAL_PROCESS_DIED'
    '0x00000139' = 'DPC_WATCHDOG_VIOLATION'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR'
}
foreach ($e in ($events | Sort-Object TimeCreated)) {
    $line = $e.Message -replace '\s+', ' '
    $m = [regex]::Match($line, '(0x[0-9a-fA-F]{8})\s*\(([^)]*)\)')
    $code = if ($m.Success) { $m.Groups[1].Value.ToLower() } else { '?' }
    $params = if ($m.Success) { $m.Groups[2].Value } else { '?' }
    $dm = [regex]::Match($line, '([A-Za-z]:\\[^\s]*\.dmp)')
    $dump = if ($dm.Success) { $dm.Groups[1].Value } else { '(no dump path in message)' }
    $name = if ($NAMES.ContainsKey($code)) { $NAMES[$code] } else { '' }
    Write-Output ("{0}  bugcheck={1} {2}  params=[{3}]  dump={4}" -f $e.TimeCreated, $code, $name, $params, $dump)
}
Write-Output ''
Write-Output 'Interpretation (this stack):'
Write-Output '  0x1A / 0x139 / 0x7E together = GPU driver / VRAM layer corrupting memory or'
Write-Output '  hanging under heavy CUDA load (hardware/firmware-level). Not fixable by TDR'
Write-Output '  settings; see README 7 for mitigation options (reduce load / swap card / move'
Write-Output '  ComfyUI to host). See docs/pitfall-log.md for the full incident record.'
