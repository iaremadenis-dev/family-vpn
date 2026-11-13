#Requires -Version 5.1
<#
.SYNOPSIS
  Publish panel-936a5e9b2ccb signed assets from this Windows PC to DE-01 /releases/.
  Does NOT update panel/agent, does NOT restart services, does NOT touch SQLite/master.key/volumes.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\Projects\family-vpn\scripts\publish-releases-from-windows.ps1
#>
param(
  [string]$PanelHost = '62.133.60.25',
  [string]$SshUser = 'root',
  [string]$IdentityFile = (Join-Path $env:USERPROFILE '.ssh\family-vpn-de01'),
  [string]$RepoRoot = 'C:\Projects\family-vpn',
  [string]$Tag = 'panel-936a5e9b2ccb',
  [string]$ExpectedDigest = 'sha256:7a14eb9234f77fa3ae6e51c4af6567fe1f62292dc8bbf21ee8c494575e3d9ed8',
  [string]$OldDigest = 'sha256:b5a719f0148019784f4eb544289fb2acb4174cf1c8b76e70f18f73ac37b09479',
  [string]$ExpectedBootSha = '',
  [string]$ExpectedBootstrapSha = 'f2d7d938999a40e4d7205e2cdac0282858a6127120eddb5d0c740afdd0dea296',
  [string]$ExpectedPubFp = '1ec270a068a05c1e1af1a29953e92a29c6c518e0b43b90f1a1f417e47d59e259',
  [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
$env:Path = "C:\Program Files\GitHub CLI;C:\Program Files\Git\bin;C:\Program Files\nodejs;C:\Windows\System32\OpenSSH;" + $env:Path
$bashExe = 'C:\Program Files\Git\bin\bash.exe'
$nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
if (-not (Test-Path $bashExe)) { throw 'Git bash not found at C:\Program Files\Git\bin\bash.exe' }

function To-BashPath([string]$WinPath) {
  if ($WinPath -match '^([A-Za-z]):\\(.*)$') {
    return '/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
  }
  return ($WinPath -replace '\\', '/')
}

function Assert-File([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "missing file: $Path" }
}

function Get-Sha256Lower([string]$Path) {
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Sha256File([string]$ChecksumFile, [string]$Directory) {
  # GNU "HASH  filename" lines; verify with Get-FileHash (PowerShell 5.1).
  $lines = Get-Content -LiteralPath $ChecksumFile | Where-Object { $_.Trim() -ne '' }
  foreach ($line in $lines) {
    if ($line -notmatch '^([0-9a-fA-F]{64})[ \t]+\*?(.+)$') {
      throw "bad checksum line in $(Split-Path $ChecksumFile -Leaf): $line"
    }
    $want = $Matches[1].ToLowerInvariant()
    $name = $Matches[2].Trim()
    $path = Join-Path $Directory $name
    Assert-File $path
    $got = Get-Sha256Lower $path
    if ($got -ne $want) {
      throw "SHA256 mismatch for $name : got $got want $want"
    }
    Write-Host "SHA256 OK  $name"
  }
}

function Assert-Ed25519([string]$File, [string]$Sig, [string]$Pub, [string]$Fp) {
  $verify = Join-Path $RepoRoot 'scripts\verify-release-file.mjs'
  Assert-File $verify
  & $nodeExe $verify $File $Sig $Pub $Fp
  if ($LASTEXITCODE -ne 0) {
    throw "Ed25519 verify failed for $(Split-Path $File -Leaf)"
  }
  Write-Host "Ed25519 OK  $(Split-Path $File -Leaf)"
}

function Get-TarText([string]$Archive, [string]$Member) {
  # Use Git bash tar only as a reader; no $(...) embedded in PowerShell strings.
  $archBash = To-BashPath $Archive
  $out = & $bashExe -lc ('tar -xOf "' + $archBash + '" "' + $Member + '"')
  if ($LASTEXITCODE -ne 0) { throw "tar extract failed: $Member from $Archive" }
  return ($out | Out-String)
}

function Assert-NoSecrets([string]$Directory) {
  $badNames = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(master\.key|release-signing\.pem)$' -or $_.Extension -eq '.pem' -or $_.Extension -eq '.sqlite' })
  if ($badNames.Count -gt 0) {
    throw ("secret-like files in stage: " + ($badNames.FullName -join ', '))
  }
  $textFiles = Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object {
    $_.Extension -in @('.sh', '.txt', '.sig', '.pub', '.sha256', '.yml', '.md') -or
    $_.Name -in @('SHA256SUMS', 'install.sh', 'bootstrap.sh', 'PANEL-UPDATE.txt', 'INSTALL.txt')
  }
  foreach ($f in $textFiles) {
    if ($f.Name -eq 'release-signing.pub') { continue }
    $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($null -eq $raw) { continue }
    if ($raw -match 'BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY' -or $raw -match 'AGE-SECRET-KEY-1' -or $raw -match 'ghp_[A-Za-z0-9]{20,}') {
      throw ("secret text found in " + $f.Name)
    }
  }
}

Write-Host '=== Family VPN publish to DE-01 /releases/ ===' -ForegroundColor Cyan
Assert-File $IdentityFile
Assert-File (Join-Path $RepoRoot 'scripts\publish-releases-to-panel.sh')
$pubPath = "$IdentityFile.pub"
if (Test-Path $pubPath) {
  Write-Host ('SSH pubkey: ' + (Get-Content -LiteralPath $pubPath -Raw).Trim())
}

# GitHub auth via existing git credential / GH_TOKEN (never printed).
# Avoid PowerShell pipeline to git.exe (stdin/encoding breaks attribute parsing on 5.1).
if (-not $env:GH_TOKEN) {
  $credIn = Join-Path $env:TEMP ('fvpn-git-cred-' + [guid]::NewGuid().ToString('n') + '.txt')
  $credOutFile = Join-Path $env:TEMP ('fvpn-git-cred-out-' + [guid]::NewGuid().ToString('n') + '.txt')
  try {
    # LF + trailing blank line required by git-credential.
    [System.IO.File]::WriteAllText($credIn, "protocol=https`nhost=github.com`n`n")
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & cmd.exe /c "git credential fill < `"$credIn`" > `"$credOutFile`" 2>nul"
    $fillExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($fillExit -ne 0 -or -not (Test-Path -LiteralPath $credOutFile)) {
      throw 'GitHub auth missing. Run: gh auth login'
    }
    $token = $null
    foreach ($line in [System.IO.File]::ReadAllLines($credOutFile)) {
      if ($line -match '^password=(.+)$') {
        $token = $Matches[1].Trim()
        break
      }
    }
    if (-not $token -or $token.Length -lt 10) {
      throw 'GitHub auth missing. Run: gh auth login'
    }
    $env:GH_TOKEN = $token
  } finally {
    Remove-Item -LiteralPath $credIn, $credOutFile -Force -ErrorAction SilentlyContinue
  }
}
# Prefer API probe over `gh auth status` (status can be empty when only GH_TOKEN is set).
$probe = & gh.exe api user -q .login 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($probe)) {
  throw ("gh auth failed:`n" + $probe)
}
Write-Host ('GitHub auth: OK (' + $probe.Trim() + ')') -ForegroundColor Green

$sshTarget = $SshUser + '@' + $PanelHost
$sshBase = @(
  '-i', $IdentityFile,
  '-o', 'BatchMode=yes',
  '-o', 'IdentitiesOnly=yes',
  '-o', 'StrictHostKeyChecking=accept-new',
  '-o', 'ConnectTimeout=20'
)
& ssh.exe @sshBase $sshTarget 'echo SSH_OK' | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw @"
SSH key rejected by $sshTarget (password auth disabled).
Identity: $IdentityFile
Authorize this public key on DE-01 via the hosting/VPS console, then re-run:
  $pubPath
"@
}
Write-Host ("SSH: OK (" + $sshTarget + ")") -ForegroundColor Green

$stage = Join-Path $RepoRoot 'dist\fvpn-publish-stage'
$repoBash = To-BashPath $RepoRoot

if (-not $SkipDownload -or -not (Test-Path (Join-Path $stage 'PANEL-UPDATE.txt'))) {
  if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
  New-Item -ItemType Directory -Force -Path $stage | Out-Null
  Write-Host ("Downloading " + $Tag + " ...") -ForegroundColor Cyan
  & gh release download $Tag -R iaremadenis-dev/family-vpn -D $stage
  if ($LASTEXITCODE -ne 0) { throw "gh release download failed: $LASTEXITCODE" }
}

Assert-File (Join-Path $stage 'PANEL-UPDATE.txt')
function Read-PanelUpdateField([string]$Key) {
  $line = Get-Content -LiteralPath (Join-Path $stage 'PANEL-UPDATE.txt') |
    Where-Object { $_ -like ($Key + '=*') } |
    Select-Object -First 1
  if (-not $line) { throw ("PANEL-UPDATE.txt missing " + $Key) }
  return $line.Substring($Key.Length + 1).Trim()
}
$bootName = Read-PanelUpdateField 'PANEL_UPDATE_BOOT'
$archiveName = Read-PanelUpdateField 'PANEL_UPDATE_ARCHIVE'
$bootShaFromFile = Read-PanelUpdateField 'PANEL_UPDATE_BOOT_SHA256'
$digestFromFile = Read-PanelUpdateField 'IMAGE_DIGEST'
if ($ExpectedBootSha -eq '') { $ExpectedBootSha = $bootShaFromFile }
if ($digestFromFile -ne $ExpectedDigest) {
  throw ("PANEL-UPDATE IMAGE_DIGEST=$digestFromFile want $ExpectedDigest")
}

$required = @(
  $bootName,
  $archiveName,
  ($archiveName + '.sha256'),
  ($archiveName + '.sig'),
  'family-vpn-panel-image.tar',
  'family-vpn-panel-image.tar.sha256',
  'bootstrap.sh', 'install.sh', 'install.sh.sig',
  'family-vpn-agent-linux-amd64', 'SHA256SUMS', 'release-signing.pub',
  'INSTALL.txt', 'PANEL-UPDATE.txt', 'panel-image-id.txt'
)
foreach ($name in $required) { Assert-File (Join-Path $stage $name) }

Write-Host 'Verifying checksums (Get-FileHash), Ed25519, NEW digest, no secrets ...' -ForegroundColor Cyan
Assert-Sha256File (Join-Path $stage ($archiveName + '.sha256')) $stage
Assert-Sha256File (Join-Path $stage 'family-vpn-panel-image.tar.sha256') $stage
Assert-Sha256File (Join-Path $stage 'SHA256SUMS') $stage

$pubFpGot = Get-Sha256Lower (Join-Path $stage 'release-signing.pub')
if ($pubFpGot -ne $ExpectedPubFp) { throw "release-signing.pub FP mismatch: $pubFpGot" }
Write-Host 'SHA256 OK  release-signing.pub (pinned fingerprint)'

Assert-Ed25519 `
  (Join-Path $stage $archiveName) `
  (Join-Path $stage ($archiveName + '.sig')) `
  (Join-Path $stage 'release-signing.pub') `
  $ExpectedPubFp
Assert-Ed25519 `
  (Join-Path $stage 'install.sh') `
  (Join-Path $stage 'install.sh.sig') `
  (Join-Path $stage 'release-signing.pub') `
  $ExpectedPubFp

$bootSha = Get-Sha256Lower (Join-Path $stage $bootName)
if ($bootSha -ne $ExpectedBootSha) { throw "panel-update-boot SHA mismatch: $bootSha" }
Write-Host ("SHA256 OK  " + $bootName)

$bootstrapSha = Get-Sha256Lower (Join-Path $stage 'bootstrap.sh')
if ($bootstrapSha -ne $ExpectedBootstrapSha) { throw "bootstrap SHA mismatch: $bootstrapSha" }
Write-Host 'SHA256 OK  bootstrap.sh'

$imageId = (Get-Content -LiteralPath (Join-Path $stage 'panel-image-id.txt') -Raw).Trim()
if ($imageId -ne $ExpectedDigest) { throw "panel-image-id.txt is not NEW digest: $imageId" }
$panelUpdateTxt = Get-Content -LiteralPath (Join-Path $stage 'PANEL-UPDATE.txt') -Raw
if ($panelUpdateTxt -notmatch [regex]::Escape('IMAGE_DIGEST=' + $ExpectedDigest)) {
  throw 'PANEL-UPDATE.txt missing NEW IMAGE_DIGEST'
}
$bundleInfo = Get-TarText (Join-Path $stage $archiveName) 'family-vpn-panel-update/BUNDLE-INFO.txt'
if ($bundleInfo -notmatch [regex]::Escape('image_digest=' + $ExpectedDigest)) {
  throw 'update pack BUNDLE-INFO missing NEW image_digest'
}
if ($bundleInfo -match [regex]::Escape('image_digest=' + $OldDigest)) {
  throw 'update pack still pins OLD digest'
}
Write-Host ('Digest OK  NEW ' + $ExpectedDigest + ' (not old ' + $OldDigest + ')') -ForegroundColor Green

Assert-NoSecrets $stage
Write-Host 'Local integrity: OK' -ForegroundColor Green

Write-Host 'Uploading to DE-01 /tmp only (not panel data dirs) ...' -ForegroundColor Cyan
& ssh.exe @sshBase $sshTarget 'rm -rf /tmp/fvpn-release-stage /tmp/publish-releases-to-panel.sh && mkdir -p /tmp/fvpn-release-stage'
if ($LASTEXITCODE -ne 0) { throw "remote mkdir failed: $LASTEXITCODE" }

# scp: pass identity via -i; avoid PowerShell eating remote paths
& scp.exe -i $IdentityFile -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -r `
  (Join-Path $stage '*') "${sshTarget}:/tmp/fvpn-release-stage/"
if ($LASTEXITCODE -ne 0) { throw "scp stage failed: $LASTEXITCODE" }

& scp.exe -i $IdentityFile -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new `
  (Join-Path $RepoRoot 'scripts\publish-releases-to-panel.sh') "${sshTarget}:/tmp/publish-releases-to-panel.sh"
if ($LASTEXITCODE -ne 0) { throw "scp publish script failed: $LASTEXITCODE" }

Write-Host 'Remote publish (releases mount only; sha256sum on DE-01; no compose restart) ...' -ForegroundColor Cyan
# Remote script uses Linux sha256sum. Pass command as a plain string (no PS $(...) around sha256sum).
$remoteCmd = 'bash /tmp/publish-releases-to-panel.sh --from-dir /tmp/fvpn-release-stage'
& ssh.exe @sshBase $sshTarget $remoteCmd
if ($LASTEXITCODE -ne 0) { throw "remote publish failed: $LASTEXITCODE" }

Write-Host 'Verifying public HTTPS /releases/ (Get-FileHash + Ed25519 locally) ...' -ForegroundColor Cyan
$vdir = Join-Path $env:TEMP ('fvpn-http-verify-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $vdir | Out-Null
$httpNames = @(
  $bootName,
  $archiveName,
  ($archiveName + '.sha256'),
  ($archiveName + '.sig'),
  'family-vpn-panel-image.tar',
  'family-vpn-panel-image.tar.sha256',
  'bootstrap.sh', 'install.sh', 'install.sh.sig',
  'family-vpn-agent-linux-amd64', 'SHA256SUMS', 'release-signing.pub', 'INSTALL.txt', 'PANEL-UPDATE.txt'
)
foreach ($name in $httpNames) {
  $out = Join-Path $vdir $name
  & curl.exe -fsSL --max-time 180 ("https://" + $PanelHost + "/releases/" + $name) -o $out
  if ($LASTEXITCODE -ne 0) { throw "HTTP fetch failed for $name (exit $LASTEXITCODE)" }
  $len = (Get-Item -LiteralPath $out).Length
  if ($len -le 0) { throw "empty HTTP body for $name" }
  Write-Host ("HTTP 200  " + $name + "  (" + $len + " bytes)")
}

if ((Get-Sha256Lower (Join-Path $vdir $bootName)) -ne $ExpectedBootSha) {
  throw 'published panel-update-boot SHA mismatch'
}
if ((Get-Sha256Lower (Join-Path $vdir 'bootstrap.sh')) -ne $ExpectedBootstrapSha) {
  throw 'published bootstrap SHA mismatch'
}
if ((Get-Sha256Lower (Join-Path $vdir 'release-signing.pub')) -ne $ExpectedPubFp) {
  throw 'published release-signing.pub fingerprint mismatch'
}
Assert-Sha256File (Join-Path $vdir ($archiveName + '.sha256')) $vdir
Assert-Sha256File (Join-Path $vdir 'family-vpn-panel-image.tar.sha256') $vdir
Assert-Sha256File (Join-Path $vdir 'SHA256SUMS') $vdir
Assert-Ed25519 `
  (Join-Path $vdir $archiveName) `
  (Join-Path $vdir ($archiveName + '.sig')) `
  (Join-Path $vdir 'release-signing.pub') `
  $ExpectedPubFp
Assert-Ed25519 `
  (Join-Path $vdir 'install.sh') `
  (Join-Path $vdir 'install.sh.sig') `
  (Join-Path $vdir 'release-signing.pub') `
  $ExpectedPubFp

$publishedBundle = Get-TarText (Join-Path $vdir $archiveName) 'family-vpn-panel-update/BUNDLE-INFO.txt'
if ($publishedBundle -notmatch [regex]::Escape('image_digest=' + $ExpectedDigest)) {
  throw 'published update pack missing NEW digest'
}
if ($publishedBundle -match [regex]::Escape('image_digest=' + $OldDigest)) {
  throw 'published update pack still has OLD digest'
}

# Extra remote confirmation via SSH sha256sum (Linux), without PowerShell $(...) expansion.
$remoteShaCmd = 'sha256sum /tmp/fvpn-release-stage/bootstrap.sh /tmp/fvpn-release-stage/' + $bootName
$remoteShaOut = & ssh.exe @sshBase $sshTarget $remoteShaCmd 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "remote sha256sum failed: $remoteShaOut" }
if ($remoteShaOut -notmatch $ExpectedBootstrapSha) { throw "remote bootstrap sha256sum mismatch: $remoteShaOut" }
if ($remoteShaOut -notmatch $ExpectedBootSha) { throw "remote panel-update-boot sha256sum mismatch: $remoteShaOut" }
Write-Host 'Remote sha256sum (DE-01): OK' -ForegroundColor Green

$oneCmd = "curl -fsSL https://$PanelHost/releases/$bootName -o /tmp/fvpn-panel-boot.sh && echo '$ExpectedBootSha  /tmp/fvpn-panel-boot.sh' | sha256sum -c - && sudo bash /tmp/fvpn-panel-boot.sh"
Write-Host ''
Write-Host 'PUBLISH_OK' -ForegroundColor Green
Write-Host ("Published updater contains NEW image " + $ExpectedDigest + " (not " + $OldDigest + ")")
Write-Host 'Panel/agent NOT updated; services NOT restarted; SQLite/master.key/volumes untouched.'
Write-Host ''
Write-Host 'DE-01 update command:'
Write-Host $oneCmd
Write-Host ''
Write-Host 'NL-01 (separate, do not run with this fix):'
Write-Host ("curl -fsSL https://" + $PanelHost + "/releases/bootstrap.sh -o /tmp/fvpn-boot.sh && echo '" + $ExpectedBootstrapSha + "  /tmp/fvpn-boot.sh' | sha256sum -c - && sudo bash /tmp/fvpn-boot.sh --update")