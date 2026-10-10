<#
.SYNOPSIS
  Uninstalls the AI Proxy getting-started release and its namespace from the CURRENT kubectl
  context, and removes the sandbox certificates that -InstallCertLocally imported.
.EXAMPLE
  ./teardown.ps1
  ./teardown.ps1 -KeepLocalCerts        # leave imported certs in place
  ./teardown.ps1 -PurgeWork             # also delete the generated certs in .work\
#>
[CmdletBinding()]
param(
  [string]$Namespace = 'aiproxy-gs',
  [switch]$KeepLocalCerts,
  [switch]$PurgeWork
)

$ErrorActionPreference = 'Stop'
$workDir = Join-Path $PSScriptRoot '.work'

Write-Host "Context: $(kubectl config current-context)" -ForegroundColor Yellow
& helm uninstall aiproxy -n $Namespace
if ($LASTEXITCODE -ne 0) { Write-Host "  'helm uninstall' reported an error (already removed?)." -ForegroundColor DarkYellow }
# Deleting the namespace also removes the three Secrets deploy.ps1 created.
& kubectl delete namespace $Namespace --ignore-not-found --wait=true

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
  }
}

if ($PurgeWork) {
  Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Removed .work\." -ForegroundColor Green
}

Write-Host "Done." -ForegroundColor Green
