# Downloads the latest successful agent-release artifact into ./releases
# for the local panel endpoint http://localhost:3010/releases/*
# Requires GitHub CLI (gh) authenticated to the private repo.
# Does not touch any VPS.
param(
  [string]$Workflow = "agent-release.yml",
  [string]$Artifact = "family-vpn-agent-0.4.0",
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is required. Install GitHub CLI: winget install --id GitHub.cli -e"
  }
}

Require-Command gh

Set-Location $RepoRoot
$releases = Join-Path $RepoRoot "releases"
New-Item -ItemType Directory -Force -Path $releases | Out-Null

Write-Host "Waiting for latest successful $Workflow run on main..."
$runs = gh run list --workflow $Workflow --branch main --json databaseId,conclusion,status,headSha --limit 20 | ConvertFrom-Json
if ($null -eq $runs) { $runs = @() }
$runs = @($runs)
$runId = ($runs |
  Where-Object { $_.status -eq "completed" -and $_.conclusion -eq "success" } |
  Select-Object -First 1).databaseId

if (-not $runId) {
  throw "No successful $Workflow run found on main yet. Push the workflow commit and wait for Actions."
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("family-vpn-release-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
  Write-Host "Downloading artifact $Artifact from run $runId..."
  gh run download $runId --name $Artifact --dir $stage

  $source = $stage
  $nested = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
  if ($nested) { $source = $nested.FullName }

  foreach ($name in @(
    "family-vpn-agent-linux-amd64",
    "install.sh",
    "SHA256SUMS",
    "INSTALL.txt",
    "bootstrap.sh"
  )) {
    $from = Join-Path $source $name
    if (-not (Test-Path $from)) {
      throw "Artifact missing file: $name"
    }
    Copy-Item -Force $from (Join-Path $releases $name)
  }
}
finally {
  Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

Write-Host "Verifying SHA256SUMS locally..."
Push-Location $releases
try {
  $lines = Get-Content .\SHA256SUMS
  foreach ($line in $lines) {
    if ($line -notmatch '^\s*([0-9a-fA-F]{64})\s+\*?(\S+)\s*$') { continue }
    $want = $Matches[1].ToLowerInvariant()
    $file = $Matches[2]
    $path = Join-Path $releases $file
    $hash = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
    if ($hash -ne $want) {
      throw "Checksum mismatch for $file"
    }
    Write-Host "ok  $file"
  }
}
finally {
  Pop-Location
}

Write-Host ""
Write-Host "Release files are in $releases"
Write-Host "Panel URL: http://localhost:3010/releases/SHA256SUMS"
Write-Host "Tunnel URL: http://127.0.0.1:13010/releases/SHA256SUMS"
Get-Content (Join-Path $releases "INSTALL.txt")
