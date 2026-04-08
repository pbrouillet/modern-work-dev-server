#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 20 – Fix SharePoint / Exchange Server coexistence issues.
.DESCRIPTION
    When Exchange Server SE is installed on the same machine as SharePoint
    Server Subscription Edition, Exchange modifies the CLR host configuration
    on ALL IIS application pools (including SharePoint's) and can break
    registry permissions required by SharePoint services.

    This phase applies the following corrective actions:

      1.  Clears the Exchange CLR host config (GenericAppPoolConfigWith
          GCServerEnabledFalse.config) from every SharePoint-owned IIS
          application pool.  That config contains assembly binding redirects
          (notably System.Collections.Immutable 0.0.0.0-5.0.0.0 -> 5.0.0.0)
          that prevent SharePoint from resolving assemblies in the GAC.

      2.  Ensures the "SharePoint Web Services Root" application pool has
          autoStart = True and is running.  Exchange installation can leave
          this pool stopped, which disables all service-application endpoints
          on ports 32843/32844/32845.

      3.  Repairs registry ACLs on the FarmAdmin encryption key so the
          SharePoint Timer Service and Search Service can access the farm
          master key without SecurityException (Event ID 6481).

      4.  Removes orphaned Central Administration application pools left
          behind by repeated PSConfig runs.

    This phase is idempotent – safe to re-run after Exchange CU patching,
    which may re-apply the CLR config to all pools.

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase20-FixSPExchangeCoexistence {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 20: Fix SP/Exchange Coexistence – START ====="

    Import-Module WebAdministration -ErrorAction Stop

    $exchangeClrConfig = "C:\Program Files\Microsoft\Exchange Server\V15\bin\GenericAppPoolConfigWithGCServerEnabledFalse.config"

    # ------------------------------------------------------------------
    # 1. Identify SharePoint-owned application pools
    # ------------------------------------------------------------------
    $spPoolPatterns = @(
        "SP_*",
        "SharePoint*",
        "SecurityTokenServiceApplicationPool",
        "AppMgmtServiceAppPool",
        "MMSServiceAppPool",
        "UPAServiceAppPool"
    )

    $allPools = Get-ChildItem "IIS:\AppPools"
    $spPools = $allPools | Where-Object {
        $name = $_.Name
        $spPoolPatterns | Where-Object { $name -like $_ }
    }

    Write-Log "Found $($spPools.Count) SharePoint-related application pools"

    # ------------------------------------------------------------------
    # 2. Clear Exchange CLR host config from SharePoint pools
    # ------------------------------------------------------------------
    $fixedCount = 0
    foreach ($pool in $spPools) {
        $poolPath = "IIS:\AppPools\$($pool.Name)"
        $currentClr = (Get-ItemProperty $poolPath).CLRConfigFile

        if ($currentClr -and $currentClr -match "Exchange") {
            Set-ItemProperty $poolPath -Name "CLRConfigFile" -Value ""
            Write-Log "Cleared Exchange CLR config from: $($pool.Name)"
            $fixedCount++
        }
    }

    if ($fixedCount -eq 0) {
        Write-Log "No SharePoint pools had Exchange CLR config (already clean)"
    } else {
        Write-Log "Cleared Exchange CLR config from $fixedCount application pool(s)"
    }

    # ------------------------------------------------------------------
    # 3. Ensure SharePoint Web Services Root pool is started
    # ------------------------------------------------------------------
    $wsRootPath = "IIS:\AppPools\SharePoint Web Services Root"
    if (Test-Path $wsRootPath) {
        $wsRoot = Get-Item $wsRootPath

        if (-not $wsRoot.autoStart) {
            Set-ItemProperty $wsRootPath -Name "autoStart" -Value $true
            Write-Log "Set autoStart=True on SharePoint Web Services Root"
        }

        if ($wsRoot.State -ne "Started") {
            Start-WebAppPool "SharePoint Web Services Root"
            Write-Log "Started SharePoint Web Services Root application pool"
        } else {
            Write-Log "SharePoint Web Services Root already running"
        }
    } else {
        Write-Log "SharePoint Web Services Root pool not found — skipping" -Level WARN
    }

    # ------------------------------------------------------------------
    # 4. Repair FarmAdmin registry permissions
    # ------------------------------------------------------------------
    $farmAdminPath = "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\16.0\Secure\FarmAdmin"

    if (Test-Path $farmAdminPath) {
        Write-Log "Repairing FarmAdmin registry ACLs..."
        $acl = Get-Acl $farmAdminPath

        $principalsToAdd = @(
            @{ Identity = "CONTOSO\WSS_ADMIN_WPG"; Rights = "FullControl" },
            @{ Identity = "CONTOSO\WSS_WPG";       Rights = "ReadKey"     },
            @{ Identity = "CONTOSO\sp_farm";        Rights = "FullControl" },
            @{ Identity = "CONTOSO\sp_search";      Rights = "ReadKey"     }
        )

        foreach ($entry in $principalsToAdd) {
            try {
                $existingRule = $acl.Access | Where-Object {
                    $_.IdentityReference.Value -eq $entry.Identity
                }
                if (-not $existingRule) {
                    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                        $entry.Identity,
                        $entry.Rights,
                        "ContainerInherit,ObjectInherit",
                        "None",
                        "Allow"
                    )
                    $acl.AddAccessRule($rule)
                    Write-Log "  Added: $($entry.Identity) - $($entry.Rights)"
                } else {
                    Write-Log "  Already present: $($entry.Identity)"
                }
            }
            catch {
                Write-Log "  Could not add $($entry.Identity): $($_.Exception.Message)" -Level WARN
            }
        }

        Set-Acl $farmAdminPath $acl
        Write-Log "FarmAdmin registry ACLs applied"
    } else {
        Write-Log "FarmAdmin registry key not found at $farmAdminPath — skipping" -Level WARN
    }

    # ------------------------------------------------------------------
    # 5. Remove orphaned Central Administration application pools
    # ------------------------------------------------------------------
    # The active CA pool is whichever one the CA IIS site references.
    $caSite = Get-Website | Where-Object { $_.Name -like "SharePoint Central Administration*" }
    $activePoolName = if ($caSite) { $caSite.applicationPool } else { $null }

    if ($activePoolName) {
        Write-Log "Active Central Admin pool: $activePoolName"

        $caPools = Get-ChildItem "IIS:\AppPools" | Where-Object {
            $_.Name -like "SharePoint Central Administration*" -and
            $_.Name -ne $activePoolName
        }

        foreach ($orphan in $caPools) {
            try {
                if ($orphan.State -eq "Started") {
                    Stop-WebAppPool $orphan.Name
                }
                Remove-WebAppPool $orphan.Name
                Write-Log "Removed orphaned CA pool: $($orphan.Name)"
            }
            catch {
                Write-Log "Could not remove pool $($orphan.Name): $($_.Exception.Message)" -Level WARN
            }
        }

        if ($caPools.Count -eq 0) {
            Write-Log "No orphaned CA pools found"
        }
    }

    # ------------------------------------------------------------------
    # 6. Recycle affected SharePoint pools to apply changes
    # ------------------------------------------------------------------
    if ($fixedCount -gt 0) {
        Write-Log "Recycling SharePoint application pools..."
        foreach ($pool in $spPools) {
            $poolPath = "IIS:\AppPools\$($pool.Name)"
            if ((Get-Item $poolPath).State -eq "Started") {
                try {
                    Restart-WebAppPool $pool.Name
                    Write-Log "  Recycled: $($pool.Name)"
                }
                catch {
                    Write-Log "  Could not recycle $($pool.Name): $($_.Exception.Message)" -Level WARN
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # 7. Restart Timer and Search services if registry was repaired
    # ------------------------------------------------------------------
    Write-Log "Restarting SharePoint Timer and Search services..."
    Restart-Service SPTimerV4 -Force -ErrorAction SilentlyContinue
    Restart-Service OSearch16 -Force -ErrorAction SilentlyContinue
    Write-Log "Services restarted"

    # ------------------------------------------------------------------
    # 8. Validation
    # ------------------------------------------------------------------
    Write-Log "Validating fixes..."
    Start-Sleep -Seconds 10

    # Check portal
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://portal.$($script:Params.DomainName)")
        $req.UseDefaultCredentials = $true
        $req.Timeout = 60000
        $resp = $req.GetResponse()
        Write-Log "  Portal: HTTP $([int]$resp.StatusCode) — OK"
        $resp.Close()
    }
    catch [System.Net.WebException] {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 401) {
            Write-Log "  Portal: HTTP 401 (running, auth challenge) — OK"
        } else {
            Write-Log "  Portal: HTTP $code — may need investigation" -Level WARN
        }
    }
    catch {
        Write-Log "  Portal: $($_.Exception.Message)" -Level WARN
    }

    Write-Log "===== Phase 20: Fix SP/Exchange Coexistence – COMPLETE ====="
    return "success"
}
