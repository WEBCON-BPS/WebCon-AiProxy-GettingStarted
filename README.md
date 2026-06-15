# WEBCON AI Proxy — Self-Hosted Getting Started

Ready-to-run samples for deploying a **self-hosted [WEBCON AI Proxy](https://hub.docker.com/r/webconbps/aiproxy)**
on Azure — with **mutual TLS** and secrets in **Azure Key Vault**. Each subdirectory is a complete,
**disposable, one-command** deployment for a specific compute target.

## Scenarios

| Scenario | What it deploys | Best for |
|---|---|---|
| [**AzureContainerInstances**](AzureContainerInstances/) | AI Proxy on **Azure Container Instances** (public mTLS endpoint) + **Key Vault** + an optional dedicated **Azure AI Foundry** (chat + embedding models), all in one resource group | Fast evaluation / demo, and debugging the **WEBCON Portal ↔ AI Proxy mTLS** handshake |

> More compute targets (e.g. a VM-based, fully network-private variant) can be added as sibling
> folders following the same pattern.

## Common prerequisites

- **Azure CLI** logged in (`az login`) as **Owner** on the target subscription
- **Docker** (running) and **OpenSSL**

The container image is pulled from the public Docker Hub repo
[`webconbps/aiproxy`](https://hub.docker.com/r/webconbps/aiproxy) — no source build or private
registry login required.

Open a scenario folder and follow its `README.md` for the full guide.

## ⚠️ These are sandboxes, not production templates

Self-signed certificates, default access keys, public container endpoints. Use them to learn and
demo; harden (real certs/CA, private networking, key rotation, monitoring) before any production use.
Generated certificates and private keys stay local — they are excluded from git by `.gitignore` and
must never be committed.
