<#
.SYNOPSIS
  Installs a WEBCON AI Proxy sandbox (SelfHosted, NO Key Vault, OpenAI provider, mutual TLS)
  on the CURRENT kubectl context with the public Helm chart - Docker Desktop Kubernetes or AKS.

.DESCRIPTION
    1. Generate a self-signed cert (combined cert + PKCS#8 key PEM) -> .work\
       It is the HTTPS server cert, the mTLS trust anchor AND the JWT signing key.
    2. Create/refresh three Secrets in the namespace: TLS cert, Config UI key, OpenAI key.
    3. helm upgrade --install oci://registry-1.docker.io/webconbps/webcon-aiproxy (values.yaml).
    4. Wait for the LoadBalancer address and print the endpoint for the WEBCON Portal.
    5. Optionally import the certs locally and run an mTLS smoke test.

  The script never creates a cluster. Point kubectl at one first:
    Docker Desktop : Settings -> Kubernetes -> Enable Kubernetes; then 'kubectl config use-context docker-desktop'
    AKS            : az aks get-credentials -g <rg> -n <cluster>

  Prerequisites: kubectl, helm (v3.8+ for OCI charts), OpenSSL. No Azure CLI needed for the deploy itself.

.EXAMPLE
  ./deploy.ps1 -OpenAiApiKey "sk-..." -SmokeTest
  ./deploy.ps1 -OpenAiApiKey "sk-..." -InstallCertLocally -SmokeTest
#>
[CmdletBinding()]
param(
  [string]$OpenAiApiKey,                            # real OpenAI key (sk-...). Stored only in the aiproxy-provider-keys Secret.
  [string]$ImageTag = '2026.2.277.65',              # AI Proxy release; the chart version is derived from it (2026.2.277.65 -> 2026.2.277-65)
  [string]$ChartVersion,                            # explicit chart version override
  [string]$Namespace = 'aiproxy-gs',
  [string]$CertPassword = 'Sandbox!1',              # password for the exported client PFX (Portal upload)
  [string]$ClientId,                                # with -ClientSecret: authenticate the Portal by client id/secret instead of mTLS
  [string]$ClientSecret,
  [string]$ConfigAdminAccessKey,                    # Config UI login key; reused from the cluster, else auto-generated
  [switch]$InstallCertLocally,                      # import server cert -> CurrentUser\Root and client cert -> CurrentUser\My
  [switch]$SmokeTest                                # run mTLS tests after the pod is ready
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-Native { param([scriptblock]$Cmd) & $Cmd; if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Cmd" } }

$here    = $PSScriptRoot
$workDir = Join-Path $here '.work'
$release = 'aiproxy'
$chart   = 'oci://registry-1.docker.io/webconbps/webcon-aiproxy'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

foreach ($tool in 'kubectl', 'helm') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' was not found on PATH." }
}
$openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
if (-not $openssl) {
  $openssl = @(
    "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
    "$env:ProgramFiles\Git\usr\bin\openssl.exe",
    "${env:ProgramFiles(x86)}\Git\mingw64\bin\openssl.exe",
    "$env:LOCALAPPDATA\Programs\Git\mingw64\bin\openssl.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $openssl) { throw "'openssl' was not found on PATH or in a Git for Windows install. Install OpenSSL (or Git for Windows) and retry." }

$context = kubectl config current-context 2>$null
if ($LASTEXITCODE -ne 0 -or -not $context) { throw "No current kubectl context. Enable Kubernetes in Docker Desktop, or run 'az aks get-credentials'." }
if ([bool]$ClientId -ne [bool]$ClientSecret) { throw "Pass both -ClientId and -ClientSecret (or neither, for mTLS)." }
$useClientCredentials = [bool]$ClientId
if (-not $ChartVersion) { $ChartVersion = $ImageTag -replace '\.(\d+)$', '-$1' }

Write-Information "Context   : $context"
Write-Information "Namespace : $Namespace"
Write-Information "Chart     : $chart --version $ChartVersion  (image webconbps/aiproxy:$ImageTag)"

# --- 1. Self-signed cert (combined cert + PKCS#8 key PEM) --------------------
# The Portal checks the server cert by thumbprint only, so CN/SAN do not matter for it; localhost
# keeps browsers happy on Docker Desktop. serverAuth+clientAuth: the same cert is the client cert.
$certPem   = Join-Path $workDir 'certificate.pem'
$keyPem    = Join-Path $workDir 'key.pem'
$crtPem    = Join-Path $workDir 'cert.pem'
$clientPfx = Join-Path $workDir 'aiproxy-client.pfx'
$serverCer = Join-Path $workDir 'aiproxy-server.cer'

if ((Test-Path $certPem) -and (Test-Path $clientPfx)) {
  Write-Information "Reusing existing certificate in $workDir (delete .work\* to regenerate)."
} else {
  Write-Information "Generating self-signed cert (CN=localhost, PKCS#8 key)..."
  Invoke-Native {
    & $openssl req -x509 -newkey rsa:2048 -nodes -keyout $keyPem -out $crtPem -days 365 `
      -subj "/CN=localhost" `
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" `
      -addext "basicConstraints=critical,CA:FALSE" `
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" `
      -addext "extendedKeyUsage=serverAuth,clientAuth"
  }
  Get-Content $crtPem, $keyPem | Set-Content -Encoding ascii $certPem
  Invoke-Native { & $openssl pkcs12 -export -out $clientPfx -inkey $keyPem -in $crtPem -passout "pass:$CertPassword" }
}
if (-not (Test-Path $serverCer)) {
  Invoke-Native { & $openssl x509 -in $certPem -outform der -out $serverCer }
}
$cert       = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($clientPfx, $CertPassword)
$thumbprint = $cert.Thumbprint
Set-Content -Path (Join-Path $workDir 'thumbprint.txt') -Value $thumbprint -Encoding ascii

# --- 2. Secrets (create or update; values never touch values.yaml or Helm history) ---
kubectl get namespace $Namespace *> $null
if ($LASTEXITCODE -ne 0) { Invoke-Native { kubectl create namespace $Namespace | Out-Null } }

# Keep the Config UI key stable across re-runs unless one is passed explicitly.
$generatedAdminKey = $false
if ([string]::IsNullOrWhiteSpace($ConfigAdminAccessKey)) {
  $existing = kubectl get secret aiproxy-config-admin -n $Namespace -o jsonpath='{.data.ConfigAdmin__AccessKey}' 2>$null
  if ($LASTEXITCODE -eq 0 -and $existing) {
    $ConfigAdminAccessKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing))
  } else {
    $ConfigAdminAccessKey = [guid]::NewGuid().ToString('N'); $generatedAdminKey = $true
  }
}
# Same for the OpenAI key: a re-run without -OpenAiApiKey keeps the one already in the cluster.
if ([string]::IsNullOrWhiteSpace($OpenAiApiKey)) {
  $existing = kubectl get secret aiproxy-provider-keys -n $Namespace -o jsonpath='{.data.ProviderConnections__OpenAi__ProviderConfiguration__ApiKey}' 2>$null
  if ($LASTEXITCODE -eq 0 -and $existing) {
    $OpenAiApiKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing))
  } else {
    Write-Warning "No -OpenAiApiKey supplied. The proxy starts, but AI calls fail until you re-run with a key."
    $OpenAiApiKey = ''
  }
}

function Set-Secret { param([string]$Name, [string[]]$KubectlArgs)
  # 'create --dry-run | apply' = idempotent create-or-update
  $yaml = kubectl create secret generic $Name -n $Namespace @KubectlArgs --dry-run=client -o yaml
  if ($LASTEXITCODE -ne 0) { throw "Rendering secret $Name failed." }
  $yaml | kubectl apply -f - | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Applying secret $Name failed." }
}
Set-Secret aiproxy-tls           @("--from-file=tls.pem=$certPem")
Set-Secret aiproxy-config-admin  @("--from-literal=ConfigAdmin__AccessKey=$ConfigAdminAccessKey")
Set-Secret aiproxy-provider-keys @("--from-literal=ProviderConnections__OpenAi__ProviderConfiguration__ApiKey=$OpenAiApiKey")

# Portal auth mode. mTLS is the values.yaml default; client credentials override it here so the
# secret lands in a Secret (aiproxy-client-credentials), never in values or Helm history.
$authArgs = @()
if ($useClientCredentials) {
  Set-Secret aiproxy-client-credentials @("--from-literal=AppConfiguration__SelfHosted__ClientSecret=$ClientSecret")
  $authArgs = @(
    '--set', 'selfHosted.requireClientCertificate=false',
    '--set-string', "selfHosted.clientId=$ClientId",
    '--set', 'secrets.appSettings.source=existingSecret',
    '--set', 'secrets.appSettings.existingSecretName=aiproxy-client-credentials',
    '--set', 'secrets.appSettings.entries[0].configKey=AppConfiguration__SelfHosted__ClientSecret'
  )
}

# --- 3. Helm ------------------------------------------------------------------
helm status $release -n $Namespace *> $null
$isUpgrade = $LASTEXITCODE -eq 0
Write-Information "helm upgrade --install (pulls the chart from Docker Hub)..."
Invoke-Native { helm upgrade --install $release $chart --version $ChartVersion -n $Namespace -f (Join-Path $here 'values.yaml') @authArgs }
# Secrets are read as env vars at pod start - restart so a changed key/cert is picked up.
# (Persistence is off, so this also resets any Config UI edits to values.yaml.)
if ($isUpgrade) { Invoke-Native { kubectl rollout restart deployment/webcon-aiproxy -n $Namespace | Out-Null } }
Invoke-Native { kubectl rollout status deployment/webcon-aiproxy -n $Namespace --timeout=300s }

# --- 4. LoadBalancer address (Docker Desktop: localhost; AKS: public IP) ------
Write-Information "Waiting for the LoadBalancer address..."
$address = $null
for ($i = 1; $i -le 60 -and -not $address; $i++) {
  $address = kubectl get svc webcon-aiproxy -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>$null
  if (-not $address) { Start-Sleep -Seconds 5 }
}
if (-not $address) { throw "The Service got no LoadBalancer address. Check: kubectl get svc -n $Namespace" }
$endpoint = "https://$($address):8081"

# --- 5. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "==================== DONE ====================" -ForegroundColor Green
Write-Host "Endpoint (Portal -> AI Proxy SelfHosted Url): $endpoint"
Write-Host "Health (no client cert needed)               : $endpoint/health"
Write-Host "Cert thumbprint (must match in Portal)      : $thumbprint"
Write-Host "Client cert for Portal upload               : $clientPfx  (password: $CertPassword)"
Write-Host "                                              $certPem  (PEM with private key)"
Write-Host "Config UI (browser)                         : $endpoint/config-ui"
Write-Host ("  access key$(if($generatedAdminKey){' (auto-generated - save it!)'}else{''}): $ConfigAdminAccessKey") -ForegroundColor $(if($generatedAdminKey){'Yellow'}else{'Gray'})
Write-Host "  (dismiss the client-cert prompt - /config-ui does not need it. UI edits last until the pod restarts.)"
Write-Host ""
Write-Host "WEBCON Portal (Studio) configuration:" -ForegroundColor Cyan
Write-Host "  1. AI mode: SelfHosted AI Proxy."
Write-Host "  2. AI Proxy Url: $endpoint   (no trailing slash)"
if ($useClientCredentials) {
  Write-Host "  3. Portal auth: client id/secret (no client cert). ClientId = $ClientId"
} else {
  Write-Host "  3. Upload the cert WITH private key (PFX + password above, or the PEM)."
}
Write-Host "  4. Restart WEBCON Service (Windows service) + Portal (IIS)."
Write-Host ""
Write-Host "Logs : kubectl logs -n $Namespace deploy/webcon-aiproxy -f"
Write-Host "Stop : ./teardown.ps1" -ForegroundColor Yellow
Write-Host ""

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
}

if ($SmokeTest) {
  # Cert loaded in PowerShell and passed in, so the helper compiles on 5.1 and 7.
  # /health needs no client cert; /token proves the Portal auth mode end to end.
  $refs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @{ ReferencedAssemblies = 'System.Net.Http' } } else { @{} }
  if (-not ('AiProxyCheck' -as [type])) { Add-Type @refs -TypeDefinition @'
using System; using System.Collections.Generic; using System.Net.Http; using System.Security.Cryptography.X509Certificates;
public static class AiProxyCheck {
  // form == null -> GET; otherwise POST (form-urlencoded) with the ConfigDbGuid header the /token endpoint requires.
  public static string Send(string url, X509Certificate2 cert, Dictionary<string,string> form) {
    var h = new HttpClientHandler();
    h.ServerCertificateCustomValidationCallback = (m,c,ch,e) => true;
    if (cert != null) h.ClientCertificates.Add(cert);
    using (var cl = new HttpClient(h)) {
      cl.Timeout = TimeSpan.FromSeconds(25);
      try {
        HttpResponseMessage r;
        if (form == null) r = cl.GetAsync(url).GetAwaiter().GetResult();
        else {
          var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = new FormUrlEncodedContent(form) };
          req.Headers.Add("ConfigDbGuid", Guid.NewGuid().ToString());
          r = cl.SendAsync(req).GetAwaiter().GetResult();
        }
        var body = r.Content.ReadAsStringAsync().GetAwaiter().GetResult();
        return "HTTP " + ((int)r.StatusCode) + ": " + (body.Length > 120 ? body.Substring(0, 120) + "..." : body);
      } catch (Exception ex) { var e = ex; while (e.InnerException != null) e = e.InnerException; return "ERR: " + e.Message; }
    }
  }
}
'@ }

  Write-Host "Smoke test..." -ForegroundColor Cyan
  for ($i = 1; $i -le 20; $i++) {
    $res = [AiProxyCheck]::Send("$endpoint/health", $null, $null)
    Write-Host "  /health, attempt $i -> $res"
    if ($res -like 'HTTP 200*') { break }
    Start-Sleep -Seconds 6
  }
  $form = { param($id, $secret) $d = [System.Collections.Generic.Dictionary[string,string]]::new(); $d['grant_type'] = 'client_credentials'; $d['client_id'] = $id; $d['client_secret'] = $secret; $d }
  if ($useClientCredentials) {
    Write-Host "  /token, wrong secret, no cert -> $([AiProxyCheck]::Send("$endpoint/token", $null, (& $form $ClientId 'wrong')))  (expected: HTTP 401)"
    Write-Host "  /token, ClientId/Secret, no cert -> $([AiProxyCheck]::Send("$endpoint/token", $null, (& $form $ClientId $ClientSecret)))  (expected: HTTP 200 + access_token)"
  } else {
    Write-Host "  /token without cert -> $([AiProxyCheck]::Send("$endpoint/token", $null, (& $form 'x' 'x')))  (expected: HTTP 401 - mTLS enforced)"
    Write-Host "  /token with cert    -> $([AiProxyCheck]::Send("$endpoint/token", $cert, (& $form 'x' 'x')))  (expected: HTTP 200 + access_token - cert accepted)"
  }
}
