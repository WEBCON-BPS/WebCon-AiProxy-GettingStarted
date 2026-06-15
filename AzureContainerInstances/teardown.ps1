<#
.SYNOPSIS
  Deletes the AI Proxy getting-started sandbox resource group and removes the
  locally-installed sandbox certificates from the CurrentUser store.
.EXAMPLE
  ./teardown.ps1 -Suffix a1b2c3
#>
[CmdletBinding()]
param(
  [string]$SubscriptionId,
  [string]$Suffix,
  [string]$Location = 'polandcentral',
  [switch]$KeepLocalCerts
)

$ErrorActionPreference = 'Stop'

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
if (-not $Suffix) { $Suffix = $SubscriptionId.Replace('-','').Substring(0,6) }

$rg = "rg-aiproxy-gs-$Suffix"

Write-Host "Deleting resource group $rg ..." -ForegroundColor Yellow
az group delete -n $rg --yes --no-wait
Write-Host "Requested deletion of $rg (running in background)." -ForegroundColor Green

if (-not $KeepLocalCerts) {
  $fqdn = "aiproxy-gs-$Suffix.$Location.azurecontainer.io"
  foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\CurrentUser\Root') {
    Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like "*$fqdn*" } | ForEach-Object {
      Write-Host "Removing cert $($_.Thumbprint) from $store"
      Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host "Note: Key Vault and AI Foundry are soft-deleted. To free the names immediately:" -ForegroundColor DarkYellow
Write-Host "  az keyvault purge --name kvaipxgs$Suffix"
Write-Host "  az cognitiveservices account purge -g $rg -l $Location -n aif-aiproxy-gs-$Suffix  # only if -DeployFoundry was used"
