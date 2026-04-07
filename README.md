# Modern Work Dev SPSE — Automated SharePoint SE Development Environment

Fully automated provisioning of a single-VM SharePoint Subscription Edition development environment on Azure using **AZD layered provisioning**. A preprovision hook creates the storage account and uploads ISOs/scripts, then two Bicep layers—`landingzone` (VNet, ACR, CAE, Container App) and `compute` (VM + RBAC)—deploy the infrastructure. An RDP bridge (Rust/Axum WebSocket proxy) running on Azure Container Apps provides RD Gateway access to the VM without opening port 3389 publicly. The VM runs 13 unattended phases—from Active Directory promotion through SharePoint farm creation and Visual Studio 2026 installation—delivering a ready-to-use dev box in ~2–3 hours.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Azure Resource Group                                               │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Windows Server 2025 VM  (Standard_D8ds_v5)                │    │
│  │                                                             │    │
│  │   Active Directory DC  (contoso.com)                        │    │
│  │   SQL Server 2022 Enterprise                                │    │
│  │   SharePoint Subscription Edition                           │    │
│  │   Visual Studio 2026 Enterprise                             │    │
│  │                                                             │    │
│  │   Central Admin ─── http://localhost:9999                   │    │
│  │   Portal ────────── http://portal.contoso.com               │    │
│  └───────────────────────────────┬─────────────────────────────┘    │
│                                  │ 10.0.1.x (snet-default)          │
│  ┌───────────────────────────────┴─────────────────────────────┐    │
│  │  VNet 10.0.0.0/16                                           │    │
│  │    snet-default ─────── 10.0.1.0/24  (VM + Storage SE)      │    │
│  │    snet-container-apps ─ 10.0.4.0/23  (CAE delegation)      │    │
│  └───────────────────────────────┬─────────────────────────────┘    │
│                                  │                                   │
│  ┌───────────────────────────────┴─────────────────────────────┐    │
│  │  Container Apps Environment (VNet-integrated)               │    │
│  │  ┌───────────────────────────────────────────────────────┐  │    │
│  │  │  rdp-bridge  (Rust/Axum WebSocket proxy)              │  │    │
│  │  │  • RD Gateway protocol (MS-TSGU) over WebSocket       │  │    │
│  │  │  • Azure VM lifecycle: start/stop on connect          │  │    │
│  │  │  • mstsc → wss://gateway → TCP 3389 on VM            │  │    │
│  │  └───────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │  Public IP    │  │  NSG         │  │  ACR (rdp-bridge image)  │  │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Storage Account (ISOs + Scripts)                            │   │
│  │    isos/    ── SQL Server 2022 ISO, SharePoint SE ISO        │   │
│  │    scripts/ ── bootstrap.ps1, phases/, helpers/, config/     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Observability: Log Analytics + Application Insights         │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

> See [`docs/architecture.md`](docs/architecture.md) for the full deployment layer breakdown and RDP bridge details.

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure subscription** | Contributor role (or Owner if assigning RBAC) |
| **Azure CLI** | `az` ≥ 2.60 |
| **AZD CLI** | `azd` ≥ 1.9 |
| **vCPU quota** | Minimum **8 vCPUs** in the **Dsv5** family in your target region |
| **SQL Server 2022 ISO** | `enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso` — download from MSDN, VLSC, or the [Eval Center](https://www.microsoft.com/en-us/evalcenter/evaluate-sql-server-2022) |
| **SharePoint SE ISO** | `en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso` — download from MSDN or VLSC |

> **No local Docker Desktop required** — the rdp-bridge container is built remotely on ACR via `az acr build`.

> See [`docs/prerequisites.md`](docs/prerequisites.md) for detailed download instructions and ISO upload guidance.

## Quick Start

This project uses **AZD layered provisioning** with a preprovision hook and two Bicep layers:

1. **Preprovision hook** — Creates storage account + blob containers (`isos`, `scripts`), uploads ISOs and scripts
2. **`landingzone` layer** — VNet, NSG, Public IP, ACR, Log Analytics, App Insights, Container Apps Environment
3. **`compute` layer** — VM, NIC, storage VNet rule, RBAC

Post-provision hooks automatically: build the rdp-bridge container on ACR, create/update the Container App, secure the storage firewall, and generate an RDP file.

```powershell
# 1. Login & initialize
azd auth login
azd init                          # If not already initialized

# 2. Place ISOs in the isos/ directory

# 3. Full deployment (preprovision + 2 layers + post hooks)
azd up
# Prompts for: environment name, location, admin password, farm passphrase
# Preprovision hook creates storage & uploads ISOs/scripts automatically.

# 4. Connect via RDP
# Open the auto-generated spsedev.rdp file:
mstsc spsedev.rdp
```

### Step-by-Step (first deployment)

```powershell
# Provision everything (preprovision creates storage, then Bicep layers deploy)
azd provision

# Or provision individual layers:
azd provision landingzone
azd provision compute
.\hooks\postprovision.ps1       # Secure storage firewall
.\hooks\generate-rdp.ps1        # Generate spsedev.rdp
```

## Connecting via RDP Bridge

The rdp-bridge provides RD Gateway access over HTTPS/WebSocket — no port 3389 exposure needed.

After `azd up`, a `spsedev.rdp` file is auto-generated at the repo root. Double-click to connect:

1. mstsc prompts for gateway credentials — enter any username/password (the bridge uses no-auth by default)
2. mstsc prompts for VM credentials — enter `spadmin` and your admin password
3. The bridge resolves the VM name, checks if it's running, starts it if deallocated, and tunnels RDP

> **VM auto-start**: With `RDP_BRIDGE_IN_AZURE=true`, connecting to a deallocated VM will automatically start it. mstsc shows "Configuring remote session..." while the VM boots.

### Direct RDP (fallback)

If the bridge is unavailable, connect directly via the VM's public IP (requires port 3389 open in NSG):

```powershell
mstsc /v:$(azd env get-values | Select-String 'vmFqdn' | ForEach-Object { $_ -replace '.*="([^"]+)".*','$1' })
```

### Access Points (on the VM)

| Service | URL |
|---|---|
| Central Administration | http://localhost:9999 |
| SharePoint Portal | http://portal.contoso.com |
| Visual Studio 2026 | Desktop shortcut |

### Default Credentials

Login with **CONTOSO\spadmin** (domain administrator) or **CONTOSO\sp_setup** (SharePoint setup account). The password is the `adminPassword` you provided during deployment.

## VM Sizing

| SKU | vCPUs | RAM | Recommendation |
|---|---|---|---|
| **Standard_D8ds_v5** (default) | 8 | 32 GB | Good for light development and testing |
| **Standard_E8ds_v5** | 8 | 64 GB | Recommended if you experience memory pressure |

To change the size, update the `vmSize` parameter in `main.bicep` or pass it as an AZD parameter.

## Provisioning Timeline

The full provisioning runs **~2–3 hours unattended** across 13 phases:

| # | Phase | ~Duration |
|---|---|---|
| 1 | OS configuration & data disk setup | 5 min |
| 2 | AD DS promotion (+ reboot) | 10 min |
| 3 | DNS & AD post-reboot configuration | 5 min |
| 4 | Service account creation | 2 min |
| 5 | SQL Server 2022 install | 15 min |
| 6 | SQL Server post-configuration | 5 min |
| 7 | SharePoint prerequisites | 20 min |
| 8 | SharePoint binary install (+ reboot) | 25 min |
| 9 | SharePoint farm creation | 10 min |
| 10 | Service applications (Search, MMS) | 15 min |
| 11 | Web application & site collection | 5 min |
| 12 | Visual Studio 2026 install | 30 min |
| 13 | Final validation & cleanup | 5 min |

## Troubleshooting

On the VM, check:

- **Provisioning log**: `D:\SPSESetup\setup.log`
- **Phase state**: `D:\SPSESetup\state.json`

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for common issues and fixes.

## Service Accounts

All accounts are created in the **CONTOSO** domain during Phase 4:

| Account | Purpose |
|---|---|
| `CONTOSO\sp_setup` | SharePoint setup / install account |
| `CONTOSO\sp_farm` | SharePoint farm account |
| `CONTOSO\sp_services` | Service application pool identity |
| `CONTOSO\sp_webapp` | Web application pool identity |
| `CONTOSO\sp_search` | SharePoint Search service account |
| `CONTOSO\sp_content` | Search content access (crawl) account |

## Parameters Reference

| Parameter | Description | Default | Required |
|---|---|---|---|
| `environmentName` | AZD environment name (used as resource prefix) | — | Yes |
| `location` | Azure region for all resources | — | Yes |
| `adminPassword` | Password for VM admin and all domain/service accounts | — | Yes |
| `farmPassphrase` | SharePoint farm passphrase | — | Yes |
| `sqlIsoFilename` | SQL Server ISO blob name | `enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso` | No |
| `spIsoFilename` | SharePoint ISO blob name | `en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso` | No |
| `vmSize` | Azure VM SKU | `Standard_D8ds_v5` | No |
| `vmName` | VM computer name | `YOURVM` | No |
| `domainName` | Active Directory domain FQDN | `contoso.com` | No |
| `domainNetBIOS` | NetBIOS name for the domain | `CONTOSO` | No |

> **Note**: `storageAccountName` is auto-generated by the **storage** layer and carried to the **compute** layer via AZD environment variables — you do not need to set it manually. The VM accesses blobs via managed identity (no storage keys or SAS tokens).

## License

Internal use — Microsoft ISD/Modern Work team.
