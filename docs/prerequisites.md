# Prerequisites

Everything you need before deploying the Modern Work Dev SPSE environment with AZD layered provisioning.

## Required ISOs

You must supply two ISO files. The provisioning scripts mount these inside the VM to install SQL Server and SharePoint.

### SQL Server 2022 Enterprise

| Detail | Value |
|---|---|
| **Filename** | `enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso` |
| **Size** | ~1.4 GB |
| **Edition** | Enterprise (Developer edition also works) |

**Download locations** (pick one):

- **MSDN / Visual Studio Subscriptions**: <https://my.visualstudio.com/Downloads> → search "SQL Server 2022"
- **Volume Licensing Service Center (VLSC)**: <https://www.microsoft.com/licensing/servicecenter> → Product list → SQL Server 2022
- **Evaluation Center** (180-day trial): <https://www.microsoft.com/en-us/evalcenter/evaluate-sql-server-2022>

### SharePoint Subscription Edition

| Detail | Value |
|---|---|
| **Filename** | `en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso` |
| **Size** | ~1.5 GB |
| **Edition** | SharePoint Server Subscription Edition |

**Download locations** (pick one):

- **MSDN / Visual Studio Subscriptions**: <https://my.visualstudio.com/Downloads> → search "SharePoint Server Subscription"
- **Volume Licensing Service Center (VLSC)**: <https://www.microsoft.com/licensing/servicecenter> → Product list → SharePoint Server Subscription Edition

> **Note**: There is no public Evaluation Center download for SharePoint SE. You need an MSDN or volume-license entitlement.

## Upload ISOs and Scripts to Azure Storage

The VM downloads ISOs and provisioning scripts from Azure Storage blob containers during provisioning. First, run `azd provision storage` to create the storage account and containers, then use the unified upload script.

> **Note**: Place your ISO files in the `isos/` directory at the project root before running the upload script.

### Recommended: Unified Upload Script

The `upload-scripts.ps1` hook uploads **both** the `isos/` and `scripts/` directories to their respective blob containers in a single step:

```powershell
.\hooks\upload-scripts.ps1
```

This script reads the storage account name from the AZD environment. Run it after `azd provision storage` and before `azd provision compute`.

### Alternative: AzCopy (manual upload for large ISOs)

If you prefer to upload ISOs individually (e.g., for resumable transfers), you can use AzCopy:

```powershell
# Retrieve the auto-generated storage account name
azd env get-values | Select-String "STORAGE_ACCOUNT_NAME"
# Example output: STORAGE_ACCOUNT_NAME="abc123storage"
```

```bash
# 1. Login with AAD (recommended) — no SAS token needed
azcopy login

# 2. Upload with AzCopy (replace <storage-account> with the value from azd env get-values)
azcopy copy "isos/enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso" \
  "https://<storage-account>.blob.core.windows.net/isos/enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso"

azcopy copy "isos/en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso" \
  "https://<storage-account>.blob.core.windows.net/isos/en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso"
```

> **Tip**: AzCopy automatically splits files into blocks and uploads them in parallel. On a fast connection you can upload 1.5 GB in under 5 minutes.

## Azure Quota Requirements

| Resource | Minimum | How to check |
|---|---|---|
| **Dsv5 family vCPUs** | 8 | `az vm list-usage -l eastus --query "[?contains(name.value,'standardDSv5Family')]"` |
| **Total regional vCPUs** | 8 | `az vm list-usage -l eastus --query "[?name.value=='cores']"` |
| **Public IP addresses** | 1 | `az network list-usages -l eastus --query "[?contains(name.value,'PublicIPAddresses')]"` |

If you don't have enough quota, request an increase via the Azure Portal → **Subscriptions** → **Usage + quotas** → **Request increase**.

## Required CLI Tools

| Tool | Minimum Version | Install |
|---|---|---|
| **Azure CLI** (`az`) | 2.60+ | [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| **AZD CLI** (`azd`) | 1.9+ | [Install AZD](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) |
| **AzCopy** (optional) | 10.x | [Install AzCopy](https://learn.microsoft.com/azure/storage/common/storage-use-azcopy-v10) |

Verify versions:

```bash
az version --query '"azure-cli"' -o tsv    # should be ≥ 2.60
azd version                                 # should be ≥ 1.9.0
```

## Checklist

- [ ] Azure subscription with Contributor access
- [ ] Azure CLI ≥ 2.60 installed
- [ ] AZD CLI ≥ 1.9 installed
- [ ] `enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso` downloaded
- [ ] `en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso` downloaded
- [ ] Logged in: `azd auth login` and `az login`
- [ ] Storage layer provisioned: `azd provision storage`
- [ ] ISOs placed in the `isos/` directory at the project root
- [ ] ISOs and scripts uploaded: `.\hooks\upload-scripts.ps1`
- [ ] Sufficient vCPU quota in target region (≥ 8 Dsv5)
