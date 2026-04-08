# SharePoint + Exchange Server Coexistence — Known Issues & Fixes

> **Environment**: SharePoint Server Subscription Edition + Exchange Server SE  
> **Server**: vm-spse-ccmsdev.contoso.com (single-server, all-in-one dev topology)  
> **Documented**: 2026-04-08  
> **Fix Script**: `phases/20-FixSPExchangeCoexistence.ps1`

---

## Why This Document Exists

Installing Exchange Server on a machine that already hosts SharePoint Server
introduces several conflicts that are **not caught by either installer**.
Microsoft does not support this topology for production use, but it is common
for dev/lab environments. This document captures every issue we hit and the
exact remediation, so the fixes can be re-applied after future CU patching.

---

## Issue 1 — Exchange CLR Host Config Breaks SharePoint Assembly Resolution

### Symptom

SharePoint Portal and/or Central Administration return **HTTP 500** with:

```
System.IO.FileNotFoundException: Could not load file or assembly
'System.Collections.Immutable, Version=1.1.37.0, Culture=neutral,
PublicKeyToken=b03f5f7f11d50a3a' or one of its dependencies.
The system cannot find the file specified.
```

Stack trace begins at `Microsoft.SharePoint.HostServices..ctor()` →
`RequestInstrumentationScopeManager..cctor()`, meaning the SharePoint
request pipeline cannot even initialize.

### Root Cause

Exchange Server sets the **CLRConfigFile** property on the **IIS
applicationPoolDefaults** (or on every individual pool) to:

```
C:\Program Files\Microsoft\Exchange Server\V15\bin\GenericAppPoolConfigWithGCServerEnabledFalse.config
```

This Exchange-specific config includes assembly binding redirects for its own
dependencies. The critical one is:

```xml
<dependentAssembly>
  <assemblyIdentity name="System.Collections.Immutable"
                    publicKeyToken="b03f5f7f11d50a3a" culture="neutral" />
  <bindingRedirect oldVersion="0.0.0.0-5.0.0.0" newVersion="5.0.0.0" />
</dependentAssembly>
```

This redirects **all** versions of `System.Collections.Immutable` to **5.0.0.0**.
SharePoint requests version **1.1.37.0** (which exists in the GAC), but the
redirect sends the CLR looking for 5.0.0.0, which does **not** exist.

The Fusion (Assembly Binding Log) confirms:

```
LOG: Using host configuration file:
  C:\Program Files\Microsoft\Exchange Server\V15\bin\GenericAppPoolConfigWithGCServerEnabledFalse.config
LOG: GAC Lookup was unsuccessful.
LOG: All probing URLs attempted and failed.
```

### Why It's Hard to Diagnose

- The DLL **is** in the GAC at the expected path — manual checks look fine
- The binding redirect is not in `web.config` or `machine.config` — it's in a
  **CLR host config file** that most admins never check
- The redirect is set on every IIS app pool, so it can affect SharePoint,
  Central Admin, and service application pools

### Fix

Clear the `CLRConfigFile` property on all SharePoint-owned application pools:

```powershell
Import-Module WebAdministration
$spPools = Get-ChildItem IIS:\AppPools | Where-Object {
    $_.Name -like "SP_*" -or $_.Name -like "SharePoint*" -or
    $_.Name -in @("SecurityTokenServiceApplicationPool","AppMgmtServiceAppPool",
                   "MMSServiceAppPool","UPAServiceAppPool")
}
foreach ($pool in $spPools) {
    Set-ItemProperty "IIS:\AppPools\$($pool.Name)" -Name "CLRConfigFile" -Value ""
}
```

Then recycle all affected app pools (or run `iisreset`).

### Persistence Warning

**Exchange CU updates will likely re-apply this setting.** After any Exchange
patching, re-run `phases/20-FixSPExchangeCoexistence.ps1`.

---

## Issue 2 — SharePoint Web Services Root App Pool Stopped

### Symptom

SharePoint sites load extremely slowly or time out. Service application
features (Managed Metadata, User Profile, Search, etc.) are non-functional.

### Root Cause

The **SharePoint Web Services Root** application pool is in a `Stopped` state
with `autoStart = False`. This pool hosts service application endpoints on
ports **32843** (HTTP) and **32844** (HTTPS). Without it, SharePoint web
applications cannot communicate with any service application.

The exact trigger is unclear but is correlated with Exchange installation or
repeated PSConfig runs.

### Fix

```powershell
Import-Module WebAdministration
Set-ItemProperty "IIS:\AppPools\SharePoint Web Services Root" -Name "autoStart" -Value $true
Start-WebAppPool "SharePoint Web Services Root"
```

---

## Issue 3 — Search Service Event 6481 (Registry Permission Error)

### Symptom

Event ID **6481** fires every 60 seconds in the Application log:

```
Application Server job failed for service instance
Microsoft.Office.Server.Search.Administration.SearchServiceInstance

Reason: System.Security.SecurityException:
  Requested registry access is not allowed.
  at Microsoft.Win32.RegistryKey.OpenSubKey(String name, Boolean writable)
  at Microsoft.SharePoint.Administration.SPCredentialManager.GetMasterKey(SPFarm farm)
```

### Root Cause

The registry key that stores the farm encryption master key:

```
HKLM\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\16.0\Secure\FarmAdmin
```

is missing ACLs for the SharePoint service accounts. Specifically, the
following principals need access:

| Principal               | Required Rights |
|-------------------------|-----------------|
| `CONTOSO\WSS_ADMIN_WPG` | FullControl     |
| `CONTOSO\sp_farm`        | FullControl     |
| `CONTOSO\WSS_WPG`        | ReadKey         |
| `CONTOSO\sp_search`      | ReadKey         |

The parent key (`...\Secure`) has correct ACLs, but the `FarmAdmin` sub-key
does not inherit them.

### Fix

```powershell
$path = "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\16.0\Secure\FarmAdmin"
$acl = Get-Acl $path

@(
    @("CONTOSO\WSS_ADMIN_WPG", "FullControl"),
    @("CONTOSO\sp_farm",       "FullControl"),
    @("CONTOSO\WSS_WPG",       "ReadKey"),
    @("CONTOSO\sp_search",     "ReadKey")
) | ForEach-Object {
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        $_[0], $_[1], "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($rule)
}

Set-Acl $path $acl
Restart-Service SPTimerV4 -Force
Restart-Service OSearch16 -Force
```

After fix, Event 6481 should stop within 1-2 minutes.

---

## Issue 4 — Orphaned Central Admin Application Pools

### Symptom

Multiple `SharePoint Central Administration v4 (...)` application pools with
timestamps in their names. Example:

```
SharePoint Central Administration v4 (4.8.2026 1.34.08 AM)
SharePoint Central Administration v4 (4.8.2026 1.48.43 AM)
SharePoint Central Administration v4 (4.8.2026 2.02.42 AM)  ← active
```

### Root Cause

Each interrupted or repeated PSConfig / `psconfig.exe -cmd upgrade` creates a
new timestamped CA pool without cleaning up the previous one.

### Fix

Identify the active pool (the one assigned to the CA IIS site), then remove
all others:

```powershell
$activeName = (Get-Website | Where-Object { $_.Name -like "SharePoint Central*" }).applicationPool
Get-ChildItem IIS:\AppPools | Where-Object {
    $_.Name -like "SharePoint Central Administration*" -and $_.Name -ne $activeName
} | ForEach-Object { Remove-WebAppPool $_.Name }
```

---

## Issue 5 — Exchange Service Crashes on Boot

### Observation

Several Exchange services crash and auto-restart during server boot:

- MSExchangeIS (Information Store)
- MSExchangeFrontEndTransport
- MSExchangeSubmission
- Microsoft Exchange Search

### Impact

Typically self-healing — services recover via the built-in restart policies.
However, the crashes contribute to high memory pressure during the boot
sequence, which may delay SharePoint's ability to start.

### Recommendation

No fix required, but monitor after boot. If persistent, increase the VM memory
beyond 32 GB or stagger service startup with delayed-start settings.

---

## General Notes on This Topology

### Memory

Both SharePoint and Exchange are memory-hungry. With 32 GB RAM, the server
runs at ~60% utilization at idle. Consider **48 GB minimum** if adding Search
crawls or heavy mailbox usage.

### Port 80 Conflict

Both Exchange (OWA via Default Web Site) and SharePoint Portal bind to port
80. They coexist via IIS host header routing:

| Site             | Binding         | Notes                    |
|------------------|-----------------|--------------------------|
| Default Web Site | `*:80:`         | Catches all (Exchange)   |
| SharePoint Portal| `:80:portal.contoso.com` | Host-header specific |

This works but is fragile. If the host header is missing from a request, it
hits Exchange instead of SharePoint.

### After Exchange CU Patching

Always re-run Phase 20 after applying Exchange cumulative updates. The
Exchange setup process resets CLR config on all application pools.

```powershell
C:\Installs\Start-Setup.ps1   # or run Phase 20 directly
```

### Loopback Authentication

The `BackConnectionHostNames` registry value must include `portal.contoso.com`
for NTLM authentication to work when accessing the portal from the server
itself. This is already configured but worth verifying after OS updates:

```powershell
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0" -Name BackConnectionHostNames
```
