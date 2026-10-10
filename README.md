# WEBCON AI Proxy — Self-Hosted Getting Started

Ready-to-run samples for deploying a **self-hosted [WEBCON AI Proxy](https://hub.docker.com/r/webconbps/aiproxy)**
with **mutual TLS**: on Azure with secrets in **Azure Key Vault**, fully local on **Docker Desktop**,
or on **Kubernetes** (Docker Desktop or AKS) with the public Helm chart. Each subdirectory is a
complete, **disposable, one-command** deployment for a specific compute target.

## Scenarios

| Scenario | What it deploys | Best for |
|---|---|---|
| [**AzureContainerInstances**](AzureContainerInstances/) | AI Proxy on **Azure Container Instances** (public mTLS endpoint) + **Key Vault** + an optional dedicated **Azure AI Foundry** (chat + embedding models), all in one resource group | Fast cloud evaluation / demo, and debugging the **WEBCON Portal ↔ AI Proxy mTLS** handshake |
| [**DockerDesktop**](DockerDesktop/) | AI Proxy on **local Docker Desktop** (mTLS) connected to **OpenAI**, with **no Key Vault**; secrets in local files | Running the proxy entirely on a dev machine, with no Azure account |
| [**Kubernetes**](Kubernetes/) | AI Proxy installed with the public **Helm chart** `webconbps/webcon-aiproxy` on the current `kubectl` context (**Docker Desktop Kubernetes** locally, or **AKS**), OpenAI, secrets in Kubernetes Secrets | Trying the Helm-based deployment locally first, then the same values on AKS |

> More compute targets (e.g. a VM-based, fully network-private variant) can be added as sibling
> folders following the same pattern.

All scenarios default to **`2026.2.277.65`**. Changes since the previous default (`2026.2.135.35`)
that affect these samples:

- **Key Vault certificate setting renamed.** `AppConfiguration__AzureKeyVault__SecretName` was removed;
  use `AppConfiguration__SelfHosted__Certificate__SecretName`. With Key Vault on, the TLS server
  certificate is now read from Key Vault as well. The ACI scenario is updated; older deployments must
  rename the variable.
- **`/health` no longer requires a client certificate**, so load balancers and Kubernetes probes can
  use it. The smoke tests now prove mTLS on `POST /token` instead (`401` without a cert).
- **Optional:** separate certificates per role (HTTPS, mTLS, JWT signing), and a client id/secret
  alternative to mTLS (`RequireClientCertificate=false`). The samples keep one certificate; the
  DockerDesktop and Kubernetes scripts switch to client id/secret with `-ClientId`/`-ClientSecret`.
- **Public Helm chart** on Docker Hub: `oci://registry-1.docker.io/webconbps/webcon-aiproxy`,
  used by the Kubernetes scenario.
- **Gemini 3.x** models (EU multi-region Vertex AI), and action generation in AI Process Builder.

The **web Config UI** (`/config-ui` over HTTPS) and the per-connection `TimeoutSeconds` from
2026.2.135.35 are unchanged. See each scenario's README for details.

## Common prerequisites

- **OpenSSL**, required by all scenarios. If it is not on `PATH`, the deploy scripts fall back to the
  copy bundled with **Git for Windows**.
- **Docker** (running) for AzureContainerInstances and DockerDesktop.
- **kubectl** and **Helm 3.8+** for Kubernetes.
- **Azure CLI** logged in (`az login`) as **Owner** on the target subscription, for
  **AzureContainerInstances** (and to create an AKS cluster).

The container image is pulled from the public Docker Hub repo
[`webconbps/aiproxy`](https://hub.docker.com/r/webconbps/aiproxy) and the chart from
[`webconbps/webcon-aiproxy`](https://hub.docker.com/r/webconbps/webcon-aiproxy). No source build or
private registry login is required.

Open a scenario folder and follow its `README.md` for the full guide.

## ⚠️ These are sandboxes, not production templates

Self-signed certificates, default access keys, public container endpoints. Use them to learn and
demo; harden (real certs/CA, private networking, key rotation, monitoring) before any production use.
Generated certificates and private keys stay local. They are excluded from git by `.gitignore` and
must never be committed.
