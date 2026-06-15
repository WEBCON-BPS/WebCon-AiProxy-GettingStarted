# Azure Container Instances — WEBCON AI Proxy (Self-Hosted)

> Part of [**WEBCON AI Proxy — Self-Hosted Getting Started**](../README.md). Run all commands below
> from **this** directory (`AzureContainerInstances/`).

Spin up a fully working, **self-hosted [WEBCON AI Proxy](https://hub.docker.com/r/webconbps/aiproxy)**
on **Azure Container Instances** — with **mutual TLS**, secrets in **Key Vault**, and (optionally) a
dedicated **Azure AI Foundry** backend — into a single, disposable resource group, with one command.

Use it to:
- evaluate / demo the self-hosted AI Proxy without touching your production environment,
- reproduce and debug the **WEBCON Portal ↔ AI Proxy mTLS** handshake,
- have a known-good reference for your own deployment.

> **Disposable by design.** Everything lands in one resource group (`rg-aiproxy-gs-<suffix>`) and is
> removed by `teardown.ps1`. This is a sandbox — see [Notes & limitations](#notes--limitations); it
> is **not** a hardened production template.

---

## Contents

- [What it deploys](#what-it-deploys)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [The AzureAi provider & `-DeployFoundry`](#the-azureai-provider---deployfoundry)
- [Wire up the WEBCON Portal](#wire-up-the-webcon-portal)
- [Test from a browser / UI](#test-from-a-browser--ui)
- [Verify it works](#verify-it-works)
- [Tear down](#tear-down)
- [Troubleshooting](#troubleshooting)
- [Repo layout](#repo-layout)
- [Notes & limitations](#notes--limitations)

---

## What it deploys

```
rg-aiproxy-gs-<suffix>
├─ Container Registry (Basic)        the Docker Hub image is re-pushed here; ACI pulls it via the MI
├─ User-assigned Managed Identity    AcrPull on the ACR + Key Vault Secrets User on the KV
├─ Key Vault                         aiproxy-certificate-pem (JWT signing key + TLS cert),
│                                    AiAzureEndpoint, AiAzureApiKey
├─ Container Instance (public FQDN)  the AI Proxy — ports 8081 (HTTPS/mTLS) and 8080
└─ AI Foundry + project + models     OPTIONAL (-DeployFoundry): gpt-4o-mini + text-embedding-3-small,
                                     firewalled so only the container can reach it
```

How each requirement is satisfied:

| Requirement | How |
|---|---|
| **TLS server cert** (mTLS endpoint) | ACI `secret` volume → `/app/https/certificate.pem` |
| **JWT signing key** | KV secret `aiproxy-certificate-pem`, read by the app via the Managed Identity (same cert as the TLS one) |
| **Provider endpoint + key** | KV secrets referenced **by name** in `aiconfiguration.json` (`AiAzureEndpoint`, `AiAzureApiKey`); for `Type: AzureAi` both are resolved from KV by the MI |
| **`aiconfiguration.json`** | **baked into the image** (`Dockerfile.config`) — the app requires `/app/aiconfiguration.json`; with Key Vault it contains only secret *names*, never secrets |
| **Azure authentication** | user-assigned Managed Identity (`AZURE_CLIENT_ID`) → `DefaultAzureCredential` |

---

## How it works

The AI Proxy runs in **SelfHosted** mode: it does **not** need the WEBCON subscription license server
or a SQL database (those are stubbed internally). It secures itself with **mutual TLS** and issues its
own short-lived JWTs.

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

**mTLS detail (the part that trips people up):** the proxy serves HTTPS on `:8081` with a self-signed
certificate and **requires the client to present the *same* certificate** — both sides compare the
**exact SHA-1 thumbprint**. So the cert you upload into the Portal must be byte-for-byte the cert the
container serves. No CA chain, no hostname check — just thumbprint equality.

---

## Prerequisites

- **Azure CLI**, logged in (`az login`) as **Owner** on the target subscription (needed to create
  role assignments and Key Vault secrets).
- **Docker** (running) and **OpenSSL**.

No source build, .NET SDK, Node, or private-registry login required — the image is pulled from the
**public** Docker Hub repo [`webconbps/aiproxy`](https://hub.docker.com/r/webconbps/aiproxy).

---

## Quick start

```powershell
# 1) mTLS / Portal sandbox only — bring your own AI endpoint later:
./deploy.ps1 -InstallCertLocally -SmokeTest

# 2) Self-contained: also create an AI Foundry + models and wire everything up:
./deploy.ps1 -DeployFoundry -InstallCertLocally -SmokeTest

# 3) Use your own Azure OpenAI / Foundry endpoint + key:
./deploy.ps1 -AzureAiEndpoint "https://<resource>.openai.azure.com/openai/v1/" -AzureAiApiKey "<key>" -SmokeTest
```

The script is **idempotent and re-runnable** — resource names are derived from your subscription id
(override with `-Suffix`). When it finishes it prints the **endpoint URL**, the **certificate
thumbprint**, the **client certificate** to upload to the Portal, and the **Config UI** URL.

---

## Configuration

`deploy.ps1` parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-ImageTag <tag>` | `2026.2.64.17` | Docker Hub tag of `webconbps/aiproxy` to deploy |
| `-Image <ref>` | — | Full image reference override (any registry) |
| `-DeployFoundry` | off | Also create an AI Foundry + project + models and wire `AiAzure*` secrets |
| `-FoundryLocation <region>` | `swedencentral` | Region for the AI Foundry account |
| `-AzureAiEndpoint` / `-AzureAiApiKey` | — | Use an existing endpoint/key (seeded into KV for you) |
| `-InstallCertLocally` | off | Import the certs into your `CurrentUser` store for browser/UI testing |
| `-SmokeTest` | off | Run the mTLS health checks at the end |
| `-Suffix <s>` | from subscription id | Distinguishes resource names (must be globally unique-ish) |
| `-Location <region>` | `polandcentral` | Region for the RG / ACR / KV / ACI |
| `-ConfigAdminAccessKey` | `sandbox-admin` | Login key for the Config UI (`/config-ui`) |
| `-CertPassword` | `Sandbox!1` | Password for the exported client `.pfx` |

### Match `aiconfiguration.json` to the image version

The provider-config schema changed between releases. Use the file that matches your `-ImageTag`:

| Image tag | File to use (`config/`) | Schema |
|---|---|---|
| **2026.2.x** (default) | `config/aiconfiguration.json` | `AiTaskTypesConfiguration` + models with `Id` |
| **2026.1.x** | copy `config/aiconfiguration.2026.1.json` over `config/aiconfiguration.json` first | `MethodTypesConfiguration` + models by `Name` |

```powershell
# for a 2026.1 image:
Copy-Item config/aiconfiguration.2026.1.json config/aiconfiguration.json -Force
./deploy.ps1 -ImageTag "2026.1.27.108" -SmokeTest
```

`Dockerfile.config` always bakes the file literally named `aiconfiguration.json` (from `config/`).
With Key Vault it holds only secret **names** (e.g. `AiAzureApiKey`), so it never contains real secrets.

---

## The AzureAi provider & `-DeployFoundry`

The sample `aiconfiguration.json` defines one provider of `Type: AzureAi` whose **endpoint and API key
are Key Vault secret names** (`AiAzureEndpoint`, `AiAzureApiKey`), resolved at runtime by the Managed
Identity. Three ways to populate them:

```powershell
# 1) Let the deploy create a dedicated AI Foundry and wire the secrets:
./deploy.ps1 -DeployFoundry

# 2) Point at an endpoint/key you already have:
./deploy.ps1 -AzureAiEndpoint "https://<resource>.openai.azure.com/openai/v1/" -AzureAiApiKey "<key>"

# 3) Set them yourself, any time (the container starts fine without them — only AI calls need them):
az keyvault secret set --vault-name kvaipxgs<suffix> --name AiAzureEndpoint --value "https://<resource>.openai.azure.com/openai/v1/"
az keyvault secret set --vault-name kvaipxgs<suffix> --name AiAzureApiKey  --value "<key>"
```

**`-DeployFoundry`** creates an Azure AI Foundry (AIServices) account + default project + two model
deployments (`gpt-4o-mini`, `text-embedding-3-small`) and seeds `AiAzureEndpoint`/`AiAzureApiKey`.

**Network model:** the Foundry is **Deny-by-default**; the deploy allow-lists **only the container's
public IP**, so the proxy can reach it but the Portal (and everyone else) cannot. This works because
an ACI's outbound IP equals its inbound `ipAddress.ip` and is **stable across restarts** (it changes
only if the whole container group is recreated — re-run `deploy.ps1` to re-add it).

> ⚠️ **Cognitive Services firewall rules are eventually-consistent and can take ~10–30 minutes to
> fully propagate.** Right after deploy, AI calls often return
> `403 ... Access denied due to Virtual Network/Firewall rules` — **this is expected** and clears on
> its own. **Do not** try to "fix" it by toggling the firewall; that just restarts the propagation
> clock. Model availability varies by region — if a model deployment fails, change `-FoundryLocation`
> or the model/version in `foundry.bicep`.

---

## Wire up the WEBCON Portal

1. Set the AI mode to **SelfHosted AI Proxy** (global parameter `UseAITokenLicense`). If this is not
   set, the Portal never attaches the client certificate.
2. **AI Proxy URL** = the endpoint printed by the script, e.g.
   `https://aiproxy-gs-xxxx.polandcentral.azurecontainer.io:8081` — **no trailing slash**.
3. Upload the certificate **with its private key** — the printed `aiproxy-client.pfx` (+ password) or
   the combined PEM. It must be the *same* cert the container serves (identical thumbprint).
4. Restart the **WEBCON Service** (Windows service) **and** the Portal (IIS) — the config is cached.

---

## Test from a browser / UI

`deploy.ps1 -InstallCertLocally` imports the sandbox certs into your **CurrentUser** store so you can
drive the whole flow from a browser on the same machine:

- **server cert → `CurrentUser\Root`** — the browser trusts the self-signed cert (no TLS warning).
  *(This import shows a Windows trust prompt, so it only works in an interactive terminal — the script
  skips it otherwise and prints the manual command.)*
- **client cert (`.pfx`) → `CurrentUser\My`** — the browser can present it for mTLS.

Then open:
- `https://<fqdn>:8081/config-ui` — the Config UI (this path is exempt from client-cert enforcement;
  log in with `-ConfigAdminAccessKey`, default `sandbox-admin`).
- any mTLS-protected endpoint — the browser will prompt you to choose the client certificate.

`teardown.ps1` removes these certs from your store again (unless you pass `-KeepLocalCerts`).

---

## Verify it works

`deploy.ps1 -SmokeTest` runs the checks below for you. To run them by hand on Windows, prefer
PowerShell + a tiny C# helper — the bundled `curl.exe` uses the **Schannel** backend (no PEM client
certs), and a PowerShell *scriptblock* TLS callback fails on background threads in Windows PowerShell
5.1. This C# helper avoids both and mirrors exactly what the (C#) Portal does:

```powershell
$fqdn = '<fqdn>'; $pfx = '.work/aiproxy-client.pfx'; $pwd = 'Sandbox!1'

Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System; using System.Net.Http; using System.Security.Cryptography.X509Certificates;
public static class MTls {
  public static string Get(string url, string pfx, string pwd, bool withCert) {
    var h = new HttpClientHandler();
    h.ServerCertificateCustomValidationCallback = (m,c,ch,e) => true;   // accept self-signed for the test
    if (withCert) h.ClientCertificates.Add(new X509Certificate2(pfx, pwd));
    using (var cl = new HttpClient(h)) {
      cl.Timeout = TimeSpan.FromSeconds(25);
      try { var r = cl.GetAsync(url).GetAwaiter().GetResult();
            return (int)r.StatusCode + ": " + r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); }
      catch (Exception ex) { var e = ex; while (e.InnerException != null) e = e.InnerException; return "ERR: " + e.Message; }
    }
  }
}
'@

"with cert    -> " + [MTls]::Get("https://$fqdn`:8081/health", $pfx, $pwd, $true)    # expect HTTP 200 Healthy
"without cert -> " + [MTls]::Get("https://$fqdn`:8081/health", $pfx, $pwd, $false)   # expect connection rejected

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

## Tear down

```powershell
./teardown.ps1 -Suffix <suffix>
```

Deletes the resource group and removes the locally-installed certs. Key Vault and AI Foundry are
*soft-deleted*; to free their names immediately the script prints the `az keyvault purge` /
`az cognitiveservices account purge` commands.

---

## Troubleshooting

| Symptom | Cause & fix |
|---|---|
| **`403 ... Virtual Network/Firewall rules`** right after `-DeployFoundry` | The Cognitive Services firewall rule for the container IP hasn't propagated yet. **Wait ~10–30 min** — it clears itself. Don't toggle the firewall. |
| **`403 ... Virtual Network/Firewall rules`** against *your own* AI resource | Your Azure OpenAI / Foundry has `defaultAction = Deny` and the container's IP isn't allowed. `az cognitiveservices account network-rule add -g <rg> -n <res> --ip-address <container ipAddress.ip>`. The IP changes only if the container group is recreated. |
| **`No RSA private key found in PEM`** on `/token` / startup | The signing-key secret must be a **PKCS#8** PEM (`BEGIN PRIVATE KEY`); `deploy.ps1` generates that. Also: `AzureKeyVault__SecretName` must point at the **cert/key** secret, not at the `aiconfiguration.json` secret. |
| **`FileNotFoundException: /app/aiconfiguration.json`** | The file must exist in the container — it's baked into the image here. Don't expect Key Vault to supply it. |
| **mTLS: "the cert is fine but it still fails"** | Validation is an **exact SHA-1 thumbprint** match. If anything terminates TLS between Portal and container (App Gateway / Front Door / APIM / reverse proxy / Container Apps ingress), the Portal sees that hop's cert and/or the client cert is stripped → it fails even with the right cert. Plain ACI does not terminate TLS. Compare the served thumbprint (see [Verify](#verify-it-works)) with the uploaded one, **run the check from the Portal host**. |
| **No container logs without a cert; logs appear with a cert** | Expected. Without a client cert the TLS layer rejects the connection before it reaches the app. A `401` *with* a cert is the authorization layer (missing Bearer token), not a cert problem. |
| **404 from the AI provider** after unblocking the firewall | `AiAzureEndpoint` must end with `/openai/v1/`, and each `ModelName` in `aiconfiguration.json` must equal the **deployment** name in your Foundry/OpenAI resource. |
| **`dbcontext` health "degraded"** | Expected in SelfHosted with no SQL — DB access is stubbed and not needed for the mTLS/token flow. |

---

## Repo layout

```
AzureContainerInstances/
├── deploy.ps1                       one-command deploy (image → infra → cert → optional Foundry → container → smoke test)
├── teardown.ps1                     delete the resource group + clean up local certs
├── bicep/
│   ├── infra.bicep                  Container Registry + Managed Identity + Key Vault + role assignments
│   ├── aci.bicep                    the Container Instance (env, cert `secret` volume, MI, public FQDN)
│   └── foundry.bicep                optional AI Foundry + project + models, firewalled to the container
└── config/
    ├── Dockerfile.config            thin layer that bakes aiconfiguration.json onto the base image
    ├── aiconfiguration.json         provider config — 2026.2 schema (AiTaskTypesConfiguration + Id)
    └── aiconfiguration.2026.1.json  provider config — 2026.1.x schema (MethodTypesConfiguration + Name)
```

Generated certificates/secrets land in `.work/` (created at deploy time) and are kept out of git by
the repo-root `.gitignore`.

---

## Notes & limitations

- **Sandbox, not production.** Self-signed certificate, a default Config UI key, public container
  endpoint, API-key auth to the AI backend. Harden (real cert/CA, private networking, key rotation,
  monitoring) before any production use.
- **Generated secrets stay local.** The cert + private key live in `.work/` and are excluded by
  `.gitignore` — they are never committed. Treat `aiproxy-client.pfx` as a secret.
- **Public proxy + private AI backend is the limit of ACI.** Keeping the proxy publicly reachable for
  the Portal (raw TLS to its Kestrel for mTLS) means the AI backend can only be *IP-restricted to the
  container*, not fully network-isolated. A truly private (private-endpoint) backend would require the
  proxy on a **VM in a VNet** (App Service / App Gateway / Front Door / Container Apps don't work —
  they terminate TLS and break the mTLS thumbprint check).
- **Cost.** ACI (~1 vCPU / 2 GB), an ACR (Basic), a Key Vault, and — with `-DeployFoundry` — an
  AIServices account with pay-per-token model deployments. Cheap for a test; run `teardown.ps1` when
  done.
