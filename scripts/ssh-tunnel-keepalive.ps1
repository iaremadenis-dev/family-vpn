#Requires -Version 5.1
<#
.SYNOPSIS
  Keep the Family VPN reverse SSH tunnel alive (Windows -> VPS).
.DESCRIPTION
  Forwards VPS 127.0.0.1:13010 to the local panel 127.0.0.1:3010.
  Connects as the unprivileged user fvpn-tunnel. That account has no shell;
  the key may only remote-forward 127.0.0.1:13010. Reconnects after a drop.
  A dead remote listener is released by sshd ClientAlive, not by a root shell.
  The VPS address is read from %LOCALAPPDATA%\FamilyVPN\tunnel-host.txt
  unless -VpsHost is passed. No passwords or private keys are stored here.
#>
param(
  [string]$VpsHost = '',
  [string]$VpsUser = 'fvpn-tunnel',
  [int]$RemotePort = 13010,
  [int]$LocalPort = 3010,
  [int]$ReconnectDelaySec = 5,
  [int]$ServerAliveInterval = 20,
  [int]$ServerAliveCountMax = 3,
  [string]$IdentityFile = (Join-Path $env:USERPROFILE '.ssh\family_vpn_tunnel_ed25519')
)

$ErrorActionPreference = 'Continue'
$ssh = Get-Command ssh.exe -ErrorAction Stop | Select-Object -ExpandProperty Source
$logDir = Join-Path $env:LOCALAPPDATA 'FamilyVPN'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'ssh-tunnel.log'

function Write-TunnelLog {
  param([string]$Message)
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  Add-Content -Path $logFile -Value $line -Encoding UTF8
}

if (-not $VpsHost) {
  $hostFile = Join-Path $logDir 'tunnel-host.txt'
  if (Test-Path -LiteralPath $hostFile) {
    $VpsHost = (Get-Content -LiteralPath $hostFile -Raw).Trim()
  }
}
if (-not $VpsHost) {
  Write-TunnelLog 'missing VPS host: pass -VpsHost or create %LOCALAPPDATA%\FamilyVPN\tunnel-host.txt'
  exit 1
}

$forward = "127.0.0.1:${RemotePort}:127.0.0.1:${LocalPort}"
$target = "${VpsUser}@${VpsHost}"

Write-TunnelLog "keepalive start user=$VpsUser host=$VpsHost -R $forward"
Write-TunnelLog "log=$logFile"
if (-not (Test-Path -LiteralPath $IdentityFile)) {
  Write-TunnelLog "missing identity file $IdentityFile"
  exit 1
}
Write-TunnelLog "identity=$IdentityFile"

while ($true) {
  $other = @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match [regex]::Escape($forward) -and $_.ProcessId -ne $PID })
  if ($other.Count -gt 0) {
    Write-TunnelLog "another tunnel ssh is already running pid=$($other[0].ProcessId); waiting"
    Start-Sleep -Seconds $ReconnectDelaySec
    continue
  }

  Write-TunnelLog 'connecting with restricted tunnel key...'
  & $ssh `
    -N `
    -i $IdentityFile `
    -o 'IdentitiesOnly=yes' `
    -o 'BatchMode=yes' `
    -o 'ExitOnForwardFailure=yes' `
    -o "ServerAliveInterval=$ServerAliveInterval" `
    -o "ServerAliveCountMax=$ServerAliveCountMax" `
    -o 'StrictHostKeyChecking=accept-new' `
    -R $forward `
    $target
  $code = $LASTEXITCODE
  Write-TunnelLog "tunnel exited code=$code; reconnect in ${ReconnectDelaySec}s"
  Start-Sleep -Seconds $ReconnectDelaySec
}
