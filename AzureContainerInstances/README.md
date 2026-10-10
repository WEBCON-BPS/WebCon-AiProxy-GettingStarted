# Azure Container Instances — WEBCON AI Proxy (Self-Hosted)

> Part of [**WEBCON AI Proxy — Self-Hosted Getting Started**](../README.md). All commands below
> should be run from **this** directory (`AzureContainerInstances/`).

This sample provisions a fully functional, self-hosted
[**WEBCON AI Proxy**](https://hub.docker.com/r/webconbps/aiproxy) on **Azure Container Instances**
with a single command. The deployment configures **mutual TLS**, stores secrets in **Azure Key Vault**,
and can optionally include a dedicated **Azure AI Foundry** backend — all within a single, disposable
resource group.

It is intended for the following scenarios:

- evaluating or demonstrating the self-hosted AI Proxy without affecting a production environment;
- reproducing and debugging the **WEBCON Portal ↔ AI Proxy** mutual TLS handshake;
- providing a known-good reference for a custom deployment.

> **Disposable by design.** All resources are created in a single resource group
> (`rg-aiproxy-gs-<suffix>`) and removed by `teardown.ps1`. This is a sandbox (see
> [Notes & limitations](#notes--limitations)), not a hardened production template.

---

## Contents

- [What it deploys](#what-it-deploys)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [The AzureAi provider & `-DeployFoundry`](#the-azureai-provider---deployfoundry)
- [Configuring WEBCON Studio](#configuring-webcon-studio)
- [Testing from a browser](#testing-from-a-browser)
- [Verification](#verification)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Notes & limitations](#notes--limitations)

---

## What it deploys

```
rg-aiproxy-gs-<suffix>
├─ Container Registry (Basic)        the Docker Hub image is re-pushed here; ACI pulls it via the MI
├─ User-assigned Managed Identity    AcrPull on the ACR + Key Vault Secrets User on the KV
├─ Key Vault                         aiproxy-certificate-pem (TLS cert + mTLS trust + JWT signing key),
│                                    AiAzureEndpoint, AiAzureApiKey
├─ Container Instance (public FQDN)  the AI Proxy — only port 8081 (HTTPS/mTLS) is public; 8080 (HTTP) stays internal
└─ AI Foundry + project + models     OPTIONAL (-DeployFoundry): gpt-4o-mini + text-embedding-3-small,
                                     firewalled so only the container can reach it
```

The table below shows how each runtime requirement is satisfied:

| Requirement | Implementation |
|---|---|
| **TLS server certificate**, **mTLS trust** and **JWT signing key** | One Key Vault secret, `aiproxy-certificate-pem` (combined cert + PKCS#8 key PEM), named by `AppConfiguration__SelfHosted__Certificate__SecretName` and read by the application via the Managed Identity. No certificate file is mounted into the container |
| **Provider endpoint + key** | Key Vault secrets referenced **by name** in `aiconfiguration.json` (`AiAzureEndpoint`, `AiAzureApiKey`); for `Type: AzureAi`, both are resolved from Key Vault by the Managed Identity |
| **`aiconfiguration.json`** | **Baked into the image** (`Dockerfile.config`). The application requires `/app/aiconfiguration.json`; when Key Vault is used, the file contains only secret *names*, never secrets |
| **Azure authentication** | User-assigned Managed Identity (`AZURE_CLIENT_ID`) → `DefaultAzureCredential` |

---

## How it works

The AI Proxy runs in **SelfHosted** mode and therefore requires neither the WEBCON subscription
license server nor a SQL database; both are stubbed internally. It secures itself with **mutual TLS**
and issues its own short-lived JWTs.

```
WEBCON Portal                         AI Proxy container (ACI)            Azure
   │                                        │                              │
   │ 1. POST /token  (mTLS, client cert)    │                              │
   │    client_id/secret + ConfigDbGuid     │──── reads signing key ──────►│ Key Vault (via MI)
   │ ◄──────────────── JWT ─────────────────│                              │
   │                                        │                              │
   │ 2. POST /ai/v1/...  Bearer <JWT>        │──── reads provider key ─────►│ Key Vault (via MI)
   │    (still over mTLS)                    │──── chat/embeddings ────────►│ Azure AI Foundry / OpenAI
   │ ◄──────────────── result ──────────────│                              │
```

**Mutual TLS — a common integration pitfall.** The proxy serves HTTPS on port `8081` with a
self-signed certificate and requires the client to present that **same** certificate; both sides
compare the exact SHA-1 thumbprint. The certificate uploaded to the Portal must therefore be
byte-for-byte identical to the one the container serves. There is no CA chain and no hostname
validation — the check is purely thumbprint equality. `/health` and `/config-ui` are exempt from the
client-certificate check; every other endpoint returns `401` without one.

> **Changed in 2026.2.260.63** (and therefore in the default 2026.2.277.65):
>
> - `AppConfiguration__AzureKeyVault__SecretName` was **removed**. The certificate secret is now named by
>   `AppConfiguration__SelfHosted__Certificate__SecretName`, and with `UseAzureKeyVault=true` the app
>   reads the **TLS server certificate from Key Vault too** (previously it came from a mounted file).
>   An older deployment that still sets only the old variable fails at startup with
>   *"... nor the shared AppConfiguration:SelfHosted:Certificate:SecretName is set"*. `aci.bicep` sets the new name.
> - The three certificate roles can be split: `SelfHosted:Certificates:Https`, `SelfHosted:Certificates:MTLS`
>   and `Jwt:SigningKey` each accept their own `SecretName` (or `Path`/`Password` in file mode) and fall back
>   to `SelfHosted:Certificate` when empty. This sample keeps one certificate for all three.
> - `/health` no longer requires a client certificate (useful for load-balancer and Kubernetes probes).
> - Instead of mTLS, the proxy can authenticate the Portal with a client id/secret:
>   `SelfHosted:RequireClientCertificate=false` plus `SelfHosted:ClientId` and `SelfHosted:ClientSecret`
>   (startup fails if either is missing). This sample keeps mTLS.

---

## Prerequisites

- **Azure CLI**, signed in (`az login`) as **Owner** of the target subscription. This is required to
  create role assignments and Key Vault secrets.
- **Docker** (running) and **OpenSSL** (if not on `PATH`, the script uses the copy bundled with Git for Windows).

No source build, .NET SDK, Node.js, or private-registry login is required. The image is pulled from
the **public** Docker Hub repository
[`webconbps/aiproxy`](https://hub.docker.com/r/webconbps/aiproxy).

---

## Quick start

```powershell
# 1) mTLS / Portal sandbox only — provide your own AI endpoint later:
./deploy.ps1 -InstallCertLocally -SmokeTest

# 2) Self-contained: also create an AI Foundry + models and configure them automatically:
./deploy.ps1 -DeployFoundry -InstallCertLocally -SmokeTest

# 3) Use your own Azure OpenAI / Foundry endpoint + key:
./deploy.ps1 -AzureAiEndpoint "https://<resource>.openai.azure.com/openai/v1/" -AzureAiApiKey "<key>" -SmokeTest
```

The script is **idempotent** and can be re-run safely; resource names are derived from the
subscription id (override with `-Suffix`). On completion it prints the **endpoint URL**, the
**certificate thumbprint**, the **client certificate** to upload to the Portal, and the **Config UI**
URL.

---

## Configuration

`deploy.ps1` parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-ImageTag <tag>` | `2026.2.277.65` | Docker Hub tag of `webconbps/aiproxy` to deploy |
| `-Image <ref>` | — | Full image reference override (any registry) |
| `-DeployFoundry` | off | Also create an AI Foundry + project + models and wire the `AiAzure*` secrets |
| `-FoundryLocation <region>` | `swedencentral` | Region for the AI Foundry account |
| `-AzureAiEndpoint` / `-AzureAiApiKey` | — | Use an existing endpoint/key (seeded into Key Vault automatically) |
| `-InstallCertLocally` | off | Import the certificates into the `CurrentUser` store for browser/UI testing |
| `-SmokeTest` | off | Run the mTLS health checks at the end |
| `-Suffix <s>` | from subscription id | Distinguishes resource names (must be reasonably globally unique) |
| `-Location <region>` | `polandcentral` | Region for the resource group, ACR, Key Vault, and ACI |
| `-ConfigAdminAccessKey` | auto-generated (strong, random) | Login key for the Config UI (`/config-ui`); the script prints it. Pass a value to set it explicitly. |
| `-CertPassword` | `Sandbox!1` | Password for the exported client `.pfx` |

### Match `aiconfiguration.json` to the image version

The provider-configuration schema changed between releases. Use the file that matches your
`-ImageTag`:

| Image tag | File to use (`config/`) | Schema |
|---|---|---|
| **2026.2.x** (default) | `config/aiconfiguration.json` | `AiTaskTypesConfiguration` + models with `Id` |
| **2026.1.x** | copy `config/aiconfiguration.2026.1.json` over `config/aiconfiguration.json` first | `MethodTypesConfiguration` + models by `Name` |

```powershell
# for a 2026.1 image:
Copy-Item config/aiconfiguration.2026.1.json config/aiconfiguration.json -Force
./deploy.ps1 -ImageTag "2026.1.27.108" -SmokeTest
```

`Dockerfile.config` always bakes the file named exactly `aiconfiguration.json` (from `config/`).
When Key Vault is used, the file holds only secret **names** (for example `AiAzureApiKey`) and
therefore never contains real secrets.

---

## The AzureAi provider & `-DeployFoundry`

The sample `aiconfiguration.json` defines a single provider of `Type: AzureAi` whose **endpoint and
API key are Key Vault secret names** (`AiAzureEndpoint`, `AiAzureApiKey`), resolved at runtime by the
Managed Identity. There are three ways to populate them:

```powershell
# 1) Let the deployment create a dedicated AI Foundry and wire the secrets:
./deploy.ps1 -DeployFoundry

# 2) Point at an endpoint/key you already have:
./deploy.ps1 -AzureAiEndpoint "https://<resource>.openai.azure.com/openai/v1/" -AzureAiApiKey "<key>"

# 3) Set them manually at any time (the container starts without them; only AI calls require them):
az keyvault secret set --vault-name kvaipxgs<suffix> --name AiAzureEndpoint --value "https://<resource>.openai.azure.com/openai/v1/"
az keyvault secret set --vault-name kvaipxgs<suffix> --name AiAzureApiKey  --value "<key>"
```

**`-DeployFoundry`** creates an Azure AI Foundry (AIServices) account, a default project, and two
model deployments (`gpt-4o-mini`, `text-embedding-3-small`), then seeds `AiAzureEndpoint` and
`AiAzureApiKey`.

**Provider timeout (`TimeoutSeconds`).** Since **2026.2.135.35** `ProviderConfiguration` accepts an
optional `TimeoutSeconds`; when a call exceeds it the proxy aborts and fails over to the next model
configured for that task type (by priority). Omit it to use the SDK default. Add it in
`config/aiconfiguration.json`, e.g. `"ProviderConfiguration": { "Endpoint": "AiAzureEndpoint", "ApiKey": "AiAzureApiKey", "TimeoutSeconds": 60 }`.

**Network model.** The Foundry is configured as **deny-by-default**; the deployment allow-lists
**only the container's public IP**, so the proxy can reach it while the Portal and all other clients
cannot. This works because an ACI's outbound IP equals its inbound `ipAddress.ip` and is **stable
across restarts** — it changes only if the entire container group is recreated, in which case
re-running `deploy.ps1` re-adds it.

> ⚠️ **Cognitive Services firewall rules are eventually consistent and can take approximately 10–30
> minutes to fully propagate.** Immediately after deployment, AI calls often return
> `403 ... Access denied due to Virtual Network/Firewall rules`. **This is expected** and resolves on
> its own. **Do not** attempt to correct it by toggling the firewall; doing so only restarts the
> propagation interval. Model availability varies by region — if a model deployment fails, change
> `-FoundryLocation` or the model/version in `foundry.bicep`.

---

## Configuring WEBCON Studio

The integration is configured in **WEBCON Studio**, under **System configuration → Global
parameters**:

1. Select **SelfHosted AI** from the AI mode drop-down. Until this mode is selected, the Portal will
   not attach the client certificate.
2. Set the **AI Proxy URL** to the endpoint printed by the script, for example
   `https://aiproxy-gs-xxxx.polandcentral.azurecontainer.io:8081` — **with no trailing slash**.
3. Upload the certificate **together with its private key** — either the printed `aiproxy-client.pfx`
   (and its password) or the combined PEM. It must be the **same** certificate the container serves
   (identical thumbprint).
4. Restart both the **WEBCON Service** (Windows service) **and** the Portal (IIS); the configuration
   is cached.

---

## Testing from a browser

`deploy.ps1 -InstallCertLocally` imports the sandbox certificates into the **CurrentUser** store so
that the full flow can be driven from a browser on the same machine:

- **Server certificate → `CurrentUser\Root`** — the browser trusts the self-signed certificate (no
  TLS warning). This import triggers a Windows trust prompt, so it works only in an interactive
  terminal; otherwise the script skips it and prints the manual command.
- **Client certificate (`.pfx`) → `CurrentUser\My`** — the browser can present it for mutual TLS.

You can then open:

- `https://<fqdn>:8081/config-ui` — the web Config UI (edit providers, connections, and models;
  always enabled in SelfHosted mode). This path is exempt from client-certificate enforcement; sign in
  with the access key the deployment printed, or with your own `-ConfigAdminAccessKey`. When the browser
  prompts for a client certificate you can dismiss it — the panel does not require one. Plain-HTTP port
  `8080` is not exposed publicly, so the panel is never reachable unencrypted.
- Any mTLS-protected endpoint — the browser will prompt you to choose the client certificate.

> **Note.** The proxy uses `ClientCertificateMode.AllowCertificate`, so the client certificate is
> negotiated during the normal TLS handshake (not via renegotiation) — Chromium browsers handle this
> fine once the server cert is trusted (`-InstallCertLocally`). Saving in the UI writes back to
> `aiconfiguration.json` and hot-reloads; here that file is **baked into the image**, so UI edits do
> not survive a container restart — persistent changes belong in `config/aiconfiguration.json`.

`teardown.ps1` removes these certificates from the store again, unless `-KeepLocalCerts` is passed.

---

## Verification

`deploy.ps1 -SmokeTest` runs the checks below automatically. To run them manually on Windows, prefer
PowerShell together with a small C# helper: the bundled `curl.exe` uses the **Schannel** backend
(which does not support PEM client certificates), and a PowerShell *scriptblock* TLS callback fails on
background threads in Windows PowerShell 5.1. The helper avoids both issues, mirrors exactly what the
(C#) Portal does, and works in both Windows PowerShell 5.1 and PowerShell 7. Because `/health` no
longer needs a client certificate, mutual TLS is verified on `POST /token`:

```powershell
$fqdn = '<fqdn>'; $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new('.work/aiproxy-client.pfx', 'Sandbox!1')

$refs = if ($PSVersionTable.PSEdition -eq 'Desktop') { @{ ReferencedAssemblies = 'System.Net.Http' } } else { @{} }
Add-Type @refs -TypeDefinition @'
using System; using System.Net.Http; using System.Security.Cryptography.X509Certificates;
public static class MTls {
  public static string Send(string url, X509Certificate2 cert, bool post) {
    var h = new HttpClientHandler();
    h.ServerCertificateCustomValidationCallback = (m,c,ch,e) => true;   // accept self-signed for the test
    if (cert != null) h.ClientCertificates.Add(cert);
    using (var cl = new HttpClient(h)) {
      cl.Timeout = TimeSpan.FromSeconds(25);
      try { var r = post ? cl.PostAsync(url, new StringContent("")).GetAwaiter().GetResult() : cl.GetAsync(url).GetAwaiter().GetResult();
            return (int)r.StatusCode + ": " + r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); }
      catch (Exception ex) { var e = ex; while (e.InnerException != null) e = e.InnerException; return "ERR: " + e.Message; }
    }
  }
}
'@

"health        -> " + [MTls]::Send("https://$fqdn`:8081/health", $null,  $false)   # expect 200 Healthy (no cert needed)
"token no cert -> " + [MTls]::Send("https://$fqdn`:8081/token",  $null,  $true)    # expect 401 (mTLS enforced)
"token cert    -> " + [MTls]::Send("https://$fqdn`:8081/token",  $cert,  $true)    # expect 400 invalid_request (cert accepted)

# What certificate does the endpoint actually serve? (detects a TLS-terminating proxy / wrong cert)
$tcp = [System.Net.Sockets.TcpClient]::new($fqdn, 8081)
$ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, ({ $true })); $ssl.AuthenticateAsClient($fqdn)
"served thumbprint -> " + ([System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate).Thumbprint
$ssl.Dispose(); $tcp.Dispose()
```

Inspect the running container:

```powershell
az container logs    -g rg-aiproxy-gs-<suffix> -n aci-aiproxy-gs-<suffix>
az container exec    -g rg-aiproxy-gs-<suffix> -n aci-aiproxy-gs-<suffix> --container-name aiproxy --exec-command "/bin/bash"
```

---

## Teardown

```powershell
./teardown.ps1 -Suffix <suffix>
```

This deletes the resource group and removes the locally installed certificates. Key Vault and AI
Foundry are *soft-deleted*; to release their names immediately, the script prints the
`az keyvault purge` and `az cognitiveservices account purge` commands.

---

## Troubleshooting

| Symptom | Cause and resolution |
|---|---|
| **`403 ... Virtual Network/Firewall rules`** immediately after `-DeployFoundry` | The Cognitive Services firewall rule for the container IP has not propagated yet. **Wait approximately 10–30 minutes** for it to clear on its own. Do not toggle the firewall. |
| **`403 ... Virtual Network/Firewall rules`** against *your own* AI resource | Your Azure OpenAI / Foundry resource has `defaultAction = Deny` and the container's IP is not allowed. Run `az cognitiveservices account network-rule add -g <rg> -n <res> --ip-address <container ipAddress.ip>`. The IP changes only if the container group is recreated. |
| **`No RSA private key found in PEM`** on `/token` or at startup | The signing-key secret must be a **PKCS#8** PEM (`BEGIN PRIVATE KEY`), which `deploy.ps1` generates. In addition, `SelfHosted__Certificate__SecretName` must point at the **certificate/key** secret, not at the `aiconfiguration.json` secret. |
| **`... nor the shared AppConfiguration:SelfHosted:Certificate:SecretName is set`** at startup | The deployment still uses `AppConfiguration__AzureKeyVault__SecretName`, which was removed in 2026.2.260.63. Rename it to `AppConfiguration__SelfHosted__Certificate__SecretName` (the current `aci.bicep` does). |
| **`FileNotFoundException: /app/aiconfiguration.json`** | The file must exist in the container; here it is baked into the image. Key Vault does not supply it. |
| **Mutual TLS: the certificate is correct but the connection still fails** | Validation is an **exact SHA-1 thumbprint** match. If anything terminates TLS between the Portal and the container (Application Gateway, Front Door, APIM, a reverse proxy, or Container Apps ingress), the Portal sees that hop's certificate and/or the client certificate is stripped, so the connection fails even with the correct certificate. Plain ACI does not terminate TLS. Compare the served thumbprint (see [Verification](#verification)) with the uploaded one, and **run the check from the Portal host**. |
| **`401` without a certificate** | Expected on every endpoint except `/health` and `/config-ui`. A **wrong** certificate (thumbprint mismatch) drops the TLS connection instead. A `401` *with* the correct certificate originates from the authorization layer (a missing Bearer token), not from a certificate problem. |
| **`404` from the AI provider** after unblocking the firewall | `AiAzureEndpoint` must end with `/openai/v1/`, and each `ModelName` in `aiconfiguration.json` must equal the **deployment** name in your Foundry/OpenAI resource. |

---

## Repository layout

```
AzureContainerInstances/
├── deploy.ps1                       one-command deploy (image → infra → cert → optional Foundry → container → smoke test)
├── teardown.ps1                     delete the resource group + clean up local certs
├── bicep/
│   ├── infra.bicep                  Container Registry + Managed Identity + Key Vault + role assignments
│   ├── aci.bicep                    the Container Instance (env, MI, public FQDN)
│   └── foundry.bicep                optional AI Foundry + project + models, firewalled to the container
└── config/
    ├── Dockerfile.config            thin layer that bakes aiconfiguration.json onto the base image
    ├── aiconfiguration.json         provider config — 2026.2 schema (AiTaskTypesConfiguration + Id)
    └── aiconfiguration.2026.1.json  provider config — 2026.1.x schema (MethodTypesConfiguration + Name)
```

Generated certificates and secrets are written to `.work/` (created at deploy time) and are kept out
of git by the repository-root `.gitignore`.

---

## Notes & limitations

- **Sandbox, not production.** The deployment uses a self-signed certificate, a default Config UI key,
  a public container endpoint, and API-key authentication to the AI backend. Harden it (a real
  certificate/CA, private networking, key rotation, and monitoring) before any production use.
- **Generated secrets remain local.** The certificate and private key reside in `.work/` and are
  excluded by `.gitignore`, so they are never committed. Treat `aiproxy-client.pfx` as a secret.
- **A public proxy with a private AI backend is the limit of ACI.** Keeping the proxy publicly
  reachable for the Portal (raw TLS to its Kestrel endpoint for mutual TLS) means the AI backend can
  only be *IP-restricted to the container*, not fully network-isolated. A truly private
  (private-endpoint) backend would require running the proxy on a **VM within a VNet**. App Service,
  Application Gateway, Front Door, and Container Apps are not viable, because they terminate TLS and
  break the mTLS thumbprint check.
- **Cost.** The deployment uses ACI (approximately 1 vCPU / 2 GB), an ACR (Basic), a Key Vault, and —
  with `-DeployFoundry` — an AIServices account with pay-per-token model deployments. This is
  inexpensive for a test; run `teardown.ps1` when finished.
