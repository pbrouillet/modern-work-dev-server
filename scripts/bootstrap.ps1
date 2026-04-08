<#
.SYNOPSIS
    Main orchestrator for automated SharePoint SE dev-box provisioning.

.DESCRIPTION
    Implements a state-machine pattern that executes 19 phases sequentially,
    surviving reboots between phases.  The Azure Custom Script Extension (CSE)
    invokes this script on first run; subsequent runs are triggered by a
    scheduled task that re-enters the same state machine after each reboot.

    Each phase is idempotent.  Completed phases are recorded in state.json and
    skipped on subsequent invocations unless -Force is specified.  A phase that
    returns "reboot" causes the script to exit cleanly so the scheduled task
    can re-invoke it after the machine restarts.

.PARAMETER IsoBlobUrl
    URL of the blob container containing ISOs (e.g., https://stXXX.blob.core.windows.net/isos).

.PARAMETER SqlIsoFileName
    File name of the SQL Server ISO (default: enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso).

.PARAMETER SpIsoFileName
    File name of the SharePoint Server ISO (default: en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso).

.PARAMETER DomainAdminPassword
    Password used for DSRM and domain/service accounts.

.PARAMETER SpFarmPassphrase
    Passphrase for the SharePoint farm configuration.

.PARAMETER DomainName
    Fully-qualified domain name (default: contoso.com).

.PARAMETER DomainNetBIOS
    NetBIOS domain name (default: CONTOSO).

.PARAMETER Force
    Re-execute phases even if they are already marked as completed.

.PARAMETER EnableExchange
    When 'True', installs Exchange Server SE after the core SharePoint setup.

.PARAMETER ExchangeIsoFileName
    File name of the Exchange Server SE ISO in the isos container.
#>

param(
    [string]$SetupRoot       = "C:\SPSESetup",
    [string]$IsoBlobUrl,
    [string]$SqlIsoFileName  = "enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso",
    [string]$SpIsoFileName   = "en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso",
    [string]$DomainAdminPassword,
    [string]$SpFarmPassphrase,
    [string]$DomainName      = "contoso.com",
    [string]$DomainNetBIOS   = "CONTOSO",
    [string]$EnableExchange  = "False",
    [string]$ExchangeIsoFileName = "ExchangeServerSE-x64.iso",
    [switch]$Force,

    # Replay specific phases by number, bypassing completed/attempt checks.
    # Only the listed phases run; all others are skipped.
    # Example: -ReplayPhases 7,10,18
    [int[]]$ReplayPhases = @()
)

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
$ScriptsRoot     = Join-Path $SetupRoot "scripts"
$StateFile       = Join-Path $SetupRoot "state.json"
$ParamsFile      = Join-Path $SetupRoot "params.json"
$CompletedMarker = Join-Path $SetupRoot "COMPLETED"
$TaskName        = "SPSEBootstrap"
$MaxAttempts     = 3

# Phase definitions — order matters.
$PhaseDefinitions = @(
    @{ Number =  1; Script = "01-InitDisks.ps1";              Function = "Invoke-Phase01-InitDisks"              }
    @{ Number =  2; Script = "02-DownloadISOs.ps1";            Function = "Invoke-Phase02-DownloadISOs"            }
    @{ Number =  3; Script = "03-PromoteADDC.ps1";             Function = "Invoke-Phase03-PromoteADDC"             }
    @{ Number =  4; Script = "04-ConfigureDNS.ps1";            Function = "Invoke-Phase04-ConfigureDNS"            }
    @{ Number =  5; Script = "05-CreateServiceAccounts.ps1";   Function = "Invoke-Phase05-CreateServiceAccounts"   }
    @{ Number =  6; Script = "06-InstallSQLServer.ps1";        Function = "Invoke-Phase06-InstallSQLServer"        }
    @{ Number =  7; Script = "07-ConfigureSQLServer.ps1";      Function = "Invoke-Phase07-ConfigureSQLServer"      }
    @{ Number =  8; Script = "08-InstallSPPrereqs.ps1";        Function = "Invoke-Phase08-InstallSPPrereqs"        }
    @{ Number =  9; Script = "09-InstallSPBinaries.ps1";       Function = "Invoke-Phase09-InstallSPBinaries"       }
    @{ Number = 10; Script = "10-ConfigureSPFarm.ps1";         Function = "Invoke-Phase10-ConfigureSPFarm"         }
    @{ Number = 11; Script = "11-CreateSPWebApp.ps1";          Function = "Invoke-Phase11-CreateSPWebApp"          }
    @{ Number = 14; Script = "14-InstallExchangePrereqs.ps1";  Function = "Invoke-Phase14-InstallExchangePrereqs";  Condition = { $script:Params.EnableExchange -eq 'True' } }
    @{ Number = 15; Script = "15-InstallExchange.ps1";         Function = "Invoke-Phase15-InstallExchange";         Condition = { $script:Params.EnableExchange -eq 'True' } }
    @{ Number = 16; Script = "16-ConfigureExchange.ps1";       Function = "Invoke-Phase16-ConfigureExchange";       Condition = { $script:Params.EnableExchange -eq 'True' } }
    @{ Number = 17; Script = "17-InstallVS2026.ps1";           Function = "Invoke-Phase17-InstallVS2026"           }
    @{ Number = 18; Script = "18-FinalConfig.ps1";             Function = "Invoke-Phase18-FinalConfig"             }
    @{ Number = 19; Script = "19-InstallOptionalSoftware.ps1"; Function = "Invoke-Phase19-InstallOptionalSoftware" }
    @{ Number = 20; Script = "20-FixSPExchangeCoexistence.ps1";Function = "Invoke-Phase20-FixSPExchangeCoexistence"       Condition = { $script:Params.EnableExchange -eq 'True' } }
)

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers (state management, param persistence, task registration)
# ─────────────────────────────────────────────────────────────────────────────

function Get-State {
    <# Read the state file.  Returns a hashtable keyed by phase number. #>
    if (Test-Path $StateFile) {
        try {
            $raw = Get-Content -Path $StateFile -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            $ht = @{}
            foreach ($prop in $obj.psobject.Properties) {
                $ht[$prop.Name] = $prop.Value
            }
            if ($ht.Phases -is [PSCustomObject]) {
                $inner = @{}
                foreach ($phaseProp in $ht.Phases.psobject.Properties) {
                    $phaseHt = @{}
                    foreach ($p in $phaseProp.Value.psobject.Properties) {
                        $phaseHt[$p.Name] = $p.Value
                    }
                    $inner[$phaseProp.Name] = $phaseHt
                }
                $ht.Phases = $inner
            }
            return $ht
        } catch {
            Write-Log "WARNING: Corrupt state file — starting fresh." -Level Warning
        }
    }
    return @{ Phases = @{} }
}

function Save-State {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFile -Encoding UTF8 -Force
}

function Save-Parameters {
    <#
    .SYNOPSIS
        Persist parameters to a JSON file with SYSTEM-only ACL.
    .DESCRIPTION
        Passwords are stored as plaintext because this is a single-user dev
        box.  The file is ACL-locked to NT AUTHORITY\SYSTEM so only the
        scheduled task (which runs as SYSTEM) can read it.
    #>
    param([hashtable]$Params)

    $Params | ConvertTo-Json -Depth 5 | Set-Content -Path $ParamsFile -Encoding UTF8 -Force

    # Lock the file to SYSTEM-only
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)   # disable inheritance
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM",
        "FullControl",
        "Allow"
    )
    $acl.AddAccessRule($systemRule)

    # Also grant Administrators read/write so manual re-runs (as spadmin)
    # can read and refresh the file.  This is a single-user dev box.
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "BUILTIN\Administrators",
        "Read, Write",
        "Allow"
    )
    $acl.AddAccessRule($adminRule)

    Set-Acl -Path $ParamsFile -AclObject $acl

    Write-Log "Parameters saved to $ParamsFile (SYSTEM + Administrators ACL applied)."
}

function Load-Parameters {
    <# Load previously-saved parameters from disk. #>
    if (-not (Test-Path $ParamsFile)) {
        throw "Parameter file not found at $ParamsFile. Cannot continue after reboot without saved parameters."
    }
    $raw = Get-Content -Path $ParamsFile -Raw -ErrorAction Stop
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $ht = @{}; $obj.psobject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    return $ht
}

function Copy-ScriptsToSetupRoot {
    <#
    .SYNOPSIS
        Copy the scripts tree from the CSE download location to the
        persistent C:\SPSESetup\scripts\ folder.
    .DESCRIPTION
        The CSE downloads scripts to a temporary directory that may not
        survive a reboot.  This function mirrors the entire scripts folder
        (helpers, phases, config, bootstrap) into $ScriptsRoot so that the
        scheduled task always has a stable path.
        Note: Uses Write-Host (not Write-Log) because Common.ps1 may not
        be loaded yet on first run.
    #>
    param([string]$SourceScriptsDir)

    if (-not (Test-Path $SourceScriptsDir)) {
        throw "Source scripts directory not found: $SourceScriptsDir"
    }

    Write-Host "Copying scripts from '$SourceScriptsDir' to '$ScriptsRoot' ..."
    Copy-Item -Path "$SourceScriptsDir\*" -Destination $ScriptsRoot -Recurse -Force
    Write-Host "Scripts copied successfully."
}

# Register-BootstrapTask and Unregister-BootstrapTask are defined in
# helpers/Wait-ForReboot.ps1 (dot-sourced below).  They read $script:TaskName,
# $script:ScriptsRoot, and $script:Params set by this script.

function Write-CompletionSummary {
    param([hashtable]$State)

    $summary = @()
    $summary += "==============================================="
    $summary += " SPSE Dev-Box Provisioning — COMPLETE"
    $summary += " Finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $summary += "==============================================="

    foreach ($phase in ($PhaseDefinitions | Sort-Object { $_.Number })) {
        $key = "Phase$($phase.Number)"
        $info = $State.Phases[$key]
        if ($info) {
            $status   = $info.Status
            $attempts = $info.Attempts
            $summary += "  Phase {0,2}: {1,-35} [{2}] (attempts: {3})" -f `
                $phase.Number, $phase.Function, $status, $attempts
        }
    }

    $summary += "==============================================="
    $text = $summary -join "`n"
    Write-Log $text
    $text | Set-Content -Path (Join-Path $SetupRoot "completion-summary.txt") -Encoding UTF8 -Force
}

function Copy-CompanionScripts {
    <#
    .SYNOPSIS
        Copy helper, phase, and config scripts from a source directory
        to the local setup directory.
    .DESCRIPTION
        Copies scripts to C:\SPSESetup\scripts\ so the scheduled task always
        has a stable local path.
    #>
    param(
        [string]$SharePath,
        [string]$DestinationRoot
    )

    if (-not (Test-Path $SharePath)) {
        Write-Warning "Share path not found: $SharePath — scripts not copied"
        return
    }

    Write-Host "Copying scripts from share '$SharePath' to '$DestinationRoot' ..."
    if (-not (Test-Path $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    # Copy all subdirectories and files
    Get-ChildItem -Path $SharePath -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($SharePath.Length)
        $dest = Join-Path $DestinationRoot $rel
        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        } else {
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -Path $_.FullName -Destination $dest -Force
            Write-Host "  [copy] $rel"
        }
    }

    Write-Host "Scripts copied successfully."
}

# ─────────────────────────────────────────────────────────────────────────────
# Main execution
# ─────────────────────────────────────────────────────────────────────────────
try {
    $ErrorActionPreference = 'Stop'

    # ── Determine the active scripts directory ──────────────────────────
    # On the very first CSE invocation, $PSScriptRoot points to the CSE
    # temp directory.  After we copy scripts to C:\SPSESetup\scripts\, all
    # subsequent runs (scheduled task) use that persistent location.
    if (Test-Path (Join-Path $ScriptsRoot "bootstrap.ps1")) { $ActiveScriptsDir = $ScriptsRoot } else { $ActiveScriptsDir = $PSScriptRoot }

    # ── First-run: ensure companion scripts are available ───────────────
    # Scripts may already exist in $PSScriptRoot (e.g., pre-provisioned to
    # C:\Installs) or need downloading from blob storage.  Either way,
    # they must be copied to $ScriptsRoot (C:\SPSESetup\scripts\) so the
    # scheduled task can find them after a reboot.
    $helpersDir = Join-Path $ActiveScriptsDir "helpers"
    if (-not (Test-Path (Join-Path $helpersDir "Common.ps1"))) {
        if (-not (Test-Path $ScriptsRoot)) {
            New-Item -ItemType Directory -Path $ScriptsRoot -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $PSScriptRoot "bootstrap.ps1") -Destination (Join-Path $ScriptsRoot "bootstrap.ps1") -Force

        # Scripts are pre-provisioned to C:\Installs by the CSE — copy them
        # to the persistent setup root if they exist.
        if (Test-Path (Join-Path $PSScriptRoot "helpers")) {
            Write-Host "First run: copying scripts to persistent setup root..."
            Copy-ScriptsToSetupRoot -SourceScriptsDir $PSScriptRoot
            Write-Host "Scripts copied."
        }

        $ActiveScriptsDir = $ScriptsRoot
        $helpersDir = Join-Path $ActiveScriptsDir "helpers"
    } elseif ($ActiveScriptsDir -ne $ScriptsRoot) {
        # Helpers exist in the source dir (e.g., C:\Installs) but haven't
        # been copied to the persistent setup root yet.  Copy everything so
        # the scheduled task path (C:\SPSESetup\scripts\) is valid.
        if (-not (Test-Path $ScriptsRoot)) {
            New-Item -ItemType Directory -Path $ScriptsRoot -Force | Out-Null
        }
        Copy-ScriptsToSetupRoot -SourceScriptsDir $ActiveScriptsDir
        Copy-Item -Path (Join-Path $PSScriptRoot "bootstrap.ps1") -Destination (Join-Path $ScriptsRoot "bootstrap.ps1") -Force
        $ActiveScriptsDir = $ScriptsRoot
        $helpersDir = Join-Path $ActiveScriptsDir "helpers"
    }

    # ── Always re-sync scripts when invoked from a different directory ──
    # Start-Setup.ps1 syncs the latest scripts from blob storage into
    # $PSScriptRoot (C:\Installs) before calling bootstrap.ps1.  If we are
    # running from a source dir that differs from the persistent setup root,
    # re-copy so the persistent location stays current.
    if ($PSScriptRoot -ne $ScriptsRoot -and (Test-Path (Join-Path $PSScriptRoot "phases"))) {
        Write-Host "Re-syncing scripts from '$PSScriptRoot' to '$ScriptsRoot' ..."
        Copy-ScriptsToSetupRoot -SourceScriptsDir $PSScriptRoot
        Copy-Item -Path (Join-Path $PSScriptRoot "bootstrap.ps1") -Destination (Join-Path $ScriptsRoot "bootstrap.ps1") -Force
        $ActiveScriptsDir = $ScriptsRoot
        $helpersDir = Join-Path $ActiveScriptsDir "helpers"
    }

    # ── Dot-source helper modules ───────────────────────────────────────
    foreach ($helperFile in @("Common.ps1", "Download-FromBlob.ps1", "Wait-ForReboot.ps1")) {
        $helperPath = Join-Path $helpersDir $helperFile
        if (Test-Path $helperPath) {
            . $helperPath
            # Write-Log may not be available until Common.ps1 is loaded
        } else {
            Write-Warning "Helper not found (will be available after copy): $helperPath"
        }
    }

    # ── Initialize setup directory structure ────────────────────────────
    Initialize-SetupEnvironment

    Write-Log "======================================================="
    Write-Log " bootstrap.ps1 starting — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log " PID: $PID | User: $env:USERNAME | Host: $env:COMPUTERNAME"
    Write-Log " ActiveScriptsDir: $ActiveScriptsDir"
    Write-Log "======================================================="

    # ── First-run tasks ─────────────────────────────────────────────────
    # If parameters were supplied on the command line, prefer them over
    # the saved file (which may be SYSTEM-ACL-locked from a prior CSE run).
    $paramsSupplied = [bool]$IsoBlobUrl
    $isFirstRun = $paramsSupplied -or -not (Test-Path $ParamsFile)

    if ($isFirstRun) {
        if ($paramsSupplied) {
            Write-Log "Parameters supplied on command line — saving/refreshing params.json."
        } else {
            Write-Log "First run detected — performing one-time setup."
        }

        # Persist parameters so they are available after reboot.
        $paramHash = @{
            IsoBlobUrl            = $IsoBlobUrl
            SqlIsoFileName        = $SqlIsoFileName
            SpIsoFileName         = $SpIsoFileName
            DomainAdminPassword   = $DomainAdminPassword
            SpFarmPassphrase      = $SpFarmPassphrase
            DomainName            = $DomainName
            DomainNetBIOS         = $DomainNetBIOS
            EnableExchange        = $EnableExchange
            ExchangeIsoFileName   = $ExchangeIsoFileName
        }

        # Validate required parameters before persisting — prevents saving
        # garbage values that corrupt all subsequent runs.
        if (-not $IsoBlobUrl -or $IsoBlobUrl -notmatch '^https://') {
            throw "Required parameter 'IsoBlobUrl' is missing or invalid (got: '$IsoBlobUrl'). Provide a valid blob URL (e.g., https://stXXX.blob.core.windows.net/isos)."
        }
        if (-not $DomainAdminPassword) {
            throw "Required parameter 'DomainAdminPassword' is missing. Cannot continue without a domain admin password."
        }
        if (-not $SqlIsoFileName) {
            throw "Required parameter 'SqlIsoFileName' is missing."
        }
        if (-not $SpIsoFileName) {
            throw "Required parameter 'SpIsoFileName' is missing."
        }

        Save-Parameters -Params $paramHash
    } else {
        Write-Log "Resuming after reboot — loading saved parameters."
        $paramHash = Load-Parameters

        # Populate script-level variables from saved params so phase
        # scripts that reference them via $script: or direct variable
        # names continue to work.
        $IsoBlobUrl            = $paramHash.IsoBlobUrl
        $SqlIsoFileName        = $paramHash.SqlIsoFileName
        $SpIsoFileName         = $paramHash.SpIsoFileName
        $DomainAdminPassword   = $paramHash.DomainAdminPassword
        $SpFarmPassphrase      = $paramHash.SpFarmPassphrase
        $DomainName            = $paramHash.DomainName
        $DomainNetBIOS         = $paramHash.DomainNetBIOS
        $EnableExchange        = $(if ($paramHash.ContainsKey('EnableExchange')) { $paramHash.EnableExchange } else { 'False' })
        $ExchangeIsoFileName   = $(if ($paramHash.ContainsKey('ExchangeIsoFileName')) { $paramHash.ExchangeIsoFileName } else { 'ExchangeServerSE-x64.iso' })

        # Re-source helpers from the persistent location.
        $ActiveScriptsDir = $ScriptsRoot
        $helpersDir = Join-Path $ActiveScriptsDir "helpers"
        foreach ($helperFile in @("Common.ps1", "Download-FromBlob.ps1", "Wait-ForReboot.ps1")) {
            $helperPath = Join-Path $helpersDir $helperFile
            if (Test-Path $helperPath) { . $helperPath }
        }
    }

    # ── Expose params to phase scripts via $script:Params ───────────────
    $script:Params = $paramHash

    # ── Register the bootstrap scheduled task ───────────────────────────
    Register-BootstrapTask

    # ── Load state ──────────────────────────────────────────────────────
    $state = Get-State

    if (-not $state.Phases) {
        $state.Phases = @{}
    }

    # ── Phase execution loop ────────────────────────────────────────────
    $phasesDir = Join-Path $ActiveScriptsDir "phases"
    $allPhasesCompleted = $true

    foreach ($phaseDef in $PhaseDefinitions) {
        $phaseNum  = $phaseDef.Number
        $phaseKey  = "Phase$phaseNum"
        $phaseFile = $phaseDef.Script
        $phaseFunc = $phaseDef.Function

        # Initialise phase state on first encounter
        if (-not $state.Phases.ContainsKey($phaseKey)) {
            $state.Phases[$phaseKey] = @{
                Status      = "pending"
                Attempts    = 0
                StartedAt   = $null
                CompletedAt = $null
            }
            Save-State -State $state
        }

        $phaseState = $state.Phases[$phaseKey]

        # ── Replay-mode: only run explicitly requested phases ──────────
        $isReplayMode  = $ReplayPhases.Count -gt 0
        $isReplayPhase = $isReplayMode -and ($phaseNum -in $ReplayPhases)

        if ($isReplayMode -and -not $isReplayPhase) {
            # In replay mode, skip every phase not in the list
            continue
        }

        if ($isReplayPhase) {
            Write-Log "Phase $phaseNum ($phaseFunc): replay requested — resetting state."
            $phaseState.Attempts = 0
            $phaseState.Status   = "pending"
        }

        # ── Skip completed phases (unless -Force or replay) ────────────
        if ($phaseState.Status -eq "completed" -and -not $Force -and -not $isReplayPhase) {
            Write-Log "Phase $phaseNum ($phaseFunc): already completed — skipping."
            continue
        }

        # ── Skip phases whose condition is not met ─────────────────────
        if ($phaseState.Status -eq "skipped" -and -not $Force -and -not $isReplayPhase) {
            Write-Log "Phase $phaseNum ($phaseFunc): previously skipped — skipping."
            continue
        }
        if ($phaseDef.Condition -and -not (& $phaseDef.Condition)) {
            Write-Log "Phase $phaseNum ($phaseFunc): condition not met — skipping."
            $phaseState.Status = "skipped"
            $state.Phases[$phaseKey] = $phaseState
            Save-State -State $state
            continue
        }

        # ── Guard: max attempts ────────────────────────────────────────
        if ($phaseState.Attempts -ge $MaxAttempts -and -not $Force -and -not $isReplayPhase) {
            Write-Log "ERROR: Phase $phaseNum ($phaseFunc) has failed $($phaseState.Attempts) times (max $MaxAttempts). Stopping." -Level Error
            $allPhasesCompleted = $false
            break
        }

        # ── Increment attempt counter ─────────────────────────────────
        $phaseState.Attempts   += 1
        $phaseState.Status      = "in-progress"
        $phaseState.StartedAt   = (Get-Date -Format 'o')
        $state.Phases[$phaseKey] = $phaseState
        Save-State -State $state

        Write-Log "────────────────────────────────────────────────"
        Write-Log "Phase $phaseNum ($phaseFunc) — attempt $($phaseState.Attempts) of $MaxAttempts"
        Write-Log "────────────────────────────────────────────────"

        # ── Dot-source the phase script ────────────────────────────────
        $phaseScriptPath = Join-Path $phasesDir $phaseFile
        if (-not (Test-Path $phaseScriptPath)) {
            Write-Log "ERROR: Phase script not found: $phaseScriptPath" -Level Error
            $phaseState.Status = "error"
            $state.Phases[$phaseKey] = $phaseState
            Save-State -State $state
            $allPhasesCompleted = $false
            break
        }

        . $phaseScriptPath

        # ── Execute the phase function ─────────────────────────────────
        try {
            $ErrorActionPreference = 'Stop'
            $result = & $phaseFunc
        } catch {
            Write-Log "ERROR: Phase $phaseNum ($phaseFunc) threw an exception: $_" -Level Error
            Write-Log $_.ScriptStackTrace -Level Error
            $phaseState.Status = "error"
            $state.Phases[$phaseKey] = $phaseState
            Save-State -State $state
            $allPhasesCompleted = $false
            # Don't break — let the next run retry via the scheduled task.
            break
        }

        # ── Handle phase result ────────────────────────────────────────
        switch ($result) {
            "reboot" {
                Write-Log "Phase $phaseNum ($phaseFunc) requests a reboot."
                $phaseState.Status = "pending-reboot"
                $state.Phases[$phaseKey] = $phaseState
                Save-State -State $state

                # Complete-Phase is NOT called yet — the phase will be
                # marked completed by the phase itself on the next run,
                # or the orchestrator will re-enter the phase after reboot
                # and the phase function should detect the work is done
                # and return success immediately (idempotent).
                Request-Reboot
                Write-Log "Exiting bootstrap.ps1 — will resume after reboot."
                exit 0
            }

            "success" {
                $phaseState.Status      = "completed"
                $phaseState.CompletedAt = (Get-Date -Format 'o')
                $state.Phases[$phaseKey] = $phaseState
                Save-State -State $state
                Write-Log "Phase $phaseNum ($phaseFunc) completed successfully."

                # After Phase 5 (CreateServiceAccounts), sp_setup now exists —
                # re-register the scheduled task to run as sp_setup instead of SYSTEM.
                if ($phaseNum -eq 5) {
                    Write-Log "Re-registering bootstrap task to run as sp_setup..."
                    Register-BootstrapTask -ForceReRegister
                }
            }

            default {
                # Treat any other truthy/null return as success
                # (phase functions that don't explicitly return a value).
                $phaseState.Status      = "completed"
                $phaseState.CompletedAt = (Get-Date -Format 'o')
                $state.Phases[$phaseKey] = $phaseState
                Save-State -State $state
                Write-Log "Phase $phaseNum ($phaseFunc) completed (implicit success)."
            }
        }
    }

    # ── Post-completion ─────────────────────────────────────────────────
    if ($allPhasesCompleted) {
        # Verify every phase is marked completed
        $incomplete = $PhaseDefinitions | Where-Object {
            $key = "Phase$($_.Number)"
            $state.Phases[$key].Status -notin @("completed","skipped")
        }

        if ($incomplete) {
            Write-Log "Some phases are not yet completed. Will resume on next run."
        } else {
            Write-Log "All $($PhaseDefinitions.Count) phases completed successfully!"
            Unregister-BootstrapTask
            Write-CompletionSummary -State $state

            # Create the COMPLETED marker file
            Get-Date -Format 'o' | Set-Content -Path $CompletedMarker -Encoding UTF8 -Force
            Write-Log "Marker file created: $CompletedMarker"
            Write-Log "SPSE dev-box provisioning is DONE."
        }
    }

} catch {
    # Top-level catch — ensures any unexpected error is logged.
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $msg = "[$ts] FATAL ERROR in bootstrap.ps1: $_"
    # Write-Log may not be available if helpers failed to load.
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $msg -Level Error
        Write-Log $_.ScriptStackTrace -Level Error
    } else {
        Write-Error $msg
        Write-Error $_.ScriptStackTrace
    }
    exit 1
}
