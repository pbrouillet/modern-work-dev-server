# Troubleshooting

Common issues encountered during Modern Work Dev SPSE provisioning and how to resolve them.

## Checking Provisioning Progress

RDP into the VM and inspect:

| File | Purpose |
|---|---|
| `D:\SPSESetup\setup.log` | Detailed log output from all phases |
| `D:\SPSESetup\state.json` | Machine-readable phase status (completed, failed, pending) |

```powershell
# View current state
Get-Content D:\SPSESetup\state.json | ConvertFrom-Json | Format-Table Phase, Status, StartTime, EndTime

# Tail the live log
Get-Content D:\SPSESetup\setup.log -Tail 50 -Wait
```

---

## DC Promotion Failures on Azure VMs

**Symptom**: Phase 2 (AD DS promotion) fails with "The operation failed because the server could not find the domain controller for the domain" or the VM becomes unreachable after reboot.

**Causes & Fixes**:

1. **DNS loop**: Azure VNet DNS is set to the VM's own IP before AD DS is ready.
   - The bootstrap script sets DNS to 127.0.0.1 during promotion then switches to the VM's static IP post-reboot. If the NIC's DNS was changed prematurely, reset it:
     ```powershell
     Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 127.0.0.1
     ```
   - Retry the phase.

2. **DSRM password policy**: The DSRM password must meet complexity requirements.
   - Ensure your `adminPassword` has uppercase, lowercase, digits, and special characters (min 12 chars).

3. **VM unreachable after promotion reboot**: Azure sometimes takes 2–5 minutes to reassign the public IP after a reboot. Wait and retry RDP.

---

## SQL Server Collation Warnings

**Symptom**: SQL Server installs successfully but logs a warning about collation `Latin1_General_CI_AS_KS_WS` during SharePoint configuration database creation.

**Fix**: This is expected. SharePoint requires this specific collation and the install script passes `/SQLCOLLATION="Latin1_General_CI_AS_KS_WS"`. The warning occurs if SQL was previously installed with a different collation. No action needed if the SharePoint farm creates successfully.

If you do need to change collation on an existing SQL instance, a reinstall is required—SQL Server collation cannot be changed after installation.

---

## SharePoint Prerequisite Failures on Server 2025

**Symptom**: `prerequisiteinstaller.exe` fails or hangs, or reports missing prerequisites on Windows Server 2025.

**Causes & Fixes**:

1. **Known Server 2025 compatibility**: SharePoint SE prerequisites were originally designed for Server 2019/2022. Some prerequisites are built into Server 2025.
   - The phase script uses `/unattended` mode and installs prerequisites manually when the auto-installer fails.
   - If prerequisites still fail, install them manually:
     ```powershell
     # Common missing prerequisites on Server 2025
     Install-WindowsFeature NET-WCF-HTTP-Activation45
     Install-WindowsFeature NET-WCF-Pipe-Activation45
     Install-WindowsFeature NET-WCF-TCP-Activation45
     ```

2. **Internet connectivity**: The prerequisite installer downloads components from Microsoft. Ensure the VM has outbound internet access (the NSG allows this by default).

3. **Reboot required**: Some prerequisites require a reboot before continuing. The phase script handles this automatically, but if running manually, reboot and re-run.

---

## Custom Script Extension Timeout

**Symptom**: The Azure deployment shows the Custom Script Extension (CSE) as timed out or failed, but provisioning is actually still running on the VM.

**Explanation**: The CSE has a maximum timeout (typically 90 minutes). The full 13-phase provisioning takes 2–3 hours, so the CSE intentionally launches the remaining phases as a background scheduled task and exits. The CSE completing (or timing out) does **not** mean provisioning failed.

**What to do**:

1. Wait for the full provisioning time (~2–3 hours from deployment start).
2. RDP into the VM and check `D:\SPSESetup\state.json` to see which phases have completed.
3. If `azd up` reports a CSE failure but `state.json` shows phases progressing, everything is fine.

---

## Re-Running a Failed Phase

If a phase fails and you need to retry it:

### Option 1: Edit state.json

```powershell
# On the VM, open state.json
$state = Get-Content D:\SPSESetup\state.json | ConvertFrom-Json

# Reset the failed phase to "pending"
$state.phases | Where-Object { $_.phase -eq 7 } | ForEach-Object { $_.status = "pending" }

# Save
$state | ConvertTo-Json -Depth 10 | Set-Content D:\SPSESetup\state.json

# Re-run the bootstrap
D:\SPSESetup\bootstrap.ps1
```

### Option 2: Run the phase script directly

```powershell
# Run a specific phase with -Force to skip the state check
D:\SPSESetup\phases\phase07-sp-prereqs.ps1 -Force
```

> **Caution**: Some phases depend on previous phases. Check the phase dependencies before re-running out of order.

---

## Memory Pressure Symptoms

**Symptom**: The VM becomes very slow, SharePoint application pools crash, or SQL Server reports insufficient memory. Event Viewer shows resource exhaustion warnings.

**Fix**: The default VM size (Standard_D8ds_v5, 32 GB RAM) can be tight when running AD + SQL + SharePoint + VS simultaneously.

1. **Immediate relief** — stop non-essential services:
   ```powershell
   # Stop Search if not needed right now
   Get-SPServiceInstance | Where-Object { $_.TypeName -like "*Search*" } | Stop-SPServiceInstance -Confirm:$false

   # Stop Visual Studio background processes
   Get-Process -Name "devenv", "ServiceHub*" -ErrorAction SilentlyContinue | Stop-Process -Force
   ```

2. **Permanent fix** — resize the VM:
   ```bash
   # From your local machine
   az vm deallocate -g <resource-group> -n <vm-name>
   az vm resize -g <resource-group> -n <vm-name> --size Standard_E8ds_v5
   az vm start -g <resource-group> -n <vm-name>
   ```
   Standard_E8ds_v5 provides 64 GB RAM — enough for comfortable all-in-one development.

---

## DNS Resolution Issues (portal.contoso.com)

**Symptom**: Browsing to `http://portal.contoso.com` returns "page not found" or DNS errors.

**Fixes**:

### On the VM itself

The VM is the domain controller, so it should resolve `portal.contoso.com` via its own DNS. If not:

```powershell
# Verify DNS zone exists
Get-DnsServerZone -Name contoso.com

# Add the A record if missing
Add-DnsServerResourceRecordA -Name portal -ZoneName contoso.com -IPv4Address 127.0.0.1
```

### From your local workstation

Your local machine doesn't know about `contoso.com`. Add a hosts file entry:

- **Windows**: Edit `C:\Windows\System32\drivers\etc\hosts` (as Administrator)
- **macOS/Linux**: Edit `/etc/hosts`

```
<vm-public-ip>  portal.contoso.com
```

### IIS binding mismatch

Ensure the SharePoint IIS site has the correct host header binding:

```powershell
Get-WebBinding -Name "SharePoint Portal"
# Should show: http *:80:portal.contoso.com
```

---

## SharePoint Farm Creation Failures

**Symptom**: `New-SPConfigurationDatabase` or `Connect-SPConfigurationDatabase` fails with permission or access errors.

**Common causes**:

1. **SQL permissions**: The farm account (`sp_farm`) must have `dbcreator` and `securityadmin` server roles in SQL.
   ```powershell
   # Verify SQL permissions
   Invoke-Sqlcmd -Query "SELECT name, type_desc FROM sys.server_principals WHERE name LIKE '%sp_farm%'"
   Invoke-Sqlcmd -Query "SELECT r.name AS role, m.name AS member FROM sys.server_role_members rm JOIN sys.server_principals r ON rm.role_principal_id = r.principal_id JOIN sys.server_principals m ON rm.member_principal_id = m.principal_id WHERE m.name LIKE '%sp_farm%'"
   ```

2. **Setup account not in local Administrators**: The `sp_setup` account must be a local administrator on the server and must have `dbcreator` + `securityadmin` roles.
   ```powershell
   net localgroup Administrators CONTOSO\sp_setup /add
   ```

3. **Farm passphrase mismatch**: If you're joining an existing farm (not applicable for single-server, but just in case), ensure the passphrase matches exactly.

4. **SQL Server not listening on TCP**: Verify SQL is accepting TCP connections:
   ```powershell
   Test-NetConnection -ComputerName localhost -Port 1433
   ```

---

## Visual Studio 2026 Bootstrapper URL Not Found

**Symptom**: Phase 12 fails because the VS 2026 bootstrapper URL returns 404 or the download fails.

**Explanation**: The bootstrapper URLs in `vs-workloads.json` use hypothetical channel numbers (`/vs/18/`). If VS 2026 isn't released yet or uses different channel numbers, the download will fail.

**Fixes**:

1. **Update the URL**: Edit `scripts/config/vs-workloads.json` and update the `bootstrapperUrls` with the correct URLs from the [Visual Studio downloads page](https://visualstudio.microsoft.com/downloads/).

2. **Manual install**: Download the VS installer manually, copy it to the VM, and run:
   ```powershell
   $config = Get-Content D:\SPSESetup\config\vs-workloads.json | ConvertFrom-Json
   $workloads = ($config.workloads | ForEach-Object { "--add $_" }) -join " "
   $components = ($config.components | ForEach-Object { "--add $_" }) -join " "

   # Run the installer with the same workloads/components from config
   Start-Process -FilePath "C:\path\to\vs_enterprise.exe" `
     -ArgumentList "--quiet --norestart --wait --includeRecommended $workloads $components" `
     -Wait
   ```

3. **Use VS 2022 instead**: If VS 2026 is not yet available, update the bootstrapper URLs to point to VS 2022:
   ```json
   {
     "release": "https://aka.ms/vs/17/release/vs_enterprise.exe",
     "preview": "https://aka.ms/vs/17/pre/vs_enterprise.exe"
   }
   ```

---

## Storage Layer Provisioned but Compute Fails

**Symptom**: `azd provision storage` succeeds, but `azd provision compute` fails with errors about missing blobs, storage account access, or the Custom Script Extension cannot download scripts.

**Causes & Fixes**:

1. **ISOs not uploaded**: The compute layer expects ISO files in the `isos` container. Verify they are present:
   ```powershell
   $acct = (azd env get-values | Select-String "STORAGE_ACCOUNT_NAME").ToString().Split("=")[1].Trim('"')
   az storage blob list -c isos --account-name $acct --query "[].name" -o tsv
   ```
   You should see `enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso` and `en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso`. If not, upload them before running `azd provision compute`.

2. **Provisioning scripts not uploaded**: The Custom Script Extension downloads `bootstrap.ps1` and supporting scripts from the `scripts` container. If you forgot to run the upload script:
   ```powershell
   .\hooks\upload-scripts.ps1
   ```

3. **SAS token generation failure**: The compute layer auto-generates a SAS token via `listAccountSas` in Bicep. If this fails, ensure the deploying identity has the **Storage Account Contributor** role (or equivalent) on the storage account created by the storage layer.

---

## How to Re-Provision Just the Compute Layer

If you need to redeploy the VM without recreating the storage account (e.g., after fixing ISOs or scripts):

```powershell
azd provision compute
```

This provisions only the network, VM, and VM extension resources. The storage layer is left untouched, so your uploaded ISOs and scripts remain in place.

> **Tip**: To tear down and redeploy everything, run `azd down` followed by `azd provision` (which runs both layers sequentially).

---

## Other Tips

- **Check Windows Event Viewer**: Application and System logs often contain useful error details that don't appear in `setup.log`.
- **SharePoint logs**: ULS logs are at `C:\Program Files\Common Files\Microsoft Shared\Web Server Extensions\16\LOGS\`.
- **SQL Server error log**: `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Log\ERRORLOG`.
- **Reboot recovery**: The provisioning uses `state.json` to track progress. After any unexpected reboot, the scheduled task picks up where it left off.
