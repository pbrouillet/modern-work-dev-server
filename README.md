# Modern Work Dev SPSE — Automated SharePoint SE Development Environment

Fully automated provisioning of a single-VM SharePoint Subscription Edition and Exchange Server SE development environment on Azure using **AZD layered provisioning**.

A preprovision hook creates the storage account and uploads ISOs/scripts, then two Bicep layers—`landingzone` (VNet, ACR, CAE) and `compute` (VM + RBAC)—deploy the infrastructure.

An RDP bridge (Rust/Axum WebSocket proxy) running on Azure Container Apps provides RD Gateway access to the VM without opening port 3389 publicly.

The VM runs up to 19 unattended phases—from Active Directory promotion through SharePoint farm creation, optional Exchange Server SE, Visual Studio 2026 installation, and developer-tool provisioning via winget—delivering a ready-to-use dev box in ~2–3 hours.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Azure Resource Group                                               │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Windows Server 2025 VM  (Standard_D8ds_v5)                 │    │
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
│                                  │                                  │
│  ┌───────────────────────────────┴─────────────────────────────┐    │
│  │  Container Apps Environment (VNet-integrated)               │    │
│  │  ┌───────────────────────────────────────────────────────┐  │    │
│  │  │  rdp-bridge  (Rust/Axum WebSocket proxy)              │  │    │
│  │  │  • RD Gateway protocol (MS-TSGU) over WebSocket       │  │    │
│  │  │  • Azure VM lifecycle: start/stop on connect          │  │    │
│  │  │  • mstsc → wss://gateway → TCP 3389 on VM             │  │    │
│  │  └───────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │  Public IP   │  │  NSG         │  │  ACR (rdp-bridge image)  │   │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘   │
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

The full provisioning runs **~2–3 hours unattended** across up to 19 phases:

| # | Phase | ~Duration | Notes |
|---|---|---|---|
| 1 | Init disks (data drive) | 2 min | |
| 2 | Download ISOs from blob storage | 10 min | |
| 3 | Promote AD DS domain controller (+ reboot) | 10 min | |
| 4 | Configure DNS (forwarders, portal A record) | 2 min | |
| 5 | Create service accounts | 2 min | |
| 6 | Install SQL Server 2022 (+ reboot) | 15 min | |
| 7 | Configure SQL Server (memory, MAXDOP, logins) | 5 min | |
| 8 | SharePoint prerequisites (+ reboot) | 20 min | |
| 9 | SharePoint binaries install (+ reboot) | 25 min | |
| 10 | Configure SharePoint farm (Central Admin, Search, MMS) | 15 min | |
| 11 | Create web application & site collection | 5 min | |
| 14 | Install Exchange prerequisites (+ reboot) | 15 min | Conditional (`EnableExchange`) |
| 15 | Install Exchange Server SE | 30 min | Conditional (`EnableExchange`) |
| 16 | Configure Exchange | 10 min | Conditional (`EnableExchange`) |
| 17 | Install Visual Studio 2026 | 30 min | |
| 18 | Final OS/dev-experience config | 5 min | Loopback fix, IIS, shortcuts |
| 19 | Install optional software (winget) | 10 min | Per `config/winget-packages.json` |

> Phases 14–16 only run when `EnableExchange` is set to `True`.

## Troubleshooting

On the VM, check:

- **Provisioning log**: `C:\SPSESetup\setup.log`
- **Phase state**: `C:\SPSESetup\state.json`

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for common issues and fixes.

### Replaying Specific Phases

To re-run individual phases without repeating the entire provisioning (e.g., after uploading fixed scripts):

```powershell
# On the VM — replay phases 7, 10, and 18:
.\Start-Setup.ps1 -ReplayPhases 7,10,18
```

This resets the attempt counter and status for only the specified phases, skipping all others.

## Optional Software (winget)

Phase 19 installs developer tools via winget from [`scripts/config/winget-packages.json`](scripts/config/winget-packages.json). Default packages include VS Code, Git, Chrome, Azure CLI, PowerShell 7, and more. Edit the JSON to add or remove packages. Failures are best-effort and never block provisioning.

## Service Accounts

All accounts are created in the **CONTOSO** domain during Phase 5:

| Account | Purpose |
|---|---|
| `CONTOSO\sp_setup` | SharePoint setup / install account |
| `CONTOSO\sp_farm` | SharePoint farm account |
| `CONTOSO\sp_services` | Service application pool identity |
| `CONTOSO\sp_webapp` | Web application pool identity |
| `CONTOSO\sp_search` | SharePoint Search service account |
| `CONTOSO\sp_content` | User Profile / content access account |
| `CONTOSO\sp_cache` | Distributed Cache service account |
| `CONTOSO\sp_apps` | App Management service account |
| `CONTOSO\sp_supuser` | Object Cache super user |
| `CONTOSO\sp_supreader` | Object Cache super reader |

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
| `enableExchange` | Enable Exchange Server SE phases (14–16) | `False` | No |
| `exchangeIsoFilename` | Exchange Server SE ISO blob name | `ExchangeServerSE-x64.iso` | No |

> **Note**: `storageAccountName` is auto-generated by the **preprovision hook** and carried to the **compute** layer via AZD environment variables — you do not need to set it manually. The VM accesses blobs via managed identity (no storage keys or SAS tokens).

## License

Internal use — Microsoft ISD/Modern Work team.
