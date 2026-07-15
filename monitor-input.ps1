# monitor-input.ps1 - Switch monitor input on Windows (ControlMyMonitor)
#
# Setup:
#   1. Download ControlMyMonitor to ~\dev\controlmymonitor\
#   2. Override path with env MONITOR_CMM_PATH if needed
#   3. Run: .\monitor-input.ps1 dp2

param(
    [Parameter(Position = 0)]
    [string]$Input
)

$ErrorActionPreference = 'Stop'

$CmmPath = if ($env:MONITOR_CMM_PATH) { $env:MONITOR_CMM_PATH } else { "$env:USERPROFILE\dev\controlmymonitor\ControlMyMonitor.exe" }
$Monitor = if ($env:MONITOR_CMM_MONITOR) { $env:MONITOR_CMM_MONITOR } else { 'Primary' }
$VcpInput = 60

$Inputs = @{
    dp1   = 15
    dp2   = 16
    hdmi1 = 17
    hdmi2 = 18
    usbc  = 27
}

function Show-Usage {
    Write-Host @"

monitor-input.ps1 - Switch monitor input (Windows)

Usage:
  .\monitor-input.ps1 dp1
  .\monitor-input.ps1 dp2
  .\monitor-input.ps1 hdmi1

Config (optional env vars):
  MONITOR_CMM_PATH    Path to ControlMyMonitor.exe
  MONITOR_CMM_MONITOR Monitor name (default: Primary)

"@
}

if (-not $Input -or $Input -in @('-h', '--help', 'help')) {
    Show-Usage
    exit 0
}

$name = $Input.ToLower()
if (-not $Inputs.ContainsKey($name)) {
    Write-Error "Unknown input '$Input'. Valid: $($Inputs.Keys -join ', ')"
    exit 1
}

if (-not (Test-Path -LiteralPath $CmmPath)) {
    Write-Error @"
ControlMyMonitor not found at: $CmmPath

Download: https://www.nirsoft.net/utils/control_my_monitor.html
Set path: `$env:MONITOR_CMM_PATH = 'C:\path\to\ControlMyMonitor.exe'
"@
    exit 1
}

$value = $Inputs[$name]
& $CmmPath /SetValue $Monitor $VcpInput $value

if ($LASTEXITCODE -ne 0) {
    Write-Error "ControlMyMonitor failed (exit $LASTEXITCODE)"
    exit $LASTEXITCODE
}

Write-Host "Switched to $Input ($value)"
