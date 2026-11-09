#Requires -Version 5.1
<#
.SYNOPSIS
  Install a per-user Startup shortcut for Family VPN SSH tunnel keepalive.
#>
param(
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo 'scripts\ssh-tunnel-keepalive.ps1'))) {
  $repo = 'C:\Projects\family-vpn'
}
$keepalive = Join-Path $repo 'scripts\ssh-tunnel-keepalive.ps1'
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'FamilyVPN-SSH-Tunnel.lnk'

if ($Uninstall) {
  if (Test-Path $shortcutPath) {
    Remove-Item -Force $shortcutPath
    Write-Host "Removed $shortcutPath"
  } else {
    Write-Host 'Shortcut not present.'
  }
  exit 0
}

$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath = 'powershell.exe'
$sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File `"$keepalive`""
$sc.WorkingDirectory = $repo
$sc.WindowStyle = 1
$sc.Description = 'Family VPN reverse SSH tunnel keepalive (VPS :13010 -> local :3010)'
$sc.Save()
Write-Host "Installed: $shortcutPath"
Write-Host "Target: $keepalive"
Write-Host 'Tunnel starts at user logon as fvpn-tunnel. Host is read from %LOCALAPPDATA%\FamilyVPN\tunnel-host.txt.'
