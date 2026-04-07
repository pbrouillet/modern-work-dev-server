# SPSE Dev-Box Setup Flow — Complete Walkthrough

_Research date: 2026-04-04_

---

## Executive Summary

This workspace implements a fully-automated, 13-phase provisioning system that turns a bare Azure VM into a self-contained SharePoint Server Subscription Edition (SPSE) developer workstation. The system uses a state-machine pattern that survives reboots: a scheduled task re-invokes `bootstrap.ps1` as SYSTEM after every restart, picking up exactly where it left off. Phases are idempotent; a JSON state file (`C:\SPSESetup\state.json`) records per-phase status. The flow installs Active Directory Domain Services, SQL Server 2022, SharePoint SE, and Visual Studio 2026 — in that order — finishing with developer-convenience configuration targeting a standard Contoso lab domain.

There are **five reboots** embedded in the flow (Phases 3, 6, 8, 9, and optionally 12). Each is handled transparently by the orchestrator.

---

## Confidence Assessment

All findings below are sourced directly from the files listed in the request — no inference required. The only area of mild uncertainty is Phase 12: the VS 2026 bootstrapper URLs (`https://aka.ms/vs/18/...`) are noted in comments as _hypothetical_ pending official channel numbers, so the VS download step may fail silently and leave a desktop shortcut instead.

---

## Table of Contents

1. [Entry Points](#1-entry-points)
2. [Orchestrator — bootstrap.ps1](#2-orchestrator--bootstrapps1)
3. [Helper Modules](#3-helper-modules)
4. [Phase-by-Phase Walkthrough](#4-phase-by-phase-walkthrough)
5. [Configuration Files](#5-configuration-files)
6. [Reboot Cycle Mechanics](#6-reboot-cycle-mechanics)
7. [State Machine Details](#7-state-machine-details)
8. [Directory and File Inventory](#8-directory-and-file-inventory)
9. [End-to-End Timeline](#9-end-to-end-timeline)

---

## 1. Entry Points

### `scripts/README.txt`

The human-readable starting instruction: scripts are provisioned to `C:\Installs` by the Azure Custom Script Extension (CSE). To kick off setup manually, an administrator runs:

```
C:\Installs\Start-Setup.ps1
```

### `scripts/Start-Setup.ps1`

A thin wrapper. It reads `params.json` from the same directory (written by the CSE at VM deploy time) and invokes `bootstrap.ps1` with the parameters it finds there:

```powershell
$p = Get-Content $paramsFile -Raw | ConvertFrom-Json

& (Join-Path $PSScriptRoot 'bootstrap.ps1') `
    -IsoBlobUrl            $p.IsoBlobUrl `
    -SqlIsoFileName        $p.SqlIsoFileName `
    -SpIsoFileName         $p.SpIsoFileName `
    -DomainAdminPassword   $p.DomainAdminPassword `
    -SpFarmPassphrase      $p.SpFarmPassphrase
```

It does nothing else — all real logic is in `bootstrap.ps1`.

---

## 2. Orchestrator — `bootstrap.ps1`

`bootstrap.ps1` is the state-machine engine. It runs in two modes depending on whether `C:\SPSESetup\params.json` already exists:

### 2.1 First-Run Initialisation (no `params.json` on disk)

1. **Determine the active scripts directory.** If `C:\SPSESetup\scripts\bootstrap.ps1` exists, that's the canonical location. Otherwise, `$PSScriptRoot` (the CSE temp dir or `C:\Installs`) is used.
2. **Copy all scripts to the persistent setup root.** `C:\SPSESetup\scripts\` becomes the stable home for all helpers, phases, and config files so the scheduled task always has a valid path after a reboot.
3. **Dot-source helpers.** `Common.ps1`, `Download-FromBlob.ps1`, and `Wait-ForReboot.ps1` are loaded.
4. **Initialize environment.** `Initialize-SetupEnvironment` creates `C:\SPSESetup\` and `setup.log`.
5. **Persist parameters.** All command-line parameters are serialized to `C:\SPSESetup\params.json` with a SYSTEM-only ACL (inheritance disabled, only `NT AUTHORITY\SYSTEM FullControl`).
6. **Register the scheduled task** `SPSEBootstrap` (at-startup trigger, 60-second delay, runs as SYSTEM/highest privilege).

### 2.2 Resume After Reboot (`params.json` exists)

1. Load parameters from `params.json`.
2. Repopulate script-scope variables.
3. Re-dot-source helpers from the persistent `C:\SPSESetup\scripts\helpers\` path.

### 2.3 Phase Execution Loop

```
foreach phase in PhaseDefinitions (1 → 13):
    if phase.Status == "completed" and not -Force:
        skip
    if phase.Attempts >= 3 and not -Force:
        abort (human intervention needed)
    increment phase.Attempts, set status = "in-progress"
    dot-source the phase script
    call the phase function
    if result == "reboot":
        set status = "pending-reboot"
        Request-Reboot (shutdown /r /t 15 /f)
        exit 0   ← scheduled task will resume after restart
    if result == "success":
        Complete-Phase, set status = "completed"
```

### 2.4 Completion

When all 13 phases are `"completed"`:
- The scheduled task `SPSEBootstrap` is **unregistered**.
- `Write-CompletionSummary` records per-phase attempt counts to `C:\SPSESetup\completion-summary.txt`.
- A `COMPLETED` sentinel file is created at `C:\SPSESetup\COMPLETED`.

### Key Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `IsoBlobUrl` | _(required)_ | Base URL of the Azure Blob container holding ISOs |
| `SqlIsoFileName` | `enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso` | SQL Server ISO filename |
| `SpIsoFileName` | `en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso` | SharePoint SE ISO filename |
| `DomainAdminPassword` | _(required)_ | Used for DSRM, all service account passwords, SQL SA password |
| `SpFarmPassphrase` | _(required)_ | SharePoint farm passphrase |
| `DomainName` | `contoso.com` | FQDN of the AD domain to create |
| `DomainNetBIOS` | `CONTOSO` | NetBIOS name used to prefix service account names |
| `-Force` | _(switch)_ | Re-run already-completed phases |

---

## 3. Helper Modules

### `helpers/Common.ps1`

Provides all shared infrastructure used by every phase script.

| Function | Purpose |
|---|---|
| `Write-Log` | Timestamped console + file logging to `C:\SPSESetup\setup.log`. Levels: INFO / WARN / ERROR / DEBUG. |
| `Initialize-SetupEnvironment` | Creates `C:\SPSESetup\` and `setup.log` if they don't exist. |
| `Get-SetupState` / `Set-SetupState` | Read/write `state.json`. Tracks `CurrentPhase`, `CompletedPhases[]`, `StartTime`, `LastPhaseTime`, `Attempts{}` map. |
| `Complete-Phase` | Appends phase number to `CompletedPhases`, increments `CurrentPhase`, updates timestamp. |
| `Test-PhaseCompleted` | Returns `$true` if a phase number is in `CompletedPhases`. |
| `Get-PhaseAttempts` / `Add-PhaseAttempt` | Read/increment per-phase attempt counter stored in `state.json`. |
| `Invoke-WithRetry` | Generic retry wrapper. Configurable max retries (default 3) and delay (default 30s). Used by phases for service-availability polling and SP cmdlets. |

### `helpers/Wait-ForReboot.ps1`

Manages the lifecycle of the startup scheduled task.

| Function | Purpose |
|---|---|
| `Register-BootstrapTask` | Creates/replaces the `SPSEDevSetup-Bootstrap` scheduled task. Trigger: at-startup with 60s delay. Runner: SYSTEM with highest privileges. `RestartCount=3`, `RestartInterval=1min`. |
| `Unregister-BootstrapTask` | Removes the task when provisioning finishes. |
| `Test-BootstrapTaskExists` | Returns `$true` if the task is registered. |
| `Request-Reboot` | Issues `shutdown.exe /r /t 15 /f /d p:4:1` and returns the string `"reboot"`. Default delay 15 seconds, configurable 5–600. |

> **Note:** `bootstrap.ps1` has its own internal `Register-BootstrapTask` and `Unregister-BootstrapTask` functions that pre-date the helper versions. The helper version is the authoritative one used by phase scripts. Both are consistent in behavior.

### `helpers/Download-FromBlob.ps1`

Provides `Download-FromBlob` — used for downloading files from Azure Blob Storage.

**Authentication:** If no SAS token is provided, it acquires a bearer token from the VM's Managed Identity via the IMDS endpoint at `http://169.254.169.254/metadata/identity/oauth2/token`.

**Download strategy:**
1. **Primary (no bearer token):** BITS transfer via `Start-BitsTransfer`.
2. **Fallback / bearer-token primary:** `Invoke-WebRequest` with `Authorization: Bearer <token>` and `x-ms-version: 2020-04-08` headers. Progress bar suppressed for performance.

**Retry logic:** Up to `MaxRetries` attempts (default 3). Backoff: 30 × attempt_number seconds.

**Hash verification:** Optional SHA-256. Deletes file and throws if mismatch.

> **Note:** Phase 02 uses `azcopy` directly instead of this helper, because azcopy handles large ISOs more efficiently with built-in resumable transfers.

---

## 4. Phase-by-Phase Walkthrough

### Phase 01 — `01-InitDisks.ps1` — Initialize Data Disk

**What it does:**

Finds the first raw (unpartitioned) disk attached as LUN 0 by Bicep, and sets it up as the `F:` data drive:
1. `Initialize-Disk` as GPT.
2. `New-Partition` using the full disk size, assigned drive letter `F:`.
3. `Format-Volume` as NTFS with **64 KB allocation unit size** (required by SQL Server for optimal I/O).
4. Creates the standard directory tree:

| Directory | Purpose |
|---|---|
| `F:\SQLData` | SQL data files |
| `F:\SQLLogs` | SQL log files |
| `F:\SQLTempDB` | TempDB files |
| `F:\SPSearchIndex` | SharePoint Search index |
| `F:\Installers` | ISO and installer staging area |
| `C:\SPSESetup` | Bootstrap working directory |

**Reboot:** No  
**Dependencies:** None (first phase)  
**Idempotency:** Checks if `F:\` already exists; skips disk initialization if so.

---

### Phase 02 — `02-DownloadISOs.ps1` — Download ISOs

**What it does:**

Downloads the SQL Server 2022 and SharePoint SE ISOs from the blob container specified in `IsoBlobUrl`. Uses `azcopy.exe` with `AZCOPY_AUTO_LOGIN_TYPE=MSI` (Managed Identity authentication — no SAS token needed at runtime).

1. Searches for `azcopy.exe` in `%TEMP%\azcopy\` then `C:\Installs\`.
2. Downloads `$SqlIsoFileName` → `F:\Installers\{SqlIsoFileName}`.
3. Downloads `$SpIsoFileName` → `F:\Installers\{SpIsoFileName}`.
4. Verifies both files exist and exceed 100 MB.

**Config read:** `params.IsoBlobUrl`, `params.SqlIsoFileName`, `params.SpIsoFileName`  
**Reboot:** No  
**Dependencies:** Phase 01 (creates `F:\Installers\`), `azcopy.exe` pre-staged by CSE  
**Idempotency:** Skips a download if the file already exists and passes the 100 MB size check.

---

### Phase 03 — `03-PromoteADDC.ps1` — Promote to Domain Controller

**What it does:**

1. Installs Windows features: `AD-Domain-Services`, `DNS`, `RSAT-AD-Tools`, `RSAT-DNS-Server`.
2. Imports the `ADDSDeployment` module.
3. Checks if the server is already a DC for `$DomainName` (idempotent guard).
4. Calls `Install-ADDSForest` with:
   - `DomainName = params.DomainName` (default: `contoso.com`)
   - `DomainNetBIOSName = params.DomainNetBIOS` (default: `CONTOSO`)
   - Forest/Domain mode: `WinThreshold` (Windows Server 2016 functional level)
   - `InstallDns = $true`
   - DSRM password = `params.DomainAdminPassword`
   - `NoRebootOnCompletion = $true` (reboot managed by orchestrator)

**Reboot:** **Yes** — mandatory after AD DS forest creation. The function returns `"reboot"` after `Install-ADDSForest` completes.  
**Dependencies:** None (features only, no prior phase artifacts)  
**Idempotency:** `Get-ADDomain` check; returns `"success"` immediately if already a DC.

---

### Phase 04 — `04-ConfigureDNS.ps1` — Configure DNS

**What it does:**

Runs after the post-AD reboot, once DNS service is available.

1. **Waits** for DNS service status = `Running` (via `Invoke-WithRetry`).
2. **Sets DNS forwarders:**
   - `168.63.129.16` — Azure's internal DNS resolver (critical for Azure VM name resolution)
   - `8.8.8.8` — Google Public DNS (internet fallback)
3. **Creates DNS A record:** `portal.contoso.com` → `127.0.0.1` (loopback — the portal runs locally)
4. **Verifies** DNS resolution via `Resolve-DnsName` with `Invoke-WithRetry`.

**Config read:** `params.DomainName`  
**Reboot:** No  
**Dependencies:** Phase 03 (DNS Windows Feature and AD DS must be installed and post-reboot)  
**Idempotency:** Checks existing forwarders and the A record before making changes.

---

### Phase 05 — `05-CreateServiceAccounts.ps1` — Create AD Service Accounts

**What it does:**

1. **Waits** for AD DS operational state via `Get-ADDomain` with `Invoke-WithRetry`.
2. **Creates OU:** `OU=ServiceAccounts,DC=contoso,DC=com`
3. **Creates 8 service accounts** in that OU, all with `PasswordNeverExpires = $true`, enabled, using `params.DomainAdminPassword`:

| Account | Display Name | Purpose |
|---|---|---|
| `sp_setup` | SP Setup Admin | Runs farm provisioning; local admin |
| `sp_farm` | SP Farm Account | SharePoint farm account |
| `sp_services` | SP Service Apps | Service application pool identity |
| `sp_webapp` | SP Web App Pool | Web application pool identity |
| `sp_search` | SP Search Service | Search service application pool |
| `sp_content` | SP Content Access | Search content access account |
| `sql_svc` | SQL Server Service | SQL Server service identity |
| `sql_agent` | SQL Server Agent | SQL Server Agent identity |

4. **Adds `CONTOSO\sp_setup` to local Administrators** (required to run SharePoint provisioning cmdlets).

**Config read:** `params.DomainName`, `params.DomainNetBIOS`, `params.DomainAdminPassword`  
**Reboot:** No  
**Dependencies:** Phase 03 (AD DS), Phase 04 (DNS resolution for LDAP)  
**Idempotency:** `Get-ADUser -Filter` check before each `New-ADUser`; group membership exception handled.

---

### Phase 06 — `06-InstallSQLServer.ps1` — Install SQL Server 2022

**What it does:**

1. **Mounts** `F:\Installers\{SqlIsoFileName}` (reuses mount if already attached).
2. **Builds an unattended argument list** for `setup.exe`:

| Argument | Value | Reason |
|---|---|---|
| `/FEATURES` | `SQLENGINE,FULLTEXT,CONN,IS` | Core engine + full-text + connectivity + Integration Services |
| `/SQLCOLLATION` | `Latin1_General_CI_AS_KS_WS` | Required by SharePoint |
| `/SQLMAXDOP` | `1` | Required by SharePoint |
| `/SECURITYMODE` | `SQL` (mixed mode) | SA password enabled |
| `/SAPWD` | `DomainAdminPassword` | SA password |
| `/SQLSVCACCOUNT` | `CONTOSO\sql_svc` | Service identity |
| `/AGTSVCACCOUNT` | `CONTOSO\sql_agent` | Agent identity |
| `/SQLSYSADMINACCOUNTS` | `CONTOSO\sp_setup` + `BUILTIN\Administrators` | Farm setup needs sysadmin |
| `/SQLUSERDBDIR` | `F:\SQLData` | Data files to data drive |
| `/SQLUSERDBLOGDIR` | `F:\SQLLogs` | Log files to data drive |
| `/SQLTEMPDBDIR` /  `/SQLTEMPDBLOGDIR` | `F:\SQLTempDB` | TempDB to data drive |
| `/SQLTEMPDBFILECOUNT` | `8` | Performance best practice |
| `/UPDATEENABLED` | `False` | No mid-install patch download |

3. **Runs setup.exe**, waits for completion.
4. **Handles exit codes:** 0 (success), 3010 (success + reboot), others → dump summary log + throw.
5. **Dismounts ISO** in a `finally` block.

**Reboot:** **Yes** — always returns `"reboot"` (both exit code 0 and 3010 proceed to reboot).  
**Dependencies:** Phase 01 (F: drive), Phase 02 (ISO), Phase 05 (service accounts must exist)  
**Idempotency:** Not deeply idempotent — SQL Setup detects an existing instance and short-circuits cleanly.

---

### Phase 07 — `07-ConfigureSQLServer.ps1` — Configure SQL Server for SharePoint

**What it does:**

Post-install tuning and logins. Runs after the post-SQL reboot.

1. **Waits** for `MSSQLSERVER` service status = `Running` (up to 10 retries × 15s = 150s).
2. **Starts SQL Server Agent** (`SQLSERVERAGENT` service).
3. **Locates `sqlcmd.exe`** by scanning `C:\Program Files\Microsoft SQL Server\...` paths and `$PATH`.
4. **Runs T-SQL batches via sqlcmd** (Windows auth, `-E` flag):
   - `sp_configure 'show advanced options', 1` → `RECONFIGURE`
   - `sp_configure 'max server memory', 8192` → `RECONFIGURE` (8 GB cap)
   - `sp_configure 'max degree of parallelism', 1` → `RECONFIGURE` (MAXDOP=1, SP requirement)
   - `CREATE LOGIN [CONTOSO\sp_setup] FROM WINDOWS` + `dbcreator` + `securityadmin` roles
   - `CREATE LOGIN [CONTOSO\sp_farm] FROM WINDOWS`
5. **Verifies** both `sys.configurations` values and the two logins via `SELECT` queries.

**Config read:** `params.DomainNetBIOS`  
**Reboot:** No  
**Dependencies:** Phase 06 (SQL Server installed and post-reboot)  
**Idempotency:** `IF NOT EXISTS` guard in T-SQL for logins; `sp_configure` changes are always safe to re-apply.

---

### Phase 08 — `08-InstallSPPrereqs.ps1` — Install SharePoint Prerequisites

**What it does:**

1. **Mounts** `F:\Installers\{SpIsoFileName}`.
2. **Runs `prerequisiteinstaller.exe /unattended`** from the mounted ISO.
3. **Handles exit codes:**

| Code | Meaning | Action |
|---|---|---|
| 0 | All prerequisites installed | Continue → reboot |
| 3010 | Success, reboot required | Continue → reboot |
| 1001 | Pending restart blocking install | Trigger reboot to clear |
| 1002 | Component install failure | Log + throw (on Server 2025, this may be a false positive for built-in components) |
| Other | Failure | Dump log tail + throw |

4. **Intentionally leaves the ISO mounted** — Phase 09 needs it.
5. Locates the prerequisite installer log from `%TEMP%\prerequisiteinstaller.*.log` for diagnostics.

**Reboot:** **Yes** — always returns `"reboot"` (prerequisites require a restart).  
**Dependencies:** Phase 02 (SP ISO), Phase 01 (F: drive)  
**Idempotency:** `prerequisiteinstaller.exe` itself is idempotent; it skips already-installed components.

---

### Phase 09 — `09-InstallSPBinaries.ps1` — Install SharePoint Binaries

**What it does:**

Post-prerequisites reboot. Installs the SharePoint Server SE binaries.

1. **Ensures ISO is mounted** (mounts it if Phase 08 dismounted it — this phase handles both cases).
2. **Reads SharePoint product key** from `scripts/config/serials.json` (`sharepoint.productKey`). Falls back to the hardcoded value `QXNWY-QHCPC-BF3DK-J94F9-2YXC2` if the file isn't found.
3. **Writes an unattended `sp-setup-config.xml`** to `C:\SPSESetup\`:

```xml
<Configuration>
  <Display Level="none" CompletionNotice="no" AcceptEula="yes"/>
  <INSTALLLOCATION Value="C:\Program Files\Microsoft Office Servers\16.0"/>
  <Setting Id="SERVERPIDINKEY" Value="<key from serials.json>"/>
  <Setting Id="SETUPTYPE" Value="CLEAN_INSTALL"/>
  <Setting Id="SETUP_REBOOT" Value="Never"/>
  <!-- ... -->
</Configuration>
```

4. **Runs `setup.exe /config C:\SPSESetup\sp-setup-config.xml`**.
5. **Handles exit codes:** 0 (success), 3010 (success + reboot), 30066 (prerequisites not met → throw), others → dump log + throw.
6. **Dismounts ISO** in `finally`.

**Config read:** `scripts/config/serials.json` (`sharepoint.productKey`), `params.SpIsoFileName`  
**Reboot:** **Yes** — always returns `"reboot"`.  
**Dependencies:** Phase 08 (prerequisites), Phase 02 (ISO)  
**Idempotency:** SharePoint setup detects existing installation and returns success.

---

### Phase 10 — `10-ConfigureSPFarm.ps1` — Configure SharePoint Farm

**What it does:**

The largest phase. Runs as SYSTEM (which has local admin + SQL sysadmin rights by this point). All SP cmdlets use `Add-PSSnapin Microsoft.SharePoint.PowerShell`.

**Step 1 — Create configuration database:**
- `New-SPConfigurationDatabase` with wraps in `Invoke-WithRetry` (3 retries, 30s delay):
  - `DatabaseName = "SP_Config"`
  - `AdministrationContentDatabaseName = "SP_Admin_Content"`
  - `LocalServerRole = "SingleServerFarm"`
  - Farm credentials: `CONTOSO\sp_farm` with `DomainAdminPassword`
  - Passphrase: `params.SpFarmPassphrase`

**Step 2 — Initialize farm:**
- `Install-SPHelpCollection -All`
- `Initialize-SPResourceSecurity`
- `Install-SPService`
- `Install-SPFeature -AllExistingFeatures`
- `New-SPCentralAdministration -Port 9999 -WindowsAuthProvider NTLM`
- `Install-SPApplicationContent`

**Step 3 — Register managed accounts** (sp_services, sp_webapp, sp_search):
- `New-SPManagedAccount` for each if not already registered.

**Step 4 — Start service instances:**
- `SharePoint Server Search` → polls up to 300s for `Online` status.
- `Managed Metadata Web Service` → same polling.

**Step 5 — Search Service Application:**
- Creates app pool `SearchServiceAppPool` with account `CONTOSO\sp_search`.
- `New-SPEnterpriseSearchServiceApplication -Name "Search Service Application" -DatabaseName "SP_Search_AdminDB"`
- Creates proxy.
- Builds single-server search topology with all components: Admin, ContentProcessing, AnalyticsProcessing, Crawl, Index (at `F:\SPSearchIndex`), QueryProcessing.
- Activates topology via `Set-SPEnterpriseSearchTopology`.

**Step 6 — Managed Metadata Service:**
- Creates app pool `MMSServiceAppPool` with account `CONTOSO\sp_services`.
- `New-SPMetadataServiceApplication -Name "Managed Metadata Service" -DatabaseName "SP_ManagedMetadata"`
- Creates proxy in default proxy group with content type push-down, default keyword taxonomy, default site collection taxonomy.

**Config read:** `params.DomainNetBIOS`, `params.DomainAdminPassword`, `params.SpFarmPassphrase`  
**Reboot:** No  
**Dependencies:** Phase 09 (SP binaries), Phase 07 (SQL Server configured with sp_setup dbcreator/securityadmin), Phase 05 (service accounts exist)  
**Idempotency:** Every major step checks whether the artifact already exists before creating it.

---

### Phase 11 — `11-CreateSPWebApp.ps1` — Create SharePoint Web Application

**What it does:**

**Step 1 — Web application:**
- URL: `http://portal.contoso.com` (port 80, host-header based)
- Name: `SharePoint Portal`
- App pool: `SP_Portal_AppPool` with managed account `CONTOSO\sp_webapp`
- Content DB: `SP_Content_Portal`
- Auth: Windows Integrated (NTLM fallback) via `New-SPAuthenticationProvider`

**Step 2 — Root site collection:**
- URL: `http://portal.contoso.com`
- Owner: `CONTOSO\sp_setup`
- Name: `Contoso Portal`
- Template: `STS#3` (modern Team Site, no Microsoft 365 group). Falls back to `STS#0` (classic Team Site) if STS#3 isn't available.
- Content DB: `SP_Content_Portal`

**Step 3 — Alternate Access Mapping:**
- Ensures Default zone AAM points to `http://portal.contoso.com`.

**Step 4 — Site warm-up:**
- `Invoke-WebRequest -Uri http://portal.contoso.com -UseDefaultCredentials -TimeoutSec 120`
- Non-fatal if it fails (IIS may still be initializing).

**Step 5 — Developer dashboard:**
- `SPDeveloperDashboardLevel.On` — enables the query/timing diagnostic panel on every page.

**Config read:** `params.DomainNetBIOS`, `params.DomainName`  
**Reboot:** No  
**Dependencies:** Phase 10 (farm configured, managed accounts registered), Phase 04 (DNS A record for `portal.contoso.com`)  
**Idempotency:** `Get-SPWebApplication` and `Get-SPSite` checks before creation.

---

### Phase 12 — `12-InstallVS2026.ps1` — Install Visual Studio 2026 Enterprise

**What it does:**

**Pre-check:** Searches for `devenv.exe` in standard VS 2026 paths and via `vswhere.exe`. Returns `"success"` immediately if already installed.

**Bootstrapper download (two-stage fallback):**
1. **Blob storage:** Uses `azcopy` with `AZCOPY_AUTO_LOGIN_TYPE=MSI` to download `vs_enterprise.exe` from `$IsoBlobUrl/vs_enterprise.exe`.
2. **CDN fallback:** Tries `https://aka.ms/vs/18/release/vs_enterprise.exe` then `https://aka.ms/vs/18/pre/vs_enterprise.exe` via `Invoke-WebRequest`. _(Note: VS 2026 channel numbers are currently hypothetical.)_
3. **If both fail:** Creates `C:\Users\Public\Desktop\Install Visual Studio 2026.url` pointing to `https://visualstudio.microsoft.com/downloads/`, logs a warning, and returns `"success"` so provisioning continues.

**Silent installation arguments** (derived from `scripts/config/vs-workloads.json`):

| Argument | Value |
|---|---|
| `--quiet` | No UI |
| `--norestart` | Reboot managed by orchestrator |
| `--wait` | Block until done |
| `--includeRecommended` | Include recommended components |
| `--add Microsoft.VisualStudio.Workload.Office` | Office/SharePoint development |
| `--add Microsoft.VisualStudio.Workload.ManagedDesktop` | .NET desktop development |
| `--add Microsoft.VisualStudio.Workload.NetWeb` | ASP.NET / web development |
| `--add Microsoft.Component.NetFX.Native` | .NET Native |
| `--add Microsoft.VisualStudio.Component.SharePoint.Tools` | SharePoint project templates |

**Exit codes:** 0 → `"success"`, 3010 → `"reboot"`, 5007 (already installed) → `"success"`, other → throw.

**Config read:** `scripts/config/vs-workloads.json` (workloads and CDN URLs)  
**Reboot:** **Conditional** — `"reboot"` only if installer returns exit code `3010`.  
**Dependencies:** Phase 01 (F:\Installers directory)  
**Idempotency:** `devenv.exe` existence check at entry.

---

### Phase 13 — `13-FinalConfig.ps1` — Final Developer-Experience Configuration

The last phase. Applies quality-of-life settings and writes the completion summary.

**Step 1 — Disable IE Enhanced Security Configuration:**
- Sets `IsInstalled = 0` on both Admin and User registry keys under `HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7...}` and `{A509B1A8...}`.

**Step 2 — Create desktop shortcuts** (`C:\Users\Public\Desktop\`):
- `SP Central Administration.url` → `http://localhost:9999`
- `SharePoint Portal.url` → `http://portal.contoso.com`
- `Visual Studio 2026.lnk` → `devenv.exe` (searched in VS 2026 Enterprise/Preview paths)
- `SQL Server Management Studio.lnk` → `ssms.exe` (searched in SSMS 19/20, SQL Server 160/150 paths)

**Step 3 — Add portal to Local Intranet zone (zone 1):**
- `HKCU:\...ZoneMap\Domains\portal.contoso.com` → `http=1`, `https=1`
- `HKCU:\...ZoneMap\Domains\localhost` → `http=1`, `https=1` (for Central Admin)

**Step 4 — PowerShell execution policy:**
- `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine`

**Step 5 — Disable Windows Firewall (Domain profile):**
- `Set-NetFirewallProfile -Profile Domain -Enabled False`
- Logged as a dev-convenience measure not appropriate for production.

**Step 6 — Windows Explorer settings:**
- `HideFileExt = 0` (show file extensions)
- `Hidden = 1` (show hidden files)

**Step 7 — Write `C:\SPSESetup\setup-summary.txt`** containing:
- Start/end time and duration
- All phase numbers completed
- URLs (Central Admin + Portal)
- All service account names
- All SQL database names
- Key configuration notes

**Config read:** `params.DomainName`, `params.DomainNetBIOS`  
**Reboot:** No  
**Dependencies:** All prior phases (reads SetupState, looks up installed paths)  
**Idempotency:** All operations are guarded with existence checks.

---

## 5. Configuration Files

### `config/sp-farm-config.json`

Describes the intended SharePoint topology. **Phase 10 and 11 use hardcoded values that match this file** (the phases don't read this JSON directly — it serves as a reference document for the operator).

```json
{
  "farm": {
    "configDatabaseName": "SP_Config",
    "adminContentDatabaseName": "SP_Admin_Content",
    "centralAdminPort": 9999,
    "serverRole": "SingleServerFarm"
  },
  "serviceAccounts": {
    "farm": "sp_farm",     "services": "sp_services",
    "webApp": "sp_webapp", "search": "sp_search",
    "contentAccess": "sp_content", "setup": "sp_setup"
  },
  "serviceApplications": {
    "search": { "databaseName": "SP_Search_AdminDB", "indexLocation": "F:\\SPSearchIndex" },
    "managedMetadata": { "databaseName": "SP_ManagedMetadata" }
  },
  "webApplication": {
    "url": "http://portal.contoso.com", "port": 80,
    "databaseName": "SP_Content_Portal",
    "siteCollection": { "template": "STS#3", "fallbackTemplate": "STS#0" }
  }
}
```

### `config/serials.json`

Product license keys. Phase 09 reads `sharepoint.productKey` at runtime.

```json
{
  "sharepoint": { "productKey": "QXNWY-QHCPC-BF3DK-J94F9-2YXC2" },
  "sqlServer":  { "productKey": "" }
}
```

- SharePoint key: `QXNWY-QHCPC-BF3DK-J94F9-2YXC2` (SPSE)
- SQL Server key: empty — the ISO evaluation license or a VLSC key pre-applied to the ISO is used.

### `config/vs-workloads.json`

Read by Phase 12 for workload IDs and bootstrapper CDN URLs.

```json
{
  "bootstrapperUrls": {
    "release": "https://aka.ms/vs/18/release/vs_enterprise.exe",
    "preview": "https://aka.ms/vs/18/pre/vs_enterprise.exe"
  },
  "workloads": [
    "Microsoft.VisualStudio.Workload.Office",
    "Microsoft.VisualStudio.Workload.ManagedDesktop",
    "Microsoft.VisualStudio.Workload.NetWeb"
  ],
  "components": [
    "Microsoft.Component.NetFX.Native",
    "Microsoft.VisualStudio.Component.SharePoint.Tools"
  ],
  "installOptions": { "quiet": true, "norestart": true, "wait": true, "includeRecommended": true }
}
```

---

## 6. Reboot Cycle Mechanics

The system handles exactly 5 potential reboots:

| After Phase | Reason | Guaranteed? |
|---|---|---|
| 3 (PromoteADDC) | AD DS forest promotion | **Yes** |
| 6 (InstallSQLServer) | SQL Server installer requirement | **Yes** |
| 8 (InstallSPPrereqs) | SP prerequisites (dotnet, VC++ runtimes, etc.) | **Yes** |
| 9 (InstallSPBinaries) | SP binaries | **Yes** |
| 12 (InstallVS2026) | VS installer exit code 3010 | **Conditional** |

**Reboot sequence for a rebooting phase:**

```
bootstrap.ps1 runs phase N
Phase N returns "reboot"
bootstrap.ps1:
  1. Writes state.json: Phase N status = "pending-reboot"
  2. Calls Request-Reboot → shutdown.exe /r /t 15 /f
  3. Exits with code 0

[machine restarts]

Scheduled task SPSEDevSetup-Bootstrap fires (60s after startup)
bootstrap.ps1 runs as SYSTEM:
  1. params.json exists → loads saved parameters
  2. Phase N status = "pending-reboot" (not "completed")
  3. Phase N function re-runs
  4. Phase function detects its work is already done → returns "success"
  5. bootstrap.ps1 marks Phase N "completed"
  6. Proceeds to Phase N+1
```

The 60-second task startup delay ensures that all Windows services (AD, DNS, SQL) have time to reach a running state before provisioning resumes.

---

## 7. State Machine Details

### State File: `C:\SPSESetup\state.json`

Structure (written by bootstrap.ps1's `Save-State` function):

```json
{
  "Phases": {
    "Phase1": { "Status": "completed", "Attempts": 1, "StartedAt": "...", "CompletedAt": "..." },
    "Phase2": { "Status": "completed", "Attempts": 1, "StartedAt": "...", "CompletedAt": "..." },
    "Phase3": { "Status": "pending-reboot", "Attempts": 1, "StartedAt": "...", "CompletedAt": null }
  }
}
```

`Common.ps1` maintains a parallel, simpler state view:

```json
{
  "CurrentPhase": 4,
  "CompletedPhases": [1, 2, 3],
  "StartTime": "2026-04-04T10:00:00",
  "LastPhaseTime": "2026-04-04T10:47:22",
  "Attempts": { "1": 1, "2": 1, "3": 1 }
}
```

### Status Values

| Status | Meaning |
|---|---|
| `pending` | Not yet started |
| `in-progress` | Currently executing |
| `pending-reboot` | Completed but reboot not yet done |
| `completed` | Done and marked |
| `error` | Exception thrown; will retry on next run |

### Failure Handling

- Max attempts per phase: **3** (configurable via `$MaxAttempts` in bootstrap.ps1).
- On exception: phase status → `"error"`, bootstrap breaks the loop and exits. The scheduled task will re-invoke bootstrap after the system clock hits the next startup.
- On third failure: bootstrap logs the error and stops iterating. Human intervention is required (check `C:\SPSESetup\setup.log`).

### The `-Force` Switch

Adding `-Force` when invoking `bootstrap.ps1` skips all completed-phase and max-attempt guards, re-running every subsequent phase from the current position.

---

## 8. Directory and File Inventory

```
C:\Installs\            ← CSE staging area (scripts dropped here by the CSE)
    bootstrap.ps1
    Start-Setup.ps1
    params.json         ← Created by CSE before first run
    helpers\
    phases\
    config\

C:\SPSESetup\           ← Persistent working directory (created by Phase 01 / bootstrap)
    state.json          ← Phase state machine
    params.json         ← Persisted params (SYSTEM-only ACL)
    setup.log           ← Full execution log
    setup-summary.txt   ← Human-readable summary (written by Phase 13)
    completion-summary.txt ← Attempt/status breakdown (written by orchestrator)
    COMPLETED           ← Sentinel file (created when all phases done)
    sp-setup-config.xml ← SharePoint unattended setup config (written by Phase 09)
    scripts\            ← Persistent copy of all scripts
        bootstrap.ps1
        helpers\
        phases\
        config\

F:\                     ← Data drive initialized in Phase 01
    Installers\
        {SqlIsoFileName}
        {SpIsoFileName}
        vs_enterprise.exe  ← Downloaded in Phase 12
    SQLData\
    SQLLogs\
    SQLTempDB\
    SPSearchIndex\
```

---

## 9. End-to-End Timeline

```
[CSE invocation / manual Start-Setup.ps1]
    ↓
bootstrap.ps1 (First Run)
    ├── Copy scripts to C:\SPSESetup\scripts\
    ├── Save params.json (SYSTEM-only)
    ├── Register scheduled task SPSEDevSetup-Bootstrap
    ├── Phase 01: InitDisks           → F: drive ready
    ├── Phase 02: DownloadISOs        → ISOs in F:\Installers
    ├── Phase 03: PromoteADDC         → *** REBOOT #1 ***
[reboot]
bootstrap.ps1 (Resume)
    ├── Phase 03: re-enter → already DC → "success"
    ├── Phase 04: ConfigureDNS        → forwarders + portal A record
    ├── Phase 05: CreateServiceAccounts → 8 AD accounts
    ├── Phase 06: InstallSQLServer    → *** REBOOT #2 ***
[reboot]
bootstrap.ps1 (Resume)
    ├── Phase 06: re-enter → SQL found → "success"
    ├── Phase 07: ConfigureSQLServer  → memory, MAXDOP, logins
    ├── Phase 08: InstallSPPrereqs    → *** REBOOT #3 ***
[reboot]
bootstrap.ps1 (Resume)
    ├── Phase 08: re-enter → prereqs done → "success"
    ├── Phase 09: InstallSPBinaries   → *** REBOOT #4 ***
[reboot]
bootstrap.ps1 (Resume)
    ├── Phase 09: re-enter → SP installed → "success"
    ├── Phase 10: ConfigureSPFarm     → SP_Config, Central Admin, Search, MMS
    ├── Phase 11: CreateSPWebApp      → portal.contoso.com, site collection
    ├── Phase 12: InstallVS2026       → [*** REBOOT #5 if exit=3010 ***]
    └── Phase 13: FinalConfig         → shortcuts, IE ESC off, firewall off, summary
    
[All phases complete]
    ├── Unregister scheduled task
    ├── Write completion-summary.txt
    └── Create C:\SPSESetup\COMPLETED
```

---

## Footnotes

[^1]: `scripts/bootstrap.ps1:1-65` — parameter block and constants definition.
[^2]: `scripts/bootstrap.ps1:120-155` — `Save-Parameters` with SYSTEM-only ACL implementation.
[^3]: `scripts/bootstrap.ps1:170-228` — `Register-BootstrapTask` (internal version).
[^4]: `scripts/bootstrap.ps1:395-500` — main phase execution loop.
[^5]: `scripts/helpers/Common.ps1:1-50` — `Write-Log` and global constants.
[^6]: `scripts/helpers/Common.ps1:55-80` — `Initialize-SetupEnvironment`.
[^7]: `scripts/helpers/Common.ps1:120-250` — state persistence and phase tracking functions.
[^8]: `scripts/helpers/Wait-ForReboot.ps1:25-90` — `Register-BootstrapTask` (helper version, canonical).
[^9]: `scripts/helpers/Wait-ForReboot.ps1:120-145` — `Request-Reboot`.
[^10]: `scripts/helpers/Download-FromBlob.ps1:1-50` — authentication strategy (IMDS bearer token vs SAS).
[^11]: `scripts/helpers/Download-FromBlob.ps1:55-130` — BITS primary / WebRequest fallback download logic.
[^12]: `scripts/phases/01-InitDisks.ps1` — full file.
[^13]: `scripts/phases/02-DownloadISOs.ps1` — full file; azcopy MSI auth pattern.
[^14]: `scripts/phases/03-PromoteADDC.ps1` — full file; WinThreshold functional level.
[^15]: `scripts/phases/04-ConfigureDNS.ps1` — full file; Azure DNS forwarder 168.63.129.16.
[^16]: `scripts/phases/05-CreateServiceAccounts.ps1` — full file; 8 service accounts.
[^17]: `scripts/phases/06-InstallSQLServer.ps1` — full file; SQL setup arguments.
[^18]: `scripts/phases/07-ConfigureSQLServer.ps1` — full file; sqlcmd T-SQL batches.
[^19]: `scripts/phases/08-InstallSPPrereqs.ps1` — full file; exit code 1002 Server 2025 note.
[^20]: `scripts/phases/09-InstallSPBinaries.ps1` — full file; config.xml generation.
[^21]: `scripts/phases/10-ConfigureSPFarm.ps1` — full file; Search topology construction.
[^22]: `scripts/phases/11-CreateSPWebApp.ps1` — full file; developer dashboard enablement.
[^23]: `scripts/phases/12-InstallVS2026.ps1` — full file; bootstrapper CDN URLs noted as hypothetical.
[^24]: `scripts/phases/13-FinalConfig.ps1` — full file; IE ESC registry keys.
[^25]: `scripts/config/sp-farm-config.json` — full file.
[^26]: `scripts/config/serials.json` — full file.
[^27]: `scripts/config/vs-workloads.json` — full file.
[^28]: `scripts/README.txt` — instructions referencing C:\Installs.
