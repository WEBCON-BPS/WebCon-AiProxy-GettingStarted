# Kubernetes — WEBCON AI Proxy (Self-Hosted, Helm, OpenAI, no Key Vault)

> Part of [**WEBCON AI Proxy — Self-Hosted Getting Started**](../README.md). All commands below
> should be run from **this** directory (`Kubernetes/`).

This sample installs a self-hosted [**WEBCON AI Proxy**](https://hub.docker.com/r/webconbps/aiproxy)
on **Kubernetes** with the **public Helm chart**
[`webconbps/webcon-aiproxy`](https://hub.docker.com/r/webconbps/webcon-aiproxy), using a single command.
It uses **mutual TLS**, connects to **OpenAI**, and keeps secrets in **Kubernetes Secrets** (no Key Vault).

The same `deploy.ps1` and `values.yaml` work on:

- **Docker Desktop Kubernetes**: a local single-node cluster, no cloud account needed. The endpoint
  is `https://localhost:8081`.
- **Azure Kubernetes Service (AKS)**: the endpoint is the public IP of an Azure load balancer.

The script never creates a cluster; it deploys to whatever `kubectl` currently points at.

It is intended for the following scenarios:

- seeing what a Kubernetes/Helm deployment of the proxy looks like before writing your own values;
- running the WEBCON Portal ↔ AI Proxy mutual TLS handshake against a cluster, locally or on AKS.

> **Disposable by design.** One namespace, one release, three Secrets. Remove it all with
> `teardown.ps1`. This is a sandbox (see [Notes & limitations](#notes--limitations)), not a hardened
> production template.

---

## Contents

- [What it runs](#what-it-runs)
- [Prerequisites](#prerequisites)
- [Quick start: Docker Desktop](#quick-start-docker-desktop)
- [Running on AKS](#running-on-aks)
- [Configuration](#configuration)
- [Why a LoadBalancer and not an Ingress](#why-a-loadbalancer-and-not-an-ingress)
- [The web Config UI](#the-web-config-ui)
- [Configuring WEBCON Studio](#configuring-webcon-studio)
- [Verification](#verification)
- [Teardown](#teardown)
- [Troubleshooting](#troubleshooting)
- [Notes & limitations](#notes--limitations)

---

## What it runs

```
namespace aiproxy-gs
├─ Helm release "aiproxy"  (chart oci://registry-1.docker.io/webconbps/webcon-aiproxy)
│  ├─ Deployment webcon-aiproxy     1 replica, image webconbps/aiproxy:<appVersion>, non-root, read-only rootfs
│  │                                probes on HTTPS /health (no client cert needed)
│  ├─ Service    webcon-aiproxy     type LoadBalancer, port 8081 (HTTPS / mTLS)
│  └─ ConfigMap  webcon-aiproxy-config   aiconfiguration.json + appsettings.json (from values.yaml, no secrets)
└─ Secrets created by deploy.ps1 (never in values.yaml or Helm history)
   ├─ aiproxy-tls             tls.pem: combined cert + PKCS#8 key (HTTPS cert, mTLS trust, JWT signing key)
   ├─ aiproxy-config-admin    ConfigAdmin__AccessKey: Config UI login
   ├─ aiproxy-provider-keys   ProviderConnections__OpenAi__ProviderConfiguration__ApiKey
   └─ aiproxy-client-credentials   AppConfiguration__SelfHosted__ClientSecret (only with -ClientId/-ClientSecret)
```

The OpenAI key is injected as an **environment variable** that overrides the empty `ApiKey` in
`aiconfiguration.json` (.NET configuration: environment variables win over the JSON file). This is
how the chart keeps provider keys out of the ConfigMap.

---

## Prerequisites

- **kubectl** and **Helm 3.8+** (OCI chart support). Helm 4 works too.
- **OpenSSL** (if it is not on `PATH`, the script uses the copy bundled with **Git for Windows**).
- An **OpenAI API key** (`sk-...`) if you want AI calls to succeed. The proxy starts without one.
- A cluster: Docker Desktop Kubernetes or AKS (see below).

The chart and the image are both pulled from public Docker Hub; no registry login is needed.

---

## Quick start: Docker Desktop

Yes, this runs locally. Docker Desktop ships a single-node Kubernetes cluster:

1. **Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & restart.** It takes a few
   minutes the first time.
2. Point `kubectl` at it and deploy:

```powershell
kubectl config use-context docker-desktop
./deploy.ps1 -OpenAiApiKey "sk-..." -SmokeTest
```

Docker Desktop publishes `LoadBalancer` services on `localhost`, so the endpoint is
**`https://localhost:8081`**. Port `8081` must be free on the host; this scenario can run alongside
the [DockerDesktop](../DockerDesktop/) one (that one uses `7033`).

The script is **idempotent**: a re-run reuses the certificate in `.work/` and the Config UI key
already stored in the cluster, refreshes the Secrets, runs `helm upgrade --install`, and restarts the
pod so changed Secrets take effect.

---

## Running on AKS

Create a small cluster (or use an existing one), fetch credentials, and run the same script:

```powershell
az group create -n rg-aiproxy-k8s-gs -l westeurope
az aks create -g rg-aiproxy-k8s-gs -n aks-aiproxy-gs --tier free --node-count 1 --node-vm-size Standard_D2s_v5 --generate-ssh-keys
az aks get-credentials -g rg-aiproxy-k8s-gs -n aks-aiproxy-gs

./deploy.ps1 -OpenAiApiKey "sk-..." -SmokeTest
```

Azure assigns the `LoadBalancer` service a **public IP**; the script waits for it and prints
`https://<public-ip>:8081`. The Portal checks the server certificate by **thumbprint only**, so the
certificate's `CN=localhost` does not matter to it. A browser will warn about the name mismatch.

Remove everything (cluster included) with:

```powershell
./teardown.ps1
az group delete -n rg-aiproxy-k8s-gs --yes --no-wait
```

> On AKS the endpoint is **reachable from the internet**. Every endpoint except `/health` and
> `/config-ui` requires the client certificate, and the Config UI requires the access key. That is
> the same exposure as the [AzureContainerInstances](../AzureContainerInstances/) scenario. To narrow
> it, restrict the node resource group's NSG to the Portal's IP. For secrets from Azure Key Vault,
> sync them into the same three Secrets with the Secrets Store CSI driver or External Secrets; the
> chart reads them unchanged.

---

## Configuration

`deploy.ps1` parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-OpenAiApiKey <sk-...>` | reused from the cluster | Real OpenAI key. Stored only in the `aiproxy-provider-keys` Secret; a re-run without it keeps the stored one |
| `-ImageTag <tag>` | `2026.2.277.65` | AI Proxy release. The chart version is derived from it (`2026.2.277.65` → `2026.2.277-65`); the chart pins the matching image |
| `-ChartVersion <ver>` | derived | Explicit chart version override |
| `-Namespace <ns>` | `aiproxy-gs` | Target namespace (created if missing) |
| `-ClientId` / `-ClientSecret` | — (mTLS) | Pass both to authenticate the Portal with a client id/secret instead of mTLS (see below) |
| `-ConfigAdminAccessKey` | reused from the cluster, else auto-generated | Login key for the **web Config UI** |
| `-CertPassword` | `Sandbox!1` | Password for the exported client `.pfx` |
| `-InstallCertLocally` | off | Import the certificates into the `CurrentUser` store (server cert → Root, client cert → My) |
| `-SmokeTest` | off | Check `/health` and request a token from `/token` at the end (mTLS or client id/secret) |

Everything that is not a secret lives in [`values.yaml`](values.yaml): the image repository, the
`LoadBalancer` service, references to the three Secrets, and the full `aiconfiguration.json` and
`appsettings.json`. Edit the models there (same 2026.2 schema as the other scenarios) and re-run
`deploy.ps1`.

### Client id/secret instead of mutual TLS

```powershell
./deploy.ps1 -OpenAiApiKey "sk-..." -ClientId "<client-id>" -ClientSecret "<client-secret>" -SmokeTest
```

The script stores the secret in a fourth Secret, `aiproxy-client-credentials`, and installs the chart
with `selfHosted.requireClientCertificate=false`, `selfHosted.clientId` and a
`secrets.appSettings` entry for `AppConfiguration__SelfHosted__ClientSecret`. No endpoint then asks
for a client certificate; `/token` accepts only the configured pair (a wrong one gets `401`). The
certificate is still the TLS server certificate and the JWT signing key. Enter the same client id and
secret in WEBCON Studio. Re-run without the two parameters to return to mTLS.

For every option the chart offers (persistence for Config UI edits, per-role certificates,
`requireClientCertificate: false` with a client id/secret, NetworkPolicy, ServiceMonitor), see
`helm show readme oci://registry-1.docker.io/webconbps/webcon-aiproxy --version 2026.2.277-65`.

---

## Why a LoadBalancer and not an Ingress

The proxy authenticates the Portal by comparing the **client certificate thumbprint** with its own.
An HTTP Ingress (nginx, Traefik, Application Gateway) terminates TLS. The pod would then see the
ingress' connection and no client certificate, and the Portal would see the ingress' server
certificate. A `LoadBalancer` service forwards TCP unchanged, so the TLS session, client certificate
included, ends in the pod. If you need an ingress, it must use **TLS passthrough**. The chart
deliberately ships without one.

---

## The web Config UI

Open **`https://<endpoint>:8081/config-ui`** (for Docker Desktop:
[`https://localhost:8081/config-ui`](https://localhost:8081/config-ui)) and log in with the access key
`deploy.ps1` printed. Dismiss the browser's client-certificate prompt; `/config-ui` does not need it.
Run `deploy.ps1 -InstallCertLocally` first to avoid the TLS warning on Docker Desktop.

The chart seeds `aiconfiguration.json` from the ConfigMap onto a writable volume, so UI edits apply
immediately (hot-reload). Persistence is **off** in this sample, so **UI edits are lost when the
pod restarts**, including on every `deploy.ps1` re-run. Make lasting changes in `values.yaml`, or set
`persistence.enabled: true` (a PVC; Docker Desktop and AKS both provide a default StorageClass).

---

## Configuring WEBCON Studio

In **WEBCON Studio → System configuration → Global parameters**:

1. Select **SelfHosted AI Proxy** as the AI mode.
2. Set the **AI Proxy URL** to the endpoint the script printed, **with no trailing slash**.
3. **mTLS (default):** upload `.work/aiproxy-client.pfx` (and its password) or `.work/certificate.pem`.
   It must be the same certificate the pod serves. **Client id/secret mode:** enter the same pair you
   passed to `deploy.ps1`.
4. Restart the **WEBCON Service** and the Portal (IIS).

---

## Verification

`deploy.ps1 -SmokeTest` checks:

| Request | Expected | Proves |
|---|---|---|
| `GET /health`, no cert | `200 Healthy` | the pod is up and the LoadBalancer forwards traffic |
| `POST /token`, no cert | `401` | mutual TLS is enforced |
| `POST /token`, client cert | `200` + `access_token` | the certificate is accepted and a JWT is issued |

With `-ClientId`/`-ClientSecret` the two `/token` checks become: wrong secret → `401`, configured
pair (no certificate) → `200` + `access_token`.

The manual PowerShell snippet in the [DockerDesktop README](../DockerDesktop/README.md#verification)
works here too; replace `localhost:7033` with the endpoint.

```powershell
kubectl get pods,svc -n aiproxy-gs
kubectl logs -n aiproxy-gs deploy/webcon-aiproxy -f
```

---

## Teardown

```powershell
./teardown.ps1                 # helm uninstall + delete the namespace (and its Secrets) + remove imported certs
./teardown.ps1 -KeepLocalCerts # leave the imported certs in the CurrentUser store
./teardown.ps1 -PurgeWork      # also delete .work\ (the generated certificate)
```

`teardown.ps1` acts on the **current** `kubectl` context; it prints the context first.

---

## Troubleshooting

| Symptom | Cause and resolution |
|---|---|
| **`No current kubectl context`** | Enable Kubernetes in Docker Desktop, or run `az aks get-credentials`. |
| **`helm` cannot pull the chart** | Helm older than 3.8 has no OCI support; upgrade. Chart versions use a dash before the last part: `2026.2.277-65`. |
| **Service stuck without an address** | Docker Desktop: another process already holds port `8081` on the host. AKS: check `kubectl describe svc webcon-aiproxy -n aiproxy-gs` for load balancer events (quota, policy). |
| **Pod in `CrashLoopBackOff`** | `kubectl logs -n aiproxy-gs deploy/webcon-aiproxy --previous`. *"Incorrect run for every connector"* or a model `Id` error means the `aiconfiguration.json` schema does not match the image; *"No RSA private key found"* means the PEM key is not PKCS#8 (delete `.work\` and re-run). |
| **Config UI login rejected** | Use the key the script printed: `kubectl get secret aiproxy-config-admin -n aiproxy-gs -o jsonpath='{.data.ConfigAdmin__AccessKey}'` (base64). |
| **Config UI edits disappeared** | Expected: persistence is off and the pod was restarted. See [The web Config UI](#the-web-config-ui). |
| **`401` from OpenAI on AI calls** | No or wrong key. Re-run `./deploy.ps1 -OpenAiApiKey "sk-..."`; the script restarts the pod. |
| **mTLS fails behind an ingress / gateway** | Something terminates TLS. See [Why a LoadBalancer](#why-a-loadbalancer-and-not-an-ingress). |

---

## Notes & limitations

- **Sandbox, not production.** Self-signed certificate, default `.pfx` password, OpenAI key in a plain
  Kubernetes Secret (base64, not encrypted unless the cluster encrypts Secrets at rest).
- **Single replica by design.** The chart fixes `replicas: 1` because the Config UI writes the config
  to the pod's own volume.
- **`.work/` holds the private key** (`certificate.pem`, `aiproxy-client.pfx`). It is excluded by the
  repository-root `.gitignore`.
