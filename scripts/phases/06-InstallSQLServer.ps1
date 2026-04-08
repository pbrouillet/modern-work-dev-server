#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 06 – Install SQL Server 2022 Enterprise from ISO.
.DESCRIPTION
    Mounts the SQL Server ISO from D:\Installers and runs an unattended
    installation with settings tuned for SharePoint (Latin1_General_CI_AS_KS_WS
    collation, MAXDOP 1, mixed-mode authentication).  Returns "reboot" on
    success so the orchestrator can restart the machine before the next phase.
    Requires Common.ps1 to be dot-sourced first for Write-Log and Invoke-WithRetry.
#>

function Invoke-Phase06-InstallSQLServer {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 06 – Install SQL Server 2022 ====="

    # ------------------------------------------------------------------
    # Idempotency: skip if SQL Server is already installed
    # ------------------------------------------------------------------
    $sqlRegPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    if ((Test-Path $sqlRegPath) -and (Get-ItemProperty -Path $sqlRegPath -ErrorAction SilentlyContinue).MSSQLSERVER) {
        Write-Log "SQL Server instance 'MSSQLSERVER' already installed – skipping"
        return "success"
    }

    $isoPath = "F:\Installers\$($script:Params.SqlIsoFileName)"
    $domainNB = $script:Params.DomainNetBIOS
    $password = $script:Params.DomainAdminPassword

    # ------------------------------------------------------------------
    # 1. Mount the SQL Server ISO
    # ------------------------------------------------------------------
    Write-Log "Mounting SQL Server ISO: $isoPath"

    if (-not (Test-Path $isoPath)) {
        throw "SQL Server ISO not found at $isoPath"
    }

    $driveLetter = $null
    try {
        # If the ISO is already mounted, reuse the existing mount
        $existingImage = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        if ($existingImage -and $existingImage.Attached) {
            Write-Log "ISO is already mounted – reusing existing mount" -Level DEBUG
            $driveLetter = ($existingImage | Get-Volume).DriveLetter
        }
        else {
            $iso = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
            $driveLetter = ($iso | Get-Volume).DriveLetter
        }

        if (-not $driveLetter) {
            throw "Failed to determine drive letter after mounting ISO"
        }
        Write-Log "ISO mounted on drive ${driveLetter}:"
    }
    catch {
        Write-Log "Failed to mount SQL Server ISO: $_" -Level ERROR
        throw
    }

    try {
        $setupExe = "${driveLetter}:\setup.exe"
        if (-not (Test-Path $setupExe)) {
            throw "setup.exe not found at $setupExe"
        }

        # ------------------------------------------------------------------
        # 2. Build setup.exe argument list
        # ------------------------------------------------------------------
        # SQLCOLLATION: Latin1_General_CI_AS_KS_WS is required by SharePoint.
        # SQLMAXDOP: Must be 1 for SharePoint.
        # SQLTEMPDBFILECOUNT: 8 files is a best-practice starting point.
        # UPDATEENABLED=False: Prevents setup from downloading patches mid-install.
        $setupArgs = @(
            "/ACTION=Install"
            "/FEATURES=SQLENGINE,FULLTEXT,CONN,IS"
            "/INSTANCENAME=MSSQLSERVER"
            "/SQLSVCACCOUNT=`"${domainNB}\sql_svc`""
            "/SQLSVCPASSWORD=`"${password}`""
            "/AGTSVCACCOUNT=`"${domainNB}\sql_agent`""
            "/AGTSVCPASSWORD=`"${password}`""
            "/AGTSVCSTARTUPTYPE=Automatic"
            "/SQLCOLLATION=`"Latin1_General_CI_AS_KS_WS`""
            "/SQLSYSADMINACCOUNTS=`"${domainNB}\sp_setup`" `"BUILTIN\Administrators`""
            "/SQLUSERDBDIR=`"F:\SQLData`""
            "/SQLUSERDBLOGDIR=`"F:\SQLLogs`""
            "/SQLTEMPDBDIR=`"F:\SQLTempDB`""
            "/SQLTEMPDBLOGDIR=`"F:\SQLTempDB`""
            "/SQLTEMPDBFILECOUNT=8"
            "/SQLTEMPDBFILESIZE=64"
            "/SQLTEMPDBFILEGROWTH=64"
            "/INSTALLSQLDATADIR=`"F:\SQLData`""
            "/SQLBACKUPDIR=`"F:\SQLData\Backup`""
            "/SECURITYMODE=SQL"
            "/SAPWD=`"${password}`""
            "/SQLMAXDOP=1"
            "/IACCEPTSQLSERVERLICENSETERMS"
            "/QUIET"
            "/INDICATEPROGRESS"
            "/UPDATEENABLED=False"
            "/TCPENABLED=1"
            "/NPENABLED=1"
        )

        $argString = $setupArgs -join " "
        Write-Log "Launching SQL Server setup (unattended)..."
        Write-Log "Setup path: $setupExe" -Level DEBUG

        # ------------------------------------------------------------------
        # 3. Run setup.exe
        # ------------------------------------------------------------------
        $process = Start-Process -FilePath $setupExe `
                                 -ArgumentList $argString `
                                 -Wait -PassThru -NoNewWindow `
                                 -ErrorAction Stop

        $exitCode = $process.ExitCode
        Write-Log "SQL Server setup exited with code $exitCode"

        # ------------------------------------------------------------------
        # 4. Evaluate exit code
        # ------------------------------------------------------------------
        $summaryLog = "C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt"
        if (Test-Path $summaryLog) {
            Write-Log "Setup summary log: $summaryLog"
        }
        else {
            Write-Log "Setup summary log not found at expected location" -Level WARN
        }

        switch ($exitCode) {
            0    { Write-Log "SQL Server installation completed successfully" }
            3010 { Write-Log "SQL Server installation succeeded – reboot required" }
            default {
                # Dump last 30 lines of summary log for diagnostics
                if (Test-Path $summaryLog) {
                    $tail = Get-Content -Path $summaryLog -Tail 30 -ErrorAction SilentlyContinue
                    foreach ($line in $tail) {
                        Write-Log "  SUMMARY: $line" -Level ERROR
                    }
                }
                throw "SQL Server setup failed with exit code $exitCode – see $summaryLog"
            }
        }
    }
    finally {
        # ------------------------------------------------------------------
        # 5. Dismount the ISO regardless of outcome
        # ------------------------------------------------------------------
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
            Write-Log "SQL Server ISO dismounted"
        }
        catch {
            Write-Log "Failed to dismount SQL Server ISO (non-fatal): $_" -Level WARN
        }
    }

    # ------------------------------------------------------------------
    # 6. Return "reboot" – always reboot after SQL Server installation
    # ------------------------------------------------------------------
    Write-Log "Phase 06 complete – reboot required"
    return "reboot"
}
