# Copilot Instructions — Modern Work DevSPSE

## Project overview

Automated Azure deployment of a single-VM SharePoint Server Subscription Edition dev environment on Windows Server 2025. Deploys AD DS, DNS, SQL Server 2022, SharePoint SE, and Visual Studio 2026 on one VM via a reboot-safe PowerShell state machine.

## Architecture

AZD deployment with a preprovision hook and two Bicep layers (`azure.yaml` defines layers `landingzone` and `compute`):

1. **Preprovision hook** (`hooks/preprovision.ps1`) — Creates the storage account (name matches `uniqueString(resourceGroup().id)`) and `scripts`/`isos` blob containers via `az` CLI, assigns RBAC, uploads `scripts/` and `isos/` to blob storage, and persists `storageAccountName` into azd env variables. Runs before any Bicep layer so blobs are available when the VM CSE fires. Has `continueOnError: false`.
2. **`azd provision landingzone`** — Creates VNet (2 subnets), NSG, Public IP, ACR, Log Analytics, App Insights, and Container Apps Environment. The CAE is here because its first deploy takes 15-20 min to warm up VNet infrastructure — keeping it in this early layer avoids ARM timeout issues in later layers. Do not move CAE resources to other layers.
3. **`azd provision compute`** — Deploys VM, NIC, storage VNet rule, and RBAC. The storage account (created by preprovision) is re-declared here to add the VNet service-endpoint rule.

Post-provision hooks (run after all layers):
- `hooks/build-rdp-bridge.ps1` — Builds rdp-bridge container on ACR via `az acr build`, creates/updates the Container App via CLI (not Bicep, to avoid ARM timeout on VNet-integrated CAE). Has `continueOnError: false` — deployment fails if this hook fails.
- `hooks/postprovision.ps1` — Secures storage firewall (Deny + VNet rule). Has `continueOnError: true`.
- `hooks/generate-rdp.ps1` — Generates `spsedev.rdp` from azd env outputs. Has `continueOnError: true`.

**Storage is CLI-managed, not Bicep.** The storage account, containers, and blob uploads are created by `hooks/preprovision.ps1` using `az` CLI commands. This avoids the race condition where the VM's CSE tries to download scripts before they exist. The `infra/storage/` directory contains an orphaned Bicep layer (kept for reference) — it is not referenced by `azure.yaml`. Do not add it back as a layer.

When adding new hooks to `azure.yaml`, set `continueOnError: false` for hooks that are critical to a working deployment, `true` for best-effort convenience steps.

The VM extension (`vm-extension.bicep`) downloads scripts via azcopy with managed identity, writes `params.json`, then launches `scripts/Start-Setup.ps1` → `scripts/bootstrap.ps1`. The CSE script itself is `infra/compute/modules/extensions-script.ps1.tpml` — a PowerShell template with `__TOKEN__` placeholders (e.g., `__STORAGE_ACCOUNT_NAME__`) replaced by chained `replace()` calls in the Bicep. Edit the `.tpml` file, not a standalone `.ps1`.

**VM blob access uses managed identity + azcopy, never SAS tokens.** The VM's system-assigned identity has Storage Blob Data Contributor on the storage account. The CSE sets `AZCOPY_AUTO_LOGIN_TYPE=MSI` and runs `azcopy copy` to download blobs. Do not introduce SAS tokens or `listAccountSas()` — managed identity is the only auth mechanism for VM-to-storage access.

**Container App is CLI-managed, not Bicep.** The Container App's first-revision creation on a VNet-integrated CAE takes 20+ minutes, exceeding the ARM deployment timeout. The `build-rdp-bridge.ps1` hook creates it via `az containerapp create` (which has no hard timeout) and updates it with the real image, env vars, and RBAC roles. Do not move the Container App back into Bicep. Note: `infra/compute/modules/container-app.bicep` exists but is **not referenced** by any `main.bicep` — it is an orphaned module. Do not add a module reference to it.

### RDP bridge

`rdp-bridge/` is a Rust/Axum WebSocket proxy that implements the MS-TSGU (RD Gateway HTTP transport) protocol. It runs on Azure Container Apps and provides RD Gateway access to Azure VMs without exposing port 3389 publicly.

With `RDP_BRIDGE_IN_AZURE=true`, the bridge acts as a multi-VM RD Gateway: it uses the client-supplied server name from the MS-TSGU Channel Create message to resolve an Azure VM, checks its power state via ARM REST API, starts it if deallocated, waits for it to become RDP-reachable (sending keepalives to prevent mstsc timeout), then tunnels the RDP connection.

The bridge uses `clap` for CLI argument parsing — all options support both `--long-flag` and environment variable forms (e.g., `--in-azure` / `RDP_BRIDGE_IN_AZURE`). Run `rdp-bridge --help` for usage.

Built remotely on ACR via `az acr build` (no local Docker Desktop required).

## Bootstrap state machine

`scripts/bootstrap.ps1` orchestrates 13 phases sequentially with reboot support:

- **Phase pattern**: `scripts/phases/NN-PhaseName.ps1` exports `Invoke-PhaseNN-PhaseName`
- **Idempotency contract**: Each phase checks existing state first, then acts. Returns `"success"` to continue or `"reboot"` to restart the VM and resume.
- **State tracking**: `C:\SPSESetup\state.json` tracks per-phase `Status`, `Attempts`, and timestamps
- **Parameters**: `C:\SPSESetup\params.json` (SYSTEM-only ACL) holds deployment config
- **Completion marker**: `C:\SPSESetup\COMPLETED` file indicates all phases finished
- **Startup task**: A scheduled task re-enters `bootstrap.ps1` after each reboot

Phases in order: InitDisks → DownloadISOs → PromoteADDC → ConfigureDNS → CreateServiceAccounts → InstallSQLServer → ConfigureSQLServer → InstallSPPrereqs → InstallSPBinaries → ConfigureSPFarm → CreateSPWebApp → InstallVS2026 → FinalConfig.

### Phase script conventions

Every phase script follows this exact pattern:

```powershell
function Invoke-PhaseNN-PhaseName {
    Write-Log "Phase NN - PhaseName: Starting ..."

    # Idempotency check — skip if already done
    if (<already-done condition>) {
        Write-Log "Already completed — skipping"
        return "success"  # or "reboot" if a reboot is needed
    }

    try {
        # ... do work ...
        Write-Log "Phase NN - PhaseName: Completed successfully"
        return "success"
    }
    catch {
        Write-Log "ERROR: $_" -Level Error
        throw
    }
}
```

Key rules:
- Use `Write-Log` (from `helpers/Common.ps1`) for all output, never bare `Write-Host`
- Return `"success"` or `"reboot"` — no other return values
- Wrap destructive operations in try/catch and re-throw after logging
- Check existing state first (idempotency) before acting

### Script execution contexts

**Hook scripts** (`hooks/*.ps1`) run on the **developer's machine** with PowerShell 7 (pwsh). They use `az` CLI, Entra ID auth, and `$ErrorActionPreference = 'Stop'`. All hooks resolve resource names from `azd env get-values` output via regex (some define a reusable `Get-EnvValue` helper). Follow this pattern when creating or modifying hooks — do not hard-code resource names or use alternative config sources.

**Phase scripts** (`scripts/phases/*.ps1`) run on the **VM** with Windows PowerShell 5.1 under `NT AUTHORITY\SYSTEM`. They use `Write-Log`, managed identity, and the bootstrap state machine. Avoid PS7-only syntax (e.g., ternary `?:`, `??=`, pipeline chain `&&`) in phase scripts.

## Dev environment constraints

The developer runs on a **Microsoft Dev Box**. This has important implications:

- **No Docker Desktop**: Dev Boxes do not have Docker Desktop. The rdp-bridge container is built remotely on ACR via `az acr build`. Never add local Docker build steps.
- **Multiple egress IPs**: Dev Boxes route through several paths. When whitelisting IPs in storage firewall rules, always use `/24 CIDR ranges`, not individual IPs.
- **No storage account keys**: Corporate policy blocks storage account key access. Always use `--auth-mode login` (Entra ID / RBAC) and managed identity. Never add key-auth fallbacks — they will always fail. Every `az storage blob` command must explicitly include `--auth-mode login`.
- **Storage firewall lifecycle**: Storage deploys with `Allow` during the storage layer. `hooks/upload-scripts.ps1` temporarily opens firewall rules for the upload, then restores them. `hooks/postprovision.ps1` re-secures the account to `Deny` with a VNet exception for the VM subnet.

## Key conventions

- **Naming**: `vm-spse-<env>`, `vnet-spse-<env>`, `nsg-spse-<env>`, `ca-rdpbridge-<env>`, `stspse<uniqueString>`
- **Config files**: `scripts/config/serials.json` (product keys), `scripts/config/sp-farm-config.json`, `scripts/config/vs-workloads.json`
- **VM paths**: `C:\SPSESetup` (state/logs), `C:\Installs` (staged scripts), `F:\` (data disk for installers/SQL data)
- **ISOs in `isos/`**: Use actual VLSC filenames (long names with hashes), not shortened aliases

## Build / test

No repo-wide test or lint harness. Validation is:

- `az bicep build --file infra/landingzone/main.bicep`, `az bicep build --file infra/storage/main.bicep`, and `az bicep build --file infra/compute/main.bicep` for Bicep compilation (all three layers)
- PowerShell parse check: `Get-ChildItem scripts -Recurse -Filter *.ps1 | ForEach-Object { $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $_.FullName -Raw), [ref]$null) }`
- `cargo build --release` in `rdp-bridge/` for the Rust proxy

**Compiled ARM templates (`main.json`) are checked into the repo** alongside `.bicep` source files. Always edit `.bicep` files and recompile with `az bicep build` — never edit `main.json` directly.
