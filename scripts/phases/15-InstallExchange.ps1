#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 15 – Install Exchange Server SE Mailbox role.
.DESCRIPTION
    Mounts the Exchange Server SE ISO, prepares the AD schema and domain,
    then installs the Mailbox role in unattended mode.

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase15-InstallExchange {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 15: Install Exchange Server SE – START ====="

    $exchangeInstallPath = "C:\Program Files\Microsoft\Exchange Server\V15"

    # ------------------------------------------------------------------
    # Idempotency: skip if Exchange is already installed
    # ------------------------------------------------------------------
    if (Test-Path (Join-Path $exchangeInstallPath "bin\ExSetup.exe")) {
        Write-Log "Exchange Server already installed at $exchangeInstallPath — skipping"
        Write-Log "===== Phase 15: Install Exchange Server SE – ALREADY DONE ====="
        return "success"
    }

    # ------------------------------------------------------------------
    # 1. Mount the Exchange ISO
    # ------------------------------------------------------------------
    $isoPath = "F:\Installers\$($script:Params.ExchangeIsoFileName)"
    if (-not (Test-Path $isoPath)) {
        throw "Exchange ISO not found at $isoPath. Ensure Phase 02 downloaded it."
    }

    Write-Log "Mounting Exchange ISO: $isoPath"
    $mountResult = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $driveLetter = ($mountResult | Get-Volume).DriveLetter
    if (-not $driveLetter) {
        throw "Failed to get drive letter after mounting Exchange ISO"
    }
    $setupExe = "${driveLetter}:\Setup.exe"
    Write-Log "Exchange ISO mounted at ${driveLetter}:\"

    try {
        # ------------------------------------------------------------------
        # 2. Prepare AD Schema
        # ------------------------------------------------------------------
        Write-Log "Preparing Active Directory schema for Exchange..."
        $proc = Start-Process -FilePath $setupExe `
            -ArgumentList "/PrepareSchema /IAcceptExchangeServerLicenseTerms_DiagnosticDataON" `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "Exchange /PrepareSchema failed with exit code $($proc.ExitCode)"
        }
        Write-Log "AD schema preparation completed"

        # ------------------------------------------------------------------
        # 3. Prepare AD (create Exchange org)
        # ------------------------------------------------------------------
        Write-Log "Preparing Active Directory for Exchange (OrganizationName: Contoso)..."
        $proc = Start-Process -FilePath $setupExe `
            -ArgumentList '/PrepareAD /OrganizationName:"Contoso" /IAcceptExchangeServerLicenseTerms_DiagnosticDataON' `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "Exchange /PrepareAD failed with exit code $($proc.ExitCode)"
        }
        Write-Log "AD preparation completed"

        # ------------------------------------------------------------------
        # 4. Install Mailbox role
        # ------------------------------------------------------------------
        Write-Log "Installing Exchange Mailbox role (this may take 30-60 minutes)..."
        $proc = Start-Process -FilePath $setupExe `
            -ArgumentList "/Mode:Install /Roles:Mailbox /IAcceptExchangeServerLicenseTerms_DiagnosticDataON" `
            -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "Exchange Mailbox role install failed with exit code $($proc.ExitCode)"
        }
        Write-Log "Exchange Mailbox role installed (exit code: $($proc.ExitCode))"
    }
    finally {
        # Always dismount the ISO
        Write-Log "Dismounting Exchange ISO..."
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    }

    Write-Log "===== Phase 15: Install Exchange Server SE – REBOOT REQUIRED ====="
    return "reboot"
}
