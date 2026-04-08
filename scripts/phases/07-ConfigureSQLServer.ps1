#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 07 – Post-installation SQL Server configuration.
.DESCRIPTION
    Waits for the SQL Server service to be running, then applies configuration
    required by SharePoint: max memory cap, MAXDOP 1, and the necessary logins
    and server-role memberships for the sp_setup and sp_farm domain accounts.
    Uses sqlcmd.exe (installed with SQL Server) for T-SQL execution.
    Requires Common.ps1 to be dot-sourced first for Write-Log and Invoke-WithRetry.
#>

function Invoke-Phase07-ConfigureSQLServer {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 07 – Configure SQL Server ====="

    $domainNB = $script:Params.DomainNetBIOS

    # ------------------------------------------------------------------
    # 1. Wait for SQL Server service to be running
    # ------------------------------------------------------------------
    Write-Log "Waiting for MSSQLSERVER service to reach 'Running' state..."

    Invoke-WithRetry -ScriptBlock {
        $svc = Get-Service -Name MSSQLSERVER -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            throw "MSSQLSERVER service is in state '$($svc.Status)', waiting for 'Running'"
        }
        return $svc
    } -MaxRetries 10 -DelaySeconds 15 -OperationName "SQL Server startup"

    # Also ensure SQL Server Agent is running (needed later for maintenance)
    try {
        $agentSvc = Get-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue
        if ($agentSvc -and $agentSvc.Status -ne 'Running') {
            Write-Log "Starting SQL Server Agent service..."
            Start-Service -Name SQLSERVERAGENT -ErrorAction Stop
            Write-Log "SQL Server Agent service started"
        }
    }
    catch {
        Write-Log "Failed to start SQL Server Agent (non-fatal): $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # Helper: locate sqlcmd.exe
    # ------------------------------------------------------------------
    $sqlcmdPath = $null
    $searchPaths = @(
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\*\Tools\Binn\SQLCMD.EXE"
        "C:\Program Files\Microsoft SQL Server\160\Tools\Binn\SQLCMD.EXE"
        "C:\Program Files\Microsoft SQL Server\150\Tools\Binn\SQLCMD.EXE"
    )
    foreach ($pattern in $searchPaths) {
        $found = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $sqlcmdPath = $found.FullName
            break
        }
    }

    if (-not $sqlcmdPath) {
        # Fallback: try it on the PATH
        $sqlcmdPath = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
    }

    if (-not $sqlcmdPath) {
        throw "sqlcmd.exe not found – cannot configure SQL Server"
    }
    Write-Log "Using sqlcmd: $sqlcmdPath" -Level DEBUG

    # ------------------------------------------------------------------
    # Helper: run a T-SQL batch via sqlcmd
    # ------------------------------------------------------------------
    function Invoke-SqlCmd-Batch {
        param(
            [Parameter(Mandatory)]
            [string]$Sql,
            [string]$Description = "T-SQL batch"
        )

        Write-Log "Executing: $Description" -Level DEBUG

        # -b: on error, set ERRORLEVEL  -S: server (local default instance)
        # -E: Windows auth (runs as the current SYSTEM/admin identity)
        $result = & $sqlcmdPath -S "." -E -b -Q $Sql 2>&1

        if ($LASTEXITCODE -ne 0) {
            $output = ($result | Out-String).Trim()
            Write-Log "sqlcmd failed for '$Description': $output" -Level ERROR
            throw "sqlcmd execution failed for '$Description' (exit code $LASTEXITCODE)"
        }

        $output = ($result | Out-String).Trim()
        if ($output) {
            Write-Log "  sqlcmd output: $output" -Level DEBUG
        }

        return $output
    }

    # ------------------------------------------------------------------
    # 2. Configure server settings via T-SQL
    # ------------------------------------------------------------------

    # 2a. Set max server memory to 8 GB
    Write-Log "Setting max server memory to 8192 MB..."
    Invoke-SqlCmd-Batch -Description "Enable advanced options" -Sql @"
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
"@

    Invoke-SqlCmd-Batch -Description "Set max server memory" -Sql @"
EXEC sp_configure 'max server memory', 8192;
RECONFIGURE;
"@

    # 2b. Verify / enforce MAXDOP = 1 (SharePoint requirement)
    Write-Log "Setting max degree of parallelism to 1..."
    Invoke-SqlCmd-Batch -Description "Set MAXDOP" -Sql @"
EXEC sp_configure 'max degree of parallelism', 1;
RECONFIGURE;
"@

    # ------------------------------------------------------------------
    # 3. Create logins and assign server roles
    # ------------------------------------------------------------------

    # 3a. sp_setup needs dbcreator and securityadmin for SharePoint config
    Write-Log "Ensuring ${domainNB}\sp_setup login with dbcreator and securityadmin..."
    Invoke-SqlCmd-Batch -Description "Create/grant sp_setup" -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'${domainNB}\sp_setup')
    CREATE LOGIN [${domainNB}\sp_setup] FROM WINDOWS;
ALTER SERVER ROLE [dbcreator]      ADD MEMBER [${domainNB}\sp_setup];
ALTER SERVER ROLE [securityadmin]  ADD MEMBER [${domainNB}\sp_setup];
"@

    # 3b. sp_farm needs a login for SharePoint farm operations
    Write-Log "Ensuring ${domainNB}\sp_farm login..."
    Invoke-SqlCmd-Batch -Description "Create sp_farm login" -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'${domainNB}\sp_farm')
    CREATE LOGIN [${domainNB}\sp_farm] FROM WINDOWS;
"@

    # 3c. Pre-create logins for all SharePoint service accounts
    #     SharePoint creates these during farm config, but pre-creating
    #     them avoids permission gaps if auto-provisioning is incomplete.
    $spServiceAccounts = @("sp_services", "sp_webapp", "sp_search", "sp_content", "sp_cache", "sp_apps")
    foreach ($acctName in $spServiceAccounts) {
        $fqName = "${domainNB}\$acctName"
        Write-Log "Ensuring login for $fqName..."
        Invoke-SqlCmd-Batch -Description "Create $acctName login" -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$fqName')
    CREATE LOGIN [$fqName] FROM WINDOWS;
"@
    }

    # ------------------------------------------------------------------
    # 4. Verify configuration
    # ------------------------------------------------------------------
    Write-Log "Verifying SQL Server configuration..."

    $verifyResult = Invoke-SqlCmd-Batch -Description "Verify sp_configure settings" -Sql @"
SELECT name, CAST(value_in_use AS INT) AS value_in_use
FROM sys.configurations
WHERE name IN ('max server memory (MB)', 'max degree of parallelism')
ORDER BY name;
"@
    Write-Log "Configuration verification output:`n$verifyResult"

    $loginResult = Invoke-SqlCmd-Batch -Description "Verify logins" -Sql @"
SELECT name, type_desc
FROM sys.server_principals
WHERE name IN (N'${domainNB}\sp_setup', N'${domainNB}\sp_farm')
ORDER BY name;
"@
    Write-Log "Login verification output:`n$loginResult"

    Write-Log "Phase 07 complete – SQL Server configured for SharePoint"
    return "success"
}
