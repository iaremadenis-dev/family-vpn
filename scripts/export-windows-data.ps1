# Exports the local Family VPN SQLite database for transfer to the Linux panel host.
# Run from the repository root on Windows while the panel is stopped.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sourceDir = if ($env:FAMILY_VPN_DATA_DIR) { $env:FAMILY_VPN_DATA_DIR } else { Join-Path $root "data" }
$stamp = Get-Date -Format "yyyyMMddTHHmmss"
$outDir = Join-Path $root ("export-" + $stamp)
New-Item -ItemType Directory -Path $outDir | Out-Null

$db = Join-Path $sourceDir "family-vpn.sqlite"
if (-not (Test-Path $db)) {
  throw "Database not found: $db"
}

Copy-Item $db (Join-Path $outDir "family-vpn.sqlite")
foreach ($suffix in @("-wal", "-shm")) {
  $path = $db + $suffix
  if (Test-Path $path) {
    Copy-Item $path (Join-Path $outDir ("family-vpn.sqlite" + $suffix))
  }
}

Get-FileHash (Join-Path $outDir "family-vpn.sqlite") -Algorithm SHA256 |
  ForEach-Object { "$($_.Hash.ToLower())  family-vpn.sqlite" } |
  Set-Content -Encoding ascii (Join-Path $outDir "family-vpn.sqlite.sha256")

Write-Host "Exported to $outDir"
Write-Host "Copy this folder to the panel host, then run scripts/import-panel-data.sh"
