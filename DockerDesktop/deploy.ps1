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
    3. Write .env (image tag + random Config UI access key + ports).
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
  [string]$ImageTag = '2026.2.277.65',              # tag of the public Docker Hub image webconbps/aiproxy (match the aiconfiguration schema)
  [string]$Image,                                   # full image ref override (any registry/tag); takes precedence over -ImageTag
  [string]$CertPassword = 'Sandbox!1',              # password for the exported client PFX (Portal upload)
  [string]$ConfigAdminAccessKey,                    # login key for the Config UI (/config-ui); auto-generated (strong) if not supplied
  [int]$HttpsPort = 7033,                            # host port -> container 8081 (HTTPS / mTLS; the Portal endpoint)
  [string]$ClientId,                                # with -ClientSecret: authenticate the Portal by client id/secret instead of mTLS
  [string]$ClientSecret,
  [int]$HttpPort  = 5298,                            # host port -> container 8080 (plain HTTP; serves the browser Config UI at /config-ui)
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

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "'docker' was not found on PATH. Install Docker Desktop and retry." }

# openssl: prefer PATH; otherwise fall back to the copy bundled with Git for Windows (not on PATH by default).
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

# 'docker compose' (v2) must be available
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw "'docker compose' (Compose v2) is not available. Update Docker Desktop." }

$image    = if ($Image) { $Image } else { "webconbps/aiproxy:$ImageTag" }
$endpoint = "https://localhost:$HttpsPort"

# Portal auth mode: both -ClientId and -ClientSecret -> client credentials on /token, no client cert.
if ([bool]$ClientId -ne [bool]$ClientSecret) { throw "Pass both -ClientId and -ClientSecret (or neither, for mTLS)." }
$useClientCredentials = [bool]$ClientId

# Config UI admin key: never ship a known default - generate a strong random one unless supplied.
$generatedAdminKey = [string]::IsNullOrWhiteSpace($ConfigAdminAccessKey)
if ($generatedAdminKey) { $ConfigAdminAccessKey = [guid]::NewGuid().ToString('N') }

Write-Information "Image        : $image"
Write-Information "Endpoint     : $endpoint   (mTLS)"
Write-Information "HTTP (local) : http://localhost:$HttpPort   (redirects to HTTPS; use the HTTPS URL for the Config UI)"

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
  "AIPROXY_HTTP_PORT=$HttpPort",
  "AIPROXY_REQUIRE_CLIENT_CERT=$((-not $useClientCredentials).ToString().ToLower())",
  "AIPROXY_CLIENT_ID=$ClientId",
  "AIPROXY_CLIENT_SECRET=$ClientSecret"
)
[IO.File]::WriteAllText((Join-Path $here '.env'), ($envLines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))

# --- 4. docker compose up ----------------------------------------------------
Write-Information "Pulling image + starting container (docker compose up -d)..."
$env:AIPROXY_IMAGE           = $image
$env:CONFIG_ADMIN_ACCESS_KEY = $ConfigAdminAccessKey
$env:AIPROXY_HTTPS_PORT      = "$HttpsPort"
$env:AIPROXY_HTTP_PORT       = "$HttpPort"
$env:AIPROXY_REQUIRE_CLIENT_CERT = (-not $useClientCredentials).ToString().ToLower()
$env:AIPROXY_CLIENT_ID       = $ClientId
$env:AIPROXY_CLIENT_SECRET   = $ClientSecret
Invoke-Native { docker compose -f $compose up -d --pull always }

# --- 5. Summary --------------------------------------------------------------
Write-Host ""
Write-Host "==================== DONE ====================" -ForegroundColor Green
Write-Host "Endpoint (Portal -> AI Proxy SelfHosted Url): $endpoint"
Write-Host "Health (no client cert needed)               : $endpoint/health"
Write-Host "Cert thumbprint (must match in Portal)      : $thumbprint"
Write-Host "Client cert for Portal upload               : $clientPfx  (password: $CertPassword)"
Write-Host "                                              $certPem  (PEM with private key)"
Write-Host "Config UI (browser)                         : https://localhost:$HttpsPort/config-ui  (HTTPS; run with -InstallCertLocally to avoid the TLS warning)"
Write-Host ("  access key$(if($generatedAdminKey){' (auto-generated - save it!)'}else{''}): $ConfigAdminAccessKey") -ForegroundColor $(if($generatedAdminKey){'Yellow'}else{'Gray'})
Write-Host "  (dismiss the client-cert prompt - /config-ui does not need it. Edits write .work\aiconfiguration.json and hot-reload; or edit the file + 'docker compose restart'.)"
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
  # mTLS test via a tiny C# helper (mirrors what the C# WEBCON Portal does). The certificate is loaded
  # in PowerShell and passed in, so the helper compiles on both Windows PowerShell 5.1 and PowerShell 7.
  # /health needs no client cert (since 2026.2.260.63); /token proves the Portal auth mode end to end.
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
