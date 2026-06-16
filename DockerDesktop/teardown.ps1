<#
.SYNOPSIS
  Stops and removes the local AI Proxy getting-started container, and removes the
  sandbox certificates that -InstallCertLocally imported into the CurrentUser store.
.EXAMPLE
  ./teardown.ps1
  ./teardown.ps1 -KeepLocalCerts        # leave imported certs in place
  ./teardown.ps1 -PurgeWork             # also delete generated certs, .env and rendered config
#>
[CmdletBinding()]
param(
  [switch]$KeepLocalCerts,   # do not remove the imported sandbox certs from CurrentUser
  [switch]$PurgeWork         # also delete .work\ (certs + rendered aiconfiguration) and .env
)

$ErrorActionPreference = 'Stop'

$here    = $PSScriptRoot
$workDir = Join-Path $here '.work'
$compose = Join-Path $here 'docker-compose.yml'

# docker compose down needs the same substitution vars the file references; supply harmless
# defaults so 'down' never fails just because .env is gone.
if (-not $env:AIPROXY_IMAGE)           { $env:AIPROXY_IMAGE = 'webconbps/aiproxy:2026.2.64.17' }
if (-not $env:CONFIG_ADMIN_ACCESS_KEY) { $env:CONFIG_ADMIN_ACCESS_KEY = 'teardown' }

Write-Host "Stopping and removing the container (docker compose down)..." -ForegroundColor Yellow
& docker compose -f $compose down
if ($LASTEXITCODE -ne 0) { Write-Host "  'docker compose down' reported an error (already removed?)." -ForegroundColor DarkYellow }

if (-not $KeepLocalCerts) {
  $tpFile = Join-Path $workDir 'thumbprint.txt'
  if (Test-Path $tpFile) {
    $tp = (Get-Content $tpFile -Raw).Trim()
    foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\CurrentUser\Root') {
      Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $tp } | ForEach-Object {
        Write-Host "Removing cert $($_.Thumbprint) from $store"
        Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
      }
    }
  } else {
    Write-Host "No .work\thumbprint.txt found - skipping local cert cleanup." -ForegroundColor DarkYellow
  }
}

if ($PurgeWork) {
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $here '.env') -Force -ErrorAction SilentlyContinue
  Write-Host "Removed .work\ and .env." -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Green
