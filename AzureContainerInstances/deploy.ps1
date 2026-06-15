<#
.SYNOPSIS
  Stands up an AI Proxy sandbox on Azure Container Instance (SelfHosted + Key Vault + mTLS)
  in a dedicated, disposable resource group on your subscription.

.DESCRIPTION
  Steps:
    1. Resource group
    2. Pull the public Docker Hub image webconbps/aiproxy:<tag> + bake aiconfiguration.json onto it
    3. Deploy infra.bicep (ACR + Managed Identity + Key Vault + role assignments)
    4. Push the image to the new ACR
    5. Generate a self-signed cert (PKCS#8 PEM) and seed Key Vault (cert/signing key + provider secrets)
    6. Deploy aci.bicep (the container)
    7. Print the endpoint + thumbprint + what to configure in the WEBCON Portal

  Prerequisites: az CLI (logged in), Docker, openssl. No source build / SDK needed.

.EXAMPLE
  # Default image (webconbps/aiproxy:2026.2.64.17), mTLS/Portal test, install certs locally:
  ./deploy.ps1 -SmokeTest -InstallCertLocally

  # Pin a different tag + a working AzureAi provider (remember to match the aiconfiguration schema):
  ./deploy.ps1 -ImageTag "2026.1.27.108" `
               -AzureAiEndpoint "https://my-res.openai.azure.com/openai/v1/" -AzureAiApiKey "..." -SmokeTest
#>
[CmdletBinding()]
param(
  [string]$SubscriptionId,
  [string]$Location = 'polandcentral',
  [string]$Suffix,                                  # short unique token; defaults to subscription-derived
  [string]$AzureAiEndpoint,                         # optional; seeded into KV as AiAzureEndpoint (e.g. https://<res>.openai.azure.com/openai/v1/)
  [string]$AzureAiApiKey,                           # optional; seeded into KV as AiAzureApiKey
  [string]$CertPassword = 'Sandbox!1',              # password for the exported client PFX (Portal upload)
  [string]$ConfigAdminAccessKey = 'sandbox-admin',  # login key for the config UI (/config-ui)
  [string]$ImageTag = '2026.2.64.17',               # tag of the public Docker Hub image webconbps/aiproxy (pick one matching your aiconfiguration schema)
  [string]$Image,                                   # full image ref override (any registry/tag); takes precedence over -ImageTag
  [switch]$DeployFoundry,                           # also create an AI Foundry + project + models, locked to the container's IP, and wire AiAzure* secrets
  [string]$FoundryLocation = 'swedencentral',       # region for the AI Foundry account (must offer the chosen models)
  [switch]$InstallCertLocally,                      # import server cert -> CurrentUser\Root and client cert -> CurrentUser\My (UI testing)
  [switch]$SmokeTest                                # run mTLS tests after deploy
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-Native { param([scriptblock]$Cmd) & $Cmd; if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Cmd" } }

# --- Resolve paths / context -------------------------------------------------
$here     = $PSScriptRoot
$workDir  = Join-Path $here '.work'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
if ($LASTEXITCODE -ne 0 -or -not $SubscriptionId) { throw "Not logged into az. Run 'az login' first." }
Invoke-Native { az account set --subscription $SubscriptionId }

if (-not $Suffix) { $Suffix = $SubscriptionId.Replace('-','').Substring(0,6) }

# --- Names (deterministic per subscription+suffix) ---------------------------
$rg          = "rg-aiproxy-gs-$Suffix"
$acrName     = "craipxgs$Suffix"
$miName      = "mi-aiproxy-gs-$Suffix"
$kvName      = "kvaipxgs$Suffix"
$aciName     = "aci-aiproxy-gs-$Suffix"
$dnsLabel    = "aiproxy-gs-$Suffix"
$fqdn        = "$dnsLabel.$Location.azurecontainer.io"
$acrTag      = 'gs'   # tag used when re-pushing to the new ACR (distinct from -ImageTag / Docker Hub)
$foundryName = "aif-aiproxy-gs-$Suffix"   # AIServices account + custom subdomain (globally unique)
$foundryProj = "aifp-gs-$Suffix"

Write-Information "Subscription : $SubscriptionId"
Write-Information "Resource grp : $rg ($Location)"
Write-Information "ACR / KV / MI: $acrName / $kvName / $miName"
Write-Information "Endpoint     : https://$fqdn`:8081"

# --- 1. Resource group -------------------------------------------------------
Invoke-Native { az group create -n $rg -l $Location --tags purpose=aiproxy-getting-started disposable=true | Out-Null }

# --- 2. Pull the base image (public Docker Hub) ------------------------------
# Default: webconbps/aiproxy:<ImageTag> from Docker Hub (no login needed for public pulls).
# Override the whole reference with -Image if you mirror it elsewhere.
$baseImage = if ($Image) { $Image } else { "webconbps/aiproxy:$ImageTag" }
Write-Information "Pulling base image: $baseImage"
Invoke-Native { docker pull $baseImage }

$localFinal = "aiproxy-gs:local"
Write-Information "Baking aiconfiguration.json onto $baseImage -> $localFinal"
Write-Information "  (make sure aiconfiguration.json matches the image's schema - see README: 2026.1 vs 2026.2)"
Invoke-Native { docker build --build-arg BASE_IMAGE=$baseImage -f (Join-Path $here 'config/Dockerfile.config') -t $localFinal (Join-Path $here 'config') }

# --- 3. infra.bicep ----------------------------------------------------------
$deployerObjectId = az ad signed-in-user show --query id -o tsv
if ($LASTEXITCODE -ne 0 -or -not $deployerObjectId) { throw "Could not resolve signed-in user object id." }

Write-Information "Deploying infra.bicep (ACR + MI + Key Vault + roles)..."
Invoke-Native {
  az deployment group create -g $rg -n infra-aiproxy-gs `
    --template-file (Join-Path $here 'bicep/infra.bicep') `
    --parameters parAcrName=$acrName parMiName=$miName parKvName=$kvName `
                 parDeployerObjectId=$deployerObjectId parLocation=$Location | Out-Null
}

$outQ = { param($n) az deployment group show -g $rg -n infra-aiproxy-gs --query "properties.outputs.$n.value" -o tsv }
$acrLoginServer = & $outQ 'outAcrLoginServer'
$miId           = & $outQ 'outMiId'
$miClientId     = & $outQ 'outMiClientId'
$miPrincipalId  = & $outQ 'outMiPrincipalId'
$kvUri          = & $outQ 'outKvUri'

# --- 4. Push image to ACR ----------------------------------------------------
$acrImage = "$acrLoginServer/webcon/aiproxy:$acrTag"
Write-Information "Pushing image to $acrImage"
Invoke-Native { az acr login --name $acrName }
Invoke-Native { docker tag $localFinal $acrImage }
Invoke-Native { docker push $acrImage }

# --- 5. Cert (PKCS#8 PEM!) + seed Key Vault ----------------------------------
# CredentialsHelper reads the signing-key secret via BouncyCastle, which only accepts
# a PKCS#8 ("BEGIN PRIVATE KEY") RSA key. 'openssl req -newkey -nodes' emits PKCS#8.
$certPem   = Join-Path $workDir 'certificate.pem'   # combined cert + key (TLS + signing + Portal client cert)
$keyPem    = Join-Path $workDir 'key.pem'
$crtPem    = Join-Path $workDir 'cert.pem'
$clientPfx = Join-Path $workDir 'aiproxy-client.pfx' # cert + private key -> CurrentUser\My (client auth) / Portal upload
$serverCer = Join-Path $workDir 'aiproxy-server.cer' # public cert (DER) -> CurrentUser\Root (trust the self-signed server)

if ((Test-Path $certPem) -and (Test-Path $clientPfx)) {
  Write-Information "Reusing existing certificate in $workDir (delete .work\* to regenerate)."
} else {
  Write-Information "Generating self-signed cert (CN=$fqdn, PKCS#8 key)..."
  Invoke-Native {
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $keyPem -out $crtPem -days 365 `
      -subj "/CN=$fqdn" -addext "subjectAltName=DNS:$fqdn,DNS:localhost"
  }
  Get-Content $crtPem, $keyPem | Set-Content -Encoding ascii $certPem
  Invoke-Native { openssl pkcs12 -export -out $clientPfx -inkey $keyPem -in $crtPem -passout "pass:$CertPassword" }
}

# Public DER cert for local Trusted-Root install (derive from the combined PEM if missing)
if (-not (Test-Path $serverCer)) {
  Invoke-Native { openssl x509 -in $certPem -outform der -out $serverCer }
}

$thumbprint = ([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($clientPfx, $CertPassword)).Thumbprint

# Seed KV (retry: RBAC data-plane role can take a minute to propagate)
function Set-KvSecret { param($name, $file, $value)
  for ($i = 1; $i -le 10; $i++) {
    if ($file) { az keyvault secret set --vault-name $kvName --name $name --file $file --encoding utf-8 -o none 2>$null }
    else       { az keyvault secret set --vault-name $kvName --name $name --value $value -o none 2>$null }
    if ($LASTEXITCODE -eq 0) { Write-Information "  KV secret '$name' set."; return }
    Write-Information "  waiting for KV RBAC propagation ($i/10)..."; Start-Sleep -Seconds 15
  }
  throw "Failed to set KV secret '$name' (RBAC not propagated or no permission)."
}
Set-KvSecret -name 'aiproxy-certificate-pem' -file $certPem

# Provider (AzureAi) - AiAzureEndpoint / AiAzureApiKey are referenced BY NAME in aiconfiguration.json
# and read by the MI at runtime. Three ways to populate them:
if ($DeployFoundry) {
  Write-Information "Deploying foundry.bicep (AI Foundry + project + models)... this can take a few minutes."
  Invoke-Native {
    az deployment group create -g $rg -n foundry-aiproxy-gs `
      --template-file (Join-Path $here 'bicep/foundry.bicep') `
      --parameters parAccountName=$foundryName parProjectName=$foundryProj parKvName=$kvName `
                   parMiPrincipalId=$miPrincipalId parLocation=$FoundryLocation | Out-Null
  }
  # foundry.bicep writes AiAzureEndpoint + AiAzureApiKey into KV itself.
} elseif ($AzureAiEndpoint -and $AzureAiApiKey) {
  Set-KvSecret -name 'AiAzureEndpoint' -value $AzureAiEndpoint
  Set-KvSecret -name 'AiAzureApiKey' -value $AzureAiApiKey
} else {
  Write-Information "  Skipping AzureAi provider secrets - use -DeployFoundry, or set them in KV before AI calls will work:"
  Write-Information "    az keyvault secret set --vault-name $kvName --name AiAzureEndpoint --value `"https://<resource>.openai.azure.com/openai/v1/`""
  Write-Information "    az keyvault secret set --vault-name $kvName --name AiAzureApiKey  --value `"<azure-api-key>`""
}

# --- 6. aci.bicep ------------------------------------------------------------
$certB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($certPem))
Write-Information "Deploying aci.bicep (container)..."
Invoke-Native {
  az deployment group create -g $rg -n aci-aiproxy-gs `
    --template-file (Join-Path $here 'bicep/aci.bicep') `
    --parameters parAciName=$aciName parImage=$acrImage parAcrLoginServer=$acrLoginServer `
                 parMiId=$miId parMiClientId=$miClientId parKvUri=$kvUri `
                 parDnsNameLabel=$dnsLabel parLocation=$Location parCertPemBase64=$certB64 `
                 parConfigAdminAccessKey=$ConfigAdminAccessKey | Out-Null
}
$endpoint = az deployment group show -g $rg -n aci-aiproxy-gs --query "properties.outputs.outEndpoint.value" -o tsv

# --- 6b. Lock Foundry to the container's IP ----------------------------------
# An ACI's egress IP equals its inbound public IP (ipAddress.ip) and is stable across restarts,
# so allow-listing it makes the Deny-by-default Foundry reachable only from the container.
# NOTE: the rule can take ~10-30 min to fully propagate - AI calls may 403 until it settles.
if ($DeployFoundry) {
  $aciIp = az container show -g $rg -n $aciName --query "ipAddress.ip" -o tsv
  Write-Information "Allowing container IP $aciIp on Foundry $foundryName (Deny-by-default; firewall may take minutes to settle)..."
  Invoke-Native { az cognitiveservices account network-rule add -g $rg -n $foundryName --ip-address $aciIp -o none }
}

# --- 7. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "==================== DONE ====================" -ForegroundColor Green
Write-Host "Endpoint (Portal -> AI Proxy SelfHosted Url): $endpoint"
Write-Host "Health (with client cert)                   : $endpoint/health"
Write-Host "Cert thumbprint (must match in Portal)      : $thumbprint"
Write-Host "Client cert for Portal upload               : $clientPfx  (password: $CertPassword)"
Write-Host "                                              $certPem  (PEM with private key)"
Write-Host "Config UI (browser)                         : $endpoint/config-ui   (access key: $ConfigAdminAccessKey)"
Write-Host ""
Write-Host "WEBCON Portal (Studio) configuration:" -ForegroundColor Cyan
Write-Host "  1. AI mode: SelfHosted AI Proxy (global param UseAITokenLicense)."
Write-Host "  2. AI Proxy Url: $endpoint   (no trailing slash)"
Write-Host "  3. Upload the cert WITH private key (PFX + password above, or the PEM)."
Write-Host "  4. Restart WEBCON Service (Windows service) + Portal (IIS)."
Write-Host ""
Write-Host "AzureAi provider (KV secrets, referenced by name in aiconfiguration.json):" -ForegroundColor Cyan
if ($DeployFoundry) {
  Write-Host "  AI Foundry '$foundryName' ($FoundryLocation) deployed; AiAzureEndpoint / AiAzureApiKey seeded into $kvName"
  Write-Host "  Foundry firewall: Deny-by-default, allowed only from the container IP ($aciIp). Portal cannot reach it."
  Write-Host "  Models deployed: gpt-4o-mini, text-embedding-3-small"
  Write-Host "  IMPORTANT: the CogSvc firewall rule can take ~10-30 min to fully propagate - AI calls may"
  Write-Host "             return 403 'Virtual Network/Firewall rules' until it settles. This is expected."
} elseif ($AzureAiEndpoint -and $AzureAiApiKey) {
  Write-Host "  AiAzureEndpoint / AiAzureApiKey  -> seeded into $kvName"
} else {
  Write-Host "  NOT set. Use -DeployFoundry, or set them in $kvName :"
  Write-Host "    az keyvault secret set --vault-name $kvName --name AiAzureEndpoint --value `"https://<resource>.openai.azure.com/openai/v1/`""
  Write-Host "    az keyvault secret set --vault-name $kvName --name AiAzureApiKey  --value `"<azure-api-key>`""
  Write-Host "  (the container starts fine without them; only AI calls need them)"
}
Write-Host ""

# --- Local cert install (test the whole flow from the browser / UI) ----------
# Non-fatal: a failure here must not abort the deploy or the smoke test. Importing into
# CurrentUser\Root shows an OS trust prompt and fails in a non-interactive session
# ("UI is not allowed in this operation") - run that part from an interactive terminal.
if ($InstallCertLocally) {
  Write-Host "Installing certs into CurrentUser store (UI testing)..." -ForegroundColor Cyan
  try {
    $sec = ConvertTo-SecureString $CertPassword -AsPlainText -Force
    Import-PfxCertificate -FilePath $clientPfx -CertStoreLocation Cert:\CurrentUser\My -Password $sec -ErrorAction Stop | Out-Null
    Write-Host "  client cert -> CurrentUser\My  (thumbprint $thumbprint)" -ForegroundColor Green
  } catch { Write-Host "  client cert install failed: $($_.Exception.Message)" -ForegroundColor Yellow }
  try {
    Import-Certificate -FilePath $serverCer -CertStoreLocation Cert:\CurrentUser\Root -ErrorAction Stop | Out-Null
    Write-Host "  server cert -> CurrentUser\Root (TLS trust)" -ForegroundColor Green
  } catch {
    Write-Host "  server cert -> CurrentUser\Root SKIPPED (needs an interactive terminal to confirm the trust prompt)." -ForegroundColor Yellow
    Write-Host "    Run in your own PowerShell window: Import-Certificate -FilePath '$serverCer' -CertStoreLocation Cert:\CurrentUser\Root" -ForegroundColor Yellow
  }
  Write-Host "  Open $endpoint in a browser and pick this client cert when prompted to test mTLS via UI."
} else {
  Write-Host "To test from the browser/UI on this machine, install the certs:" -ForegroundColor DarkCyan
  Write-Host "  re-run with -InstallCertLocally, or manually:"
  Write-Host "    Import-Certificate -FilePath '$serverCer' -CertStoreLocation Cert:\CurrentUser\Root"
  Write-Host "    Import-PfxCertificate -FilePath '$clientPfx' -CertStoreLocation Cert:\CurrentUser\My -Password (ConvertTo-SecureString '$CertPassword' -AsPlainText -Force)"
}
Write-Host ""

if ($SmokeTest) {
  # mTLS test via a tiny C# helper. A PowerShell scriptblock used as the validation callback
  # fails on background threads in Windows PowerShell 5.1 ("no Runspace available"); a C# lambda
  # does not - and this mirrors exactly what the WEBCON Portal (also C#) does.
  $csharp = @'
using System; using System.Net.Http; using System.Security.Cryptography.X509Certificates;
public static class AiProxySmoke {
  public static string Health(string url, string pfx, string pwd, bool withCert) {
    var h = new HttpClientHandler();
    h.ServerCertificateCustomValidationCallback = (m,c,ch,e) => true;
    if (withCert) h.ClientCertificates.Add(new X509Certificate2(pfx, pwd));
    using (var cl = new HttpClient(h)) {
      cl.Timeout = TimeSpan.FromSeconds(25);
      try {
        var r = cl.GetAsync(url).GetAwaiter().GetResult();
        return "HTTP " + ((int)r.StatusCode) + ": " + r.Content.ReadAsStringAsync().GetAwaiter().GetResult();
      } catch (Exception ex) { var e = ex; while (e.InnerException != null) e = e.InnerException; return "ERR: " + e.Message; }
    }
  }
}
'@
  if (-not ('AiProxySmoke' -as [type])) { Add-Type -TypeDefinition $csharp -ReferencedAssemblies System.Net.Http }
  $healthUrl = "https://$fqdn`:8081/health"

  Write-Host "Smoke test (waiting for container to come up)..." -ForegroundColor Cyan
  for ($i = 1; $i -le 20; $i++) {
    $res = [AiProxySmoke]::Health($healthUrl, $clientPfx, $CertPassword, $true)
    Write-Host "  with cert, attempt $i -> $res"
    if ($res -like 'HTTP 200*') { break }
    Start-Sleep -Seconds 15
  }
  Write-Host "  without cert         -> $([AiProxySmoke]::Health($healthUrl, $clientPfx, $CertPassword, $false))  (expected: connection rejected)"

  # What cert does the endpoint actually serve? (detects a TLS-terminating proxy / wrong cert)
  try {
    $tcp = [System.Net.Sockets.TcpClient]::new($fqdn, 8081)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, ({ $true }))
    $ssl.AuthenticateAsClient($fqdn)
    $served = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
    Write-Host "  served cert thumbprint: $($served.Thumbprint)" -ForegroundColor $(if ($served.Thumbprint -eq $thumbprint) { 'Green' } else { 'Red' })
    Write-Host "  expected (uploaded)   : $thumbprint"
    $ssl.Dispose(); $tcp.Dispose()
  } catch { Write-Host "  could not read served cert: $($_.Exception.Message)" }
}

Write-Host "Tear down with: ./teardown.ps1 -Suffix $Suffix" -ForegroundColor Yellow
