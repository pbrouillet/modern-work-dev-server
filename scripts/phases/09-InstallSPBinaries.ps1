#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 09 – Install SharePoint Subscription Edition binaries.
.DESCRIPTION
    Ensures the SharePoint ISO is mounted, writes an unattended config.xml,
    and runs setup.exe to install the SharePoint Server binaries.  The ISO is
    dismounted after installation.  Returns "reboot" so the orchestrator can
    restart the machine before farm configuration.
    Requires Common.ps1 to be dot-sourced first for Write-Log and Invoke-WithRetry.
#>

function Invoke-Phase09-InstallSPBinaries {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 09 – Install SharePoint Binaries ====="

    $isoPath    = "F:\Installers\$($script:Params.SpIsoFileName)"
    $configDir  = "C:\SPSESetup"
    $configFile = Join-Path $configDir "sp-setup-config.xml"

    # ------------------------------------------------------------------
    # 1. Ensure the SharePoint ISO is mounted
    # ------------------------------------------------------------------
    Write-Log "Checking SharePoint ISO mount status..."

    if (-not (Test-Path $isoPath)) {
        throw "SharePoint ISO not found at $isoPath"
    }

    $driveLetter = $null
    try {
        $existingImage = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        if ($existingImage -and $existingImage.Attached) {
            Write-Log "SharePoint ISO is already mounted" -Level DEBUG
            $driveLetter = ($existingImage | Get-Volume).DriveLetter
        }
        else {
            Write-Log "SharePoint ISO not mounted – mounting now..."
            $iso = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
            $driveLetter = ($iso | Get-Volume).DriveLetter
        }

        if (-not $driveLetter) {
            throw "Failed to determine drive letter for SharePoint ISO"
        }
        Write-Log "SharePoint ISO available on drive ${driveLetter}:"
    }
    catch {
        Write-Log "Failed to mount SharePoint ISO: $_" -Level ERROR
        throw
    }

    try {
        $setupExe = "${driveLetter}:\setup.exe"
        if (-not (Test-Path $setupExe)) {
            throw "setup.exe not found at $setupExe"
        }

        # ------------------------------------------------------------------
        # 2. Create unattended config.xml
        # ------------------------------------------------------------------
        # SERVERPIDINKEY: Loaded from config/serials.json.
        # SETUP_REBOOT=Never: We manage reboots ourselves via the orchestrator.
        $serialsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "config\serials.json"
        if (Test-Path $serialsPath) {
            $serials = Get-Content $serialsPath -Raw | ConvertFrom-Json
            $spProductKey = $serials.sharepoint.productKey
            Write-Log "Loaded SharePoint product key from serials.json"
        } else {
            $spProductKey = "QXNWY-QHCPC-BF3DK-J94F9-2YXC2"
            Write-Log "WARNING: serials.json not found — using default SharePoint key"
        }

        $configXml = @"
<Configuration>
  <Package Id="sts">
    <Setting Id="LAUNCHEDFROMSETUPSTS" Value="Yes"/>
  </Package>
  <Package Id="spswfe">
    <Setting Id="SETUPCALLED" Value="1"/>
  </Package>
  <ARP ARPCOMMENTS="SharePoint Server" ARPCONTACT="admin" />
  <Logging Type="verbose" Path="%temp%" Template="SharePoint Server Setup(*).log"/>
  <Display Level="none" CompletionNotice="no" AcceptEula="yes"/>
  <INSTALLLOCATION Value="C:\Program Files\Microsoft Office Servers\16.0"/>
  <PIDKEY Value="$spProductKey"/>
  <Setting Id="USINGUIINSTALLMODE" Value="0"/>
  <Setting Id="SETUPTYPE" Value="CLEAN_INSTALL"/>
  <Setting Id="SETUP_REBOOT" Value="Never"/>
</Configuration>
"@

        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            Write-Log "Created config directory: $configDir"
        }

        Set-Content -Path $configFile -Value $configXml -Encoding UTF8 -Force -ErrorAction Stop
        Write-Log "Wrote setup config to $configFile"

        # ------------------------------------------------------------------
        # 3. Run setup.exe
        # ------------------------------------------------------------------
        Write-Log "Launching SharePoint setup (unattended)..."

        $process = Start-Process -FilePath $setupExe `
                                 -ArgumentList "/config `"$configFile`" /IAcceptTheLicenseTerms" `
                                 -Wait -PassThru -NoNewWindow `
                                 -ErrorAction Stop

        $exitCode = $process.ExitCode
        Write-Log "SharePoint setup exited with code $exitCode"

        # ------------------------------------------------------------------
        # 4. Evaluate exit code
        # ------------------------------------------------------------------
        # Locate setup log for diagnostics
        $setupLogs = Get-ChildItem -Path $env:TEMP -Filter "SharePoint Server Setup*.log" `
                        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($setupLogs) {
            $latestLog = $setupLogs[0].FullName
            Write-Log "Latest SharePoint setup log: $latestLog"
        }

        switch ($exitCode) {
            0 {
                Write-Log "SharePoint binaries installed successfully"
            }
            3010 {
                Write-Log "SharePoint binaries installed – reboot required"
            }
            30066 {
                # 30066 = prerequisites not met; should not happen after Phase 08
                Write-Log "Setup reports prerequisites not met (exit 30066)" -Level ERROR
                throw "SharePoint setup failed – prerequisites not met. Re-run Phase 08."
            }
            default {
                if ($latestLog -and (Test-Path $latestLog)) {
                    $tail = Get-Content -Path $latestLog -Tail 40 -ErrorAction SilentlyContinue
                    foreach ($line in $tail) {
                        Write-Log "  SP-SETUP-LOG: $line" -Level ERROR
                    }
                }
                throw "SharePoint setup failed with exit code $exitCode – see $latestLog"
            }
        }
    }
    finally {
        # ------------------------------------------------------------------
        # 5. Dismount the ISO
        # ------------------------------------------------------------------
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
            Write-Log "SharePoint ISO dismounted"
        }
        catch {
            Write-Log "Failed to dismount SharePoint ISO (non-fatal): $_" -Level WARN
        }
    }

    # ------------------------------------------------------------------
    # 6. Return reboot
    # ------------------------------------------------------------------
    Write-Log "Phase 09 complete – reboot required"
    return "reboot"
}
