#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 08 – Install SharePoint Subscription Edition prerequisites.
.DESCRIPTION
    Mounts the SharePoint ISO and runs prerequisiteinstaller.exe in unattended
    mode.  The ISO is intentionally left mounted so Phase 09 can use it for
    binary installation.  Returns "reboot" because prerequisite installation
    almost always requires a restart.
    Requires Common.ps1 to be dot-sourced first for Write-Log and Invoke-WithRetry.
#>

function Invoke-Phase08-InstallSPPrereqs {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 08 – Install SharePoint Prerequisites ====="

    $isoPath = "F:\Installers\$($script:Params.SpIsoFileName)"

    # ------------------------------------------------------------------
    # 1. Mount the SharePoint ISO
    # ------------------------------------------------------------------
    Write-Log "Mounting SharePoint ISO: $isoPath"

    if (-not (Test-Path $isoPath)) {
        throw "SharePoint ISO not found at $isoPath"
    }

    $driveLetter = $null
    try {
        $existingImage = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        if ($existingImage -and $existingImage.Attached) {
            Write-Log "SharePoint ISO is already mounted – reusing existing mount" -Level DEBUG
            $driveLetter = ($existingImage | Get-Volume).DriveLetter
        }
        else {
            $iso = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
            $driveLetter = ($iso | Get-Volume).DriveLetter
        }

        if (-not $driveLetter) {
            throw "Failed to determine drive letter after mounting SharePoint ISO"
        }
        Write-Log "SharePoint ISO mounted on drive ${driveLetter}:"
    }
    catch {
        Write-Log "Failed to mount SharePoint ISO: $_" -Level ERROR
        throw
    }

    # ------------------------------------------------------------------
    # 2. Run prerequisiteinstaller.exe
    # ------------------------------------------------------------------
    $prereqExe = "${driveLetter}:\prerequisiteinstaller.exe"

    if (-not (Test-Path $prereqExe)) {
        throw "prerequisiteinstaller.exe not found at $prereqExe"
    }

    Write-Log "Launching SharePoint prerequisite installer (unattended)..."

    try {
        $process = Start-Process -FilePath $prereqExe `
                                 -ArgumentList "/unattended" `
                                 -Wait -PassThru -NoNewWindow `
                                 -ErrorAction Stop

        $exitCode = $process.ExitCode
        Write-Log "Prerequisite installer exited with code $exitCode"

        # ------------------------------------------------------------------
        # 3. Evaluate exit code
        # ------------------------------------------------------------------
        # Known exit codes from prerequisiteinstaller.exe:
        #   0    = Success
        #   3010 = Success, reboot required
        #   1    = Another instance is running
        #   2    = Invalid command-line parameter
        #   1001 = A pending restart is blocking installation
        #   1002 = A prerequisite component failed to install
        #   1003 = Download failure (offline scenario)

        # Locate prereq log for diagnostics
        $prereqLogs = Get-ChildItem -Path $env:TEMP -Filter "prerequisiteinstaller.*.log" `
                        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($prereqLogs) {
            $latestLog = $prereqLogs[0].FullName
            Write-Log "Latest prerequisite log: $latestLog"
        }

        switch ($exitCode) {
            0 {
                Write-Log "SharePoint prerequisites installed successfully"
            }
            3010 {
                Write-Log "SharePoint prerequisites installed – reboot required"
            }
            1001 {
                Write-Log "A pending restart is blocking prerequisite installation" -Level WARN
                Write-Log "Returning reboot to clear the pending restart"
            }
            default {
                # Dump tail of the latest log for troubleshooting
                if ($latestLog -and (Test-Path $latestLog)) {
                    $tail = Get-Content -Path $latestLog -Tail 40 -ErrorAction SilentlyContinue
                    foreach ($line in $tail) {
                        Write-Log "  PREREQ-LOG: $line" -Level ERROR
                    }
                }

                # On Windows Server 2025, some older prerequisites may fail because
                # they are already part of the OS or have been superseded.  Log the
                # specific exit code so the operator can decide whether to proceed.
                if ($exitCode -eq 1002) {
                    Write-Log ("A prerequisite component failed to install (exit 1002). " +
                               "On Server 2025 this may indicate a component is already " +
                               "built in. Check the log above for details.") -Level ERROR
                }

                throw "Prerequisite installer failed with exit code $exitCode – see $latestLog"
            }
        }
    }
    catch [System.Management.Automation.RuntimeException] {
        # Re-throw our own explicit throws
        throw
    }
    catch {
        Write-Log "Failed to run prerequisite installer: $_" -Level ERROR
        throw
    }

    # ------------------------------------------------------------------
    # NOTE: Do NOT dismount the ISO – Phase 09 needs it to install
    # SharePoint binaries from the same mounted image.
    # ------------------------------------------------------------------
    Write-Log "SharePoint ISO left mounted for Phase 09"

    # ------------------------------------------------------------------
    # 4. Return reboot – prerequisites almost always require a restart
    # ------------------------------------------------------------------
    Write-Log "Phase 08 complete – reboot required"
    return "reboot"
}
