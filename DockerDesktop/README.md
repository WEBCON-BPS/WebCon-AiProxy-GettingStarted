# Docker Desktop — WEBCON AI Proxy (Self-Hosted, OpenAI, no Key Vault)

> Part of [**WEBCON AI Proxy — Self-Hosted Getting Started**](../README.md). All commands below
> should be run from **this** directory (`DockerDesktop/`).

This sample runs a fully functional, self-hosted
[**WEBCON AI Proxy**](https://hub.docker.com/r/webconbps/aiproxy) on your local **Docker Desktop**
with a single command. It uses **mutual TLS**, connects to **OpenAI** (`api.openai.com`), and stores
**no secrets in Azure Key Vault** — everything lives in local files. There is no Azure account, no
cloud resources, and nothing to tear down except a container.

It is intended for the following scenarios:

- evaluating or demonstrating the self-hosted AI Proxy entirely on a developer machine;
- reproducing and debugging the **WEBCON Portal ↔ AI Proxy** mutual TLS handshake locally;
- a quick OpenAI-backed sandbox without provisioning any cloud infrastructure.

> **Disposable by design.** One container, one local certificate, one rendered config file. Remove
> it all with `teardown.ps1`. This is a sandbox (see [Notes & limitations](#notes--limitations)), not
> a hardened production template.

---

## Contents

- [What it runs](#what-it-runs)
- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [The OpenAI provider (no Key Vault)](#the-openai-provider-no-key-vault)
- [Configuring WEBCON Studio](#configuring-webcon-studio)
- [Testing the endpoint (Postman / the Portal)](#testing-the-endpoint-postman--the-portal)
- [Verification](#verification)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Notes & limitations](#notes--limitations)

---

## What it runs

```
Docker Desktop (local)
└─ container "aiproxy-gs"  (public image webconbps/aiproxy)
   ├─ 8081  HTTPS / mutual TLS   -> host :7033   the endpoint the WEBCON Portal connects to
   ├─ 8080  plain HTTP           -> host :5298   localhost only; redirects to HTTPS (Config UI is future)
   ├─ /app/https/certificate.pem        (mounted, read-only)  TLS server cert + JWT signing key
   └─ /app/aiconfiguration.json         (mounted, rw)         OpenAI provider; holds the real key
```

The table below shows how each runtime requirement is satisfied:

| Requirement | Implementation |
|---|---|
| **TLS server certificate** (mTLS endpoint) | A self-signed combined cert+key PEM, bind-mounted to `/app/https/certificate.pem` |
| **JWT signing key** | The **same** PEM — with `UseAzureKeyVault=false` the proxy reads the RSA private key directly from `Certificate__Path` |
| **Provider endpoint + key** | Set **literally** in `aiconfiguration.json`. With Key Vault disabled the `ApiKey` value is the real OpenAI key, not a secret name |
| **`aiconfiguration.json`** | Rendered into `.work/` (with your key) and bind-mounted. Kept out of git |
| **Azure authentication** | None — there is no Key Vault and no Managed Identity in this scenario |

---

## How it works

The AI Proxy runs in **SelfHosted** mode and therefore requires neither the WEBCON subscription
license server nor a SQL database; both are stubbed internally. It secures itself with **mutual TLS**
and issues its own short-lived JWTs.

```
WEBCON Portal                         AI Proxy container (Docker)         OpenAI
   │                                        │                              │
   │ 1. POST /token  (mTLS, client cert)    │                              │
   │    client_id/secret + ConfigDbGuid     │  signs with the PEM key      │
   │ ◄──────────────── JWT ─────────────────│                              │
   │                                        │                              │
   │ 2. POST /ai/v1/...  Bearer <JWT>        │  reads the literal API key   │
   │    (still over mTLS)                    │──── chat/embeddings ────────►│ api.openai.com
   │ ◄──────────────── result ──────────────│                              │
```

**Mutual TLS — a common integration pitfall.** The proxy serves HTTPS on container port `8081`
(published to `localhost:7033`) with a self-signed certificate and requires the client to present that
**same** certificate; both sides compare the exact SHA-1 thumbprint. The certificate uploaded to the
Portal must therefore be byte-for-byte identical to the one the container serves. There is no CA chain
and no hostname validation — the check is purely thumbprint equality. In the current image **every**
endpoint requires the matching client certificate (a request without it has its connection dropped).

**Two layers, two kinds of `401`.** Passing mutual TLS only gets you past the certificate check:

- **`/health`** needs *only* the client certificate — with the matching cert it returns `200`, which
  is why it is the smoke-test endpoint (see [Verification](#verification)). A `401` here means the
  client **did not present a certificate** at all. The app accepts a connection with no client cert
  (TLS `AllowCertificate`) and then returns `401`; a browser typically hits this because Windows did
  not *offer* the cert in the picker — see [the testing notes](#testing-the-endpoint-postman--the-portal).
- **AI endpoints** additionally require a **Bearer JWT** the proxy issues from `/token`. A `401` there
  *with* a valid client certificate is the **authorization** layer (missing token), not a certificate
  problem — only the full WEBCON Portal flow obtains that token.

**No Key Vault.** With `AppConfiguration__SelfHosted__UseAzureKeyVault=false`, the proxy does **not**
call Azure. The values in `aiconfiguration.json` are used verbatim (the `ApiKey` is the real key), and
the JWT signing key is read straight from the mounted certificate PEM.

---

## Prerequisites

- **Docker Desktop** running, with Docker Compose v2 (`docker compose version`).
- **OpenSSL** on `PATH` (used once to generate the self-signed certificate).
- An **OpenAI API key** (`sk-...`) if you want AI calls to succeed. The container starts without one;
  only AI calls require it.

No Azure CLI, .NET SDK, or private-registry login is required. The image is pulled from the **public**
Docker Hub repository [`webconbps/aiproxy`](https://hub.docker.com/r/webconbps/aiproxy).

---

## Quick start

```powershell
# Connect to OpenAI and run the mTLS smoke test:
./deploy.ps1 -OpenAiApiKey "sk-..." -SmokeTest

# Also import the sandbox certs so a browser / local Portal trusts the endpoint:
./deploy.ps1 -OpenAiApiKey "sk-..." -InstallCertLocally -SmokeTest

# Start without a key now (add it later: edit .work\aiconfiguration.json, then docker compose restart):
./deploy.ps1
```

The script is **idempotent** and re-runnable. It generates the certificate and config under `.work/`,
writes `.env`, and runs `docker compose up -d --pull always`. On completion it prints the **endpoint
URL**, the **certificate thumbprint**, and the **client certificate** to upload to the Portal.

After the first run you can also drive Compose directly (it reads the generated `.env`):

```powershell
docker compose up -d
docker compose logs -f ai-proxy
docker compose down
```

---

## Configuration

`deploy.ps1` parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-OpenAiApiKey <sk-...>` | — | Real OpenAI key. Written into `.work/aiconfiguration.json`; never committed |
| `-Model <id>` | `gpt-4o-mini` | OpenAI text/image model id |
| `-EmbeddingModel <id>` | `text-embedding-3-small` | OpenAI embedding model id |
| `-ImageTag <tag>` | `2026.2.64.17` | Docker Hub tag of `webconbps/aiproxy` to run |
| `-Image <ref>` | — | Full image reference override (any registry) |
| `-HttpsPort <n>` | `7033` | Host port mapped to container `8081` (HTTPS/mTLS) |
| `-HttpPort <n>` | `5298` | Host port mapped to container `8080` (plain HTTP) |
| `-ConfigAdminAccessKey` | auto-generated (strong, random) | Login key for the **web Config UI that ships in a later image**; harmless now |
| `-CertPassword` | `Sandbox!1` | Password for the exported client `.pfx` |
| `-InstallCertLocally` | off | Import the certificates into the `CurrentUser` store (server cert → Root, client cert → My) |
| `-SmokeTest` | off | Run the mTLS health checks at the end |

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
./deploy.ps1 -ImageTag "2026.1.27.108" -OpenAiApiKey "sk-..." -SmokeTest
```

`deploy.ps1` always renders the file named exactly `config/aiconfiguration.json` (replacing
`__OPENAI_API_KEY__` and the model ids) into `.work/aiconfiguration.json`, which is what the container
mounts.

---

## The OpenAI provider (no Key Vault)

The sample `aiconfiguration.json` defines a single provider of `Type: OpenAi`. **Because Key Vault is
disabled, the `ApiKey` value is the literal OpenAI key**, not a secret name — this is the key
difference from the Azure scenario, where the same field holds a Key Vault secret *name*.

```json
"ProviderConnections": {
  "OpenAi": {
    "Type": "OpenAi",
    "ProviderConfiguration": { "ApiKey": "sk-...your real key..." }
  }
}
```

You never edit this by hand with a real key in git: `deploy.ps1 -OpenAiApiKey "sk-..."` injects it into
`.work/aiconfiguration.json` (git-ignored). There are two ways to populate it:

```powershell
# 1) Pass it to the deploy script (recommended):
./deploy.ps1 -OpenAiApiKey "sk-..."

# 2) Edit the rendered file, then restart the container:
notepad .work\aiconfiguration.json        # replace the ApiKey value
docker compose -f docker-compose.yml restart
```

> A browser-based **Config UI** for editing this without touching files is on the way in a later
> image; until then, the rendered file + a restart is the way to change the key or models.

The default endpoint is OpenAI's public API; `ModelName` values are OpenAI model ids (for example
`gpt-4o-mini`, `text-embedding-3-small`). To use a different provider, change `Type` (the image also
supports `AzureAi`, `Gemini`, and `OpenAiApiCompatible`) and the matching `ProviderConfiguration`.

---

## Configuring WEBCON Studio

The integration is configured in **WEBCON Studio**, under **System configuration → Global
parameters**:

1. Select **SelfHosted AI Proxy** from the AI mode drop-down. Until this mode is selected, the Portal
   will not attach the client certificate.
2. Set the **AI Proxy URL** to `https://localhost:7033` — **with no trailing slash**. (The Portal/IIS
   host must be the same machine that runs Docker Desktop, or reachable at that address.)
3. Upload the certificate **together with its private key** — either the printed `aiproxy-client.pfx`
   (and its password) or the combined PEM. It must be the **same** certificate the container serves
   (identical thumbprint).
4. Restart both the **WEBCON Service** (Windows service) **and** the Portal (IIS); the configuration
   is cached.

---

## Testing the endpoint (Postman / the Portal)

The reliable way to drive mutual TLS by hand is a client that lets you **attach the `.pfx` explicitly**
— Postman, `curl`, or the WEBCON Portal itself — rather than a browser:

- **Postman** — under the request's *Settings → Certificates* (or *Settings → Certificates* at the app
  level), add a client certificate for host `localhost` port `7033`, pointing at
  `.work\aiproxy-client.pfx` with the password (`Sandbox!1` by default). Then `GET
  https://localhost:7033/health` returns **200 Healthy**. (Disable SSL verification, or trust the
  server cert, since it is self-signed.)
- **The WEBCON Portal** — the real consumer; see [Configuring WEBCON Studio](#configuring-webcon-studio).

`deploy.ps1 -InstallCertLocally` imports the sandbox certificates into the **CurrentUser** store
(server cert → `Root` for TLS trust, client cert → `My`). This helps tools that read the OS store, and
removes the browser's TLS warning.

> **Why a browser gets `401` on `/health` even though the cert is installed.** `/health` needs only
> the client certificate, so the `401` means the browser **did not send one**. The proxy accepts the
> connection without a client cert (TLS `AllowCertificate`) and the app then returns `401` — it is not
> a thumbprint mismatch (that would drop the connection). On Windows the usual cause is that the cert
> is **not offered** in the selection prompt unless it carries the **Client Authentication** EKU.
> `deploy.ps1` now generates the cert with `serverAuth,clientAuth`; a certificate created by an earlier
> run lacks it, so regenerate and re-import:
>
> ```powershell
> ./teardown.ps1 -PurgeWork
> ./deploy.ps1 -OpenAiApiKey "sk-..." -InstallCertLocally -SmokeTest
> ```
>
> Then open `https://localhost:7033/health` and **pick the certificate when prompted** (restart the
> browser if no prompt appears). Postman and the Portal, which attach the `.pfx` explicitly, are
> unaffected and remain the reliable test paths.

`teardown.ps1` removes the imported certificates from the store again, unless `-KeepLocalCerts` is
passed.

---

## Verification

`deploy.ps1 -SmokeTest` runs the checks below automatically. To run them manually on Windows, prefer
PowerShell together with a small C# helper: the bundled `curl.exe` uses the **Schannel** backend
(which does not support PEM client certificates), and a PowerShell *scriptblock* TLS callback fails on
background threads in Windows PowerShell 5.1. The helper avoids both issues and mirrors exactly what
the (C#) Portal does:

```powershell
$pfx = '.work/aiproxy-client.pfx'; $pwd = 'Sandbox!1'

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

"with cert    -> " + [MTls]::Get("https://localhost:7033/health", $pfx, $pwd, $true)    # expect HTTP 200 Healthy
"without cert -> " + [MTls]::Get("https://localhost:7033/health", $pfx, $pwd, $false)   # expect the connection to be dropped (no client cert)
```

Inspect the running container:

```powershell
docker compose -f docker-compose.yml logs -f ai-proxy
docker exec -it aiproxy-gs /bin/bash
```

---

## Teardown

```powershell
./teardown.ps1                 # docker compose down + remove the imported sandbox certs
./teardown.ps1 -KeepLocalCerts # leave the imported certs in the CurrentUser store
./teardown.ps1 -PurgeWork      # also delete .work\ (certs + rendered config) and .env
```

---

## Troubleshooting

| Symptom | Cause and resolution |
|---|---|
| **`docker compose` errors with `CONFIG_ADMIN_ACCESS_KEY` is not set** | Run `deploy.ps1` first (it writes `.env`), or set the variable in your shell before `docker compose up`. |
| **`Incorrect run for every connector`** in the logs | The `aiconfiguration.json` schema does not match the image version. Use the 2026.1 file for a 2026.1 image (see [Match the schema](#match-aiconfigurationjson-to-the-image-version)). |
| **`No RSA private key found in PEM`** at startup or on `/token` | The certificate must be a combined cert + **PKCS#8** key PEM (`BEGIN PRIVATE KEY`), which `deploy.ps1` generates. Delete `.work\*` and re-run to regenerate. |
| **`Certificate does not contain private key`** | `Certificate__Path` must point at the combined PEM (cert **and** key), not a cert-only file. |
| **Mutual TLS: the certificate is correct but the connection still fails** | Validation is an **exact SHA-1 thumbprint** match. Upload the exact `aiproxy-client.pfx`/PEM the container serves, and run the check from the Portal host. |
| **`401` on `/health` in a browser, cert installed** | The browser **did not send** the client cert (a thumbprint mismatch would drop the connection instead). On Windows the cert must carry the **Client Authentication** EKU to be offered; regenerate with `teardown.ps1 -PurgeWork` then `deploy.ps1 -InstallCertLocally`, and pick the cert when prompted. Postman/the Portal (explicit `.pfx`) are unaffected. |
| **`401` on an AI endpoint, valid cert** | Not a cert fault — the endpoint also wants a **Bearer JWT** issued by `/token`, which only the Portal flow obtains. |
| **`401` from OpenAI** on AI calls | The `ApiKey` in `.work\aiconfiguration.json` is empty or wrong. Edit the file and `docker compose restart`. |
| **`404` / model not found from OpenAI** | Each `ModelName` must be a valid OpenAI model id (for example `gpt-4o-mini`, `text-embedding-3-small`). |
| **`dbcontext` health reported as "degraded"** | Expected in SelfHosted mode with no SQL database — database access is stubbed and is not required for the mTLS/token flow. |
| **Port `7033`/`5298` already in use** | Re-run with `-HttpsPort` / `-HttpPort`, or stop the conflicting service. |

---

## Repository layout

```
DockerDesktop/
├── deploy.ps1                       one-command run (cert -> render config -> .env -> docker compose up -> smoke test)
├── teardown.ps1                     docker compose down + clean up local certs (optional .work/.env purge)
├── docker-compose.yml               the AI Proxy service (SelfHosted, no Key Vault, mTLS, host ports 7033/5298)
└── config/
    ├── aiconfiguration.json         OpenAI provider - 2026.2 schema (AiTaskTypesConfiguration + Id), key placeholder
    └── aiconfiguration.2026.1.json  OpenAI provider - 2026.1.x schema (MethodTypesConfiguration + Name)
```

Generated artifacts are written to `.work/` (certificates, the rendered `aiconfiguration.json` with
your real key, and `thumbprint.txt`) and `.env` (the Config UI admin key). Both are kept out of git by
the repository-root `.gitignore`.

---

## Notes & limitations

- **Sandbox, not production.** Self-signed certificate, a default cert password, the OpenAI key stored
  in a local file in cleartext, and a local container. Harden it (a real certificate/CA, a secret
  store, key rotation, and monitoring) before any production use.
- **The OpenAI key is in cleartext on disk.** It lives in `.work/aiconfiguration.json`, excluded by
  `.gitignore`. Treat that file — and `aiproxy-client.pfx` — as secrets.
- **Local-only by design.** The plain-HTTP port (host `5298`) is exposed for local convenience; do not
  publish it beyond your machine. The Portal must reach the proxy at `https://localhost:7033`, so it normally
  runs on the same host as Docker Desktop. For a public endpoint with secrets in Key Vault, use the
  [AzureContainerInstances](../AzureContainerInstances/) scenario instead.
