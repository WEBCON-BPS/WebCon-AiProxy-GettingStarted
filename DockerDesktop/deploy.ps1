<#
.SYNOPSIS
  Stands up a WEBCON AI Proxy sandbox on local Docker Desktop
  (SelfHosted, NO Azure Key Vault, OpenAI provider, mutual TLS) with one command.

.DESCRIPTION
  No Azure account, no Key Vault, no cloud. Everything runs locally:
    1. Generate a self-signed cert (combined cert + PKCS#8 key PEM) -> .work\
       It is used BOTH as the TLS server cert AND as the JWT signing key.
    2. Render aiconfiguration.json with your real OpenAI key -> .work\ (git-ignored).
       With Key Vault disabled, the proxy reads the key value literally from this file.
    3. Write .env (image tag + random Config UI key + ports).
    4. docker compose up -d  (pulls the public image webconbps/aiproxy).
    5. Optionally import the certs locally and run an mTLS smoke test.

  Prerequisites: Docker Desktop (running) and OpenSSL. No Azure CLI / .NET SDK needed.

.EXAMPLE
  # Connect to OpenAI and run the mTLS smoke test:
  ./deploy.ps1 -OpenAiApiKey "sk-..." -SmokeTest

  # Also import the sandbox certs so a browser / local Portal trusts the endpoint:
  ./deploy.ps1 -OpenAiApiKey "sk-..." -InstallCertLocally -SmokeTest

  # Start without a key now (set it later: edit .work\aiconfiguration.json, then docker compose restart):
  ./deploy.ps1
#>
[CmdletBinding()]
param(
  [string]$OpenAiApiKey,                            # real OpenAI key (sk-...). Written into .work\aiconfiguration.json, never committed.
  [string]$Model = 'gpt-4o-mini',                   # OpenAI text/image model id (replaces the default gpt-4o-mini in the template)
  [string]$EmbeddingModel = 'text-embedding-3-small', # OpenAI embedding model id
  [string]$ImageTag = '2026.2.64.17',               # tag of the public Docker Hub image webconbps/aiproxy (match the aiconfiguration schema)
  [string]$Image,                                   # full image ref override (any registry/tag); takes precedence over -ImageTag
  [string]$CertPassword = 'Sandbox!1',              # password for the exported client PFX (Portal upload)
  [string]$ConfigAdminAccessKey,                    # login key for the Config UI; auto-generated (strong) if not supplied
  [int]$HttpsPort = 7033,                            # host port -> container 8081 (HTTPS / mTLS; the Portal endpoint)
  [int]$HttpPort  = 5298,                            # host port -> container 8080 (plain HTTP; redirects to HTTPS, kept for the future Config UI)
  [switch]$InstallCertLocally,                      # import server cert -> CurrentUser\Root and client cert -> CurrentUser\My (UI testing)
  [switch]$SmokeTest                                # run mTLS tests after the container starts
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-Native { param([scriptblock]$Cmd) & $Cmd; if ($LASTEXITCODE -ne 0) { throw "Command failed (exit $LASTEXITCODE): $Cmd" } }

# --- Resolve paths / context -------------------------------------------------
$here    = $PSScriptRoot
$workDir = Join-Path $here '.work'
$compose = Join-Path $here 'docker-compose.yml'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

foreach ($tool in 'docker', 'openssl') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' was not found on PATH. Install it and retry." }
}
# 'docker compose' (v2) must be available
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw "'docker compose' (Compose v2) is not available. Update Docker Desktop." }

$image    = if ($Image) { $Image } else { "webconbps/aiproxy:$ImageTag" }
$endpoint = "https://localhost:$HttpsPort"

# Config UI admin key: never ship a known default - generate a strong random one unless supplied.
$generatedAdminKey = [string]::IsNullOrWhiteSpace($ConfigAdminAccessKey)
if ($generatedAdminKey) { $ConfigAdminAccessKey = [guid]::NewGuid().ToString('N') }

Write-Information "Image        : $image"
Write-Information "Endpoint     : $endpoint   (mTLS)"
Write-Information "HTTP (local) : http://localhost:$HttpPort   (redirects to HTTPS; web Config UI ships in a later image)"

# --- 1. Self-signed cert (combined cert + PKCS#8 key PEM) --------------------
# CredentialsHelper reads the JWT signing key from this PEM via BouncyCastle, which only
# accepts a PKCS#8 ("BEGIN PRIVATE KEY") RSA key. 'openssl req -newkey -nodes' emits PKCS#8.
# The same cert is served for TLS, so the Portal's uploaded client cert must match it exactly.
$certPem   = Join-Path $workDir 'certificate.pem'    # combined cert + key (TLS + JWT signing + Portal client cert)
$keyPem    = Join-Path $workDir 'key.pem'
$crtPem    = Join-Path $workDir 'cert.pem'
$clientPfx = Join-Path $workDir 'aiproxy-client.pfx' # cert + private key -> CurrentUser\My / Portal upload
$serverCer = Join-Path $workDir 'aiproxy-server.cer' # public cert (DER) -> CurrentUser\Root (trust the self-signed server)

if ((Test-Path $certPem) -and (Test-Path $clientPfx)) {
  Write-Information "Reusing existing certificate in $workDir (delete .work\* to regenerate)."
} else {
  Write-Information "Generating self-signed cert (CN=localhost, PKCS#8 key)..."
  # serverAuth+clientAuth EKU: the same cert is used as the TLS server cert AND as the
  # client cert; without clientAuth, Windows/Edge may not offer it in the cert picker.
  Invoke-Native {
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $keyPem -out $crtPem -days 365 `
      -subj "/CN=localhost" `
      -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" `
      -addext "basicConstraints=critical,CA:FALSE" `
      -addext "keyUsage=critical,digitalSignature,keyEncipherment" `
      -addext "extendedKeyUsage=serverAuth,clientAuth"
  }
  Get-Content $crtPem, $keyPem | Set-Content -Encoding ascii $certPem
  Invoke-Native { openssl pkcs12 -export -out $clientPfx -inkey $keyPem -in $crtPem -passout "pass:$CertPassword" }
}
if (-not (Test-Path $serverCer)) {
  Invoke-Native { openssl x509 -in $certPem -outform der -out $serverCer }
}

$cert       = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($clientPfx, $CertPassword)
$thumbprint = $cert.Thumbprint
Set-Content -Path (Join-Path $workDir 'thumbprint.txt') -Value $thumbprint -Encoding ascii

# --- 2. Render aiconfiguration.json (real OpenAI key goes here) --------------
$templateCfg = Join-Path $here 'config/aiconfiguration.json'
if (-not (Test-Path $templateCfg)) { throw "Missing template: $templateCfg" }
$cfg = Get-Content $templateCfg -Raw

if ([string]::IsNullOrWhiteSpace($OpenAiApiKey)) {
  Write-Warning "No -OpenAiApiKey supplied. The proxy will start, but AI calls fail until you set a key."
  Write-Warning "  Set it later: edit .work\aiconfiguration.json (the ApiKey value), then: docker compose -f `"$compose`" restart"
  $OpenAiApiKey = ''
}
$cfg = $cfg.Replace('__OPENAI_API_KEY__', $OpenAiApiKey)
if ($Model -ne 'gpt-4o-mini')                 { $cfg = $cfg.Replace('gpt-4o-mini', $Model) }
if ($EmbeddingModel -ne 'text-embedding-3-small') { $cfg = $cfg.Replace('text-embedding-3-small', $EmbeddingModel) }
# UTF-8 without BOM (the app's JSON reader does not expect a BOM)
[IO.File]::WriteAllText((Join-Path $workDir 'aiconfiguration.json'), $cfg, [System.Text.UTF8Encoding]::new($false))
Write-Information "Wrote .work\aiconfiguration.json (OpenAI provider; key kept out of git)."

# --- 3. .env for docker compose (image, admin key, ports) --------------------
$envLines = @(
  "AIPROXY_IMAGE=$image",
  "CONFIG_ADMIN_ACCESS_KEY=$ConfigAdminAccessKey",
  "AIPROXY_HTTPS_PORT=$HttpsPort",
  "AIPROXY_HTTP_PORT=$HttpPort"
)
[IO.File]::WriteAllText((Join-Path $here '.env'), ($envLines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))

# --- 4. docker compose up ----------------------------------------------------
Write-Information "Pulling image + starting container (docker compose up -d)..."
$env:AIPROXY_IMAGE           = $image
$env:CONFIG_ADMIN_ACCESS_KEY = $ConfigAdminAccessKey
$env:AIPROXY_HTTPS_PORT      = "$HttpsPort"
$env:AIPROXY_HTTP_PORT       = "$HttpPort"
Invoke-Native { docker compose -f $compose up -d --pull always }

# --- 5. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "==================== DONE ====================" -ForegroundColor Green
Write-Host "Endpoint (Portal -> AI Proxy SelfHosted Url): $endpoint"
Write-Host "Health (with client cert)                   : $endpoint/health"
Write-Host "Cert thumbprint (must match in Portal)      : $thumbprint"
Write-Host "Client cert for Portal upload               : $clientPfx  (password: $CertPassword)"
Write-Host "                                              $certPem  (PEM with private key)"
Write-Host ("Config UI access key (future image)         : $ConfigAdminAccessKey$(if($generatedAdminKey){'  (auto-generated - save it!)'}else{''})") -ForegroundColor $(if($generatedAdminKey){'Yellow'}else{'Gray'})
Write-Host "  (the web Config UI / config-ui ships in a later image; until then, edit .work\aiconfiguration.json)"
Write-Host ""
Write-Host "WEBCON Portal (Studio) configuration:" -ForegroundColor Cyan
Write-Host "  1. AI mode: SelfHosted AI Proxy."
Write-Host "  2. AI Proxy Url: $endpoint   (no trailing slash)"
Write-Host "  3. Upload the cert WITH private key (PFX + password above, or the PEM)."
Write-Host "  4. Restart WEBCON Service (Windows service) + Portal (IIS)."
Write-Host ""
Write-Host "OpenAI provider (no Key Vault): the API key is read literally from .work\aiconfiguration.json." -ForegroundColor Cyan
if ([string]::IsNullOrEmpty($OpenAiApiKey)) {
  Write-Host "  No key set yet - AI calls will fail until you add one: edit .work\aiconfiguration.json then 'docker compose -f `"$compose`" restart'." -ForegroundColor Yellow
} else {
  Write-Host "  Models: text/image=$Model, embeddings=$EmbeddingModel (edit .work\aiconfiguration.json to change)."
}
Write-Host ""
Write-Host "Logs : docker compose -f `"$compose`" logs -f ai-proxy"
Write-Host "Stop : ./teardown.ps1" -ForegroundColor Yellow
Write-Host ""

# --- Local cert install (test the whole flow from the browser / local Portal) ----
# Non-fatal: importing into CurrentUser\Root shows an OS trust prompt and fails in a
# non-interactive session - run that part from an interactive terminal.
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
  $healthUrl = "$endpoint/health"

  Write-Host "Smoke test (waiting for container to come up)..." -ForegroundColor Cyan
  $ok = $false
  for ($i = 1; $i -le 20; $i++) {
    $res = [AiProxySmoke]::Health($healthUrl, $clientPfx, $CertPassword, $true)
    Write-Host "  with cert, attempt $i -> $res"
    if ($res -like 'HTTP 200*') { $ok = $true; break }
    Start-Sleep -Seconds 6
  }
  Write-Host "  without cert         -> $([AiProxySmoke]::Health($healthUrl, $clientPfx, $CertPassword, $false))  (expected: connection dropped - no client cert)"

  # What cert does the endpoint actually serve? (sanity check the thumbprint)
  try {
    $tcp = [System.Net.Sockets.TcpClient]::new('localhost', $HttpsPort)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, ({ $true }))
    $ssl.AuthenticateAsClient('localhost')
    $served = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
    Write-Host "  served cert thumbprint: $($served.Thumbprint)" -ForegroundColor $(if ($served.Thumbprint -eq $thumbprint) { 'Green' } else { 'Red' })
    Write-Host "  expected (uploaded)   : $thumbprint"
    $ssl.Dispose(); $tcp.Dispose()
  } catch { Write-Host "  could not read served cert: $($_.Exception.Message)" }

  if (-not $ok) {
    Write-Host "  health did not return 200 yet - check logs: docker compose -f `"$compose`" logs -f ai-proxy" -ForegroundColor Yellow
  }
}
