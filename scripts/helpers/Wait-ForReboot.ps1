#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Scheduled-task and reboot management for multi-phase provisioning.
.DESCRIPTION
    Provides helpers to register/unregister the bootstrap scheduled task and
    to request a reboot.  Called from bootstrap.ps1 which sets the script-scope
    variables these functions depend on ($script:TaskName, $script:ScriptsRoot,
    $script:Params with DomainNetBIOS and DomainAdminPassword).
    Requires Common.ps1 to be dot-sourced first for Write-Log.
#>

# ---------------------------------------------------------------------------
# Task registration
# ---------------------------------------------------------------------------
function Register-BootstrapTask {
    <# Register a scheduled task that re-invokes bootstrap.ps1 at startup.
       Uses DOMAIN\sp_setup when the account exists (after Phase 05), otherwise
       falls back to NT AUTHORITY\SYSTEM for early phases before the domain
       service accounts are created.
       Reads $script:TaskName, $script:ScriptsRoot, and $script:Params from
       the calling bootstrap.ps1 scope. #>
    param([switch]$ForceReRegister)

    $taskName       = $script:TaskName
    $bootstrapPath  = Join-Path $script:ScriptsRoot "bootstrap.ps1"
    $domainNetBIOS  = if ($script:Params) { $script:Params.DomainNetBIOS } else { $script:DomainNetBIOS }
    $adminPassword  = if ($script:Params) { $script:Params.DomainAdminPassword } else { $script:DomainAdminPassword }
    $spSetupAccount = "$domainNetBIOS\sp_setup"

    # Clean up stale task from older versions (used a different name)
    $legacyTaskName = "SPSEDevSetup-Bootstrap"
    if (Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $legacyTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Removed legacy scheduled task '$legacyTaskName'."
    }

    # Determine whether sp_setup exists in AD
    $useSpSetup = $false
    try {
        $null = Get-ADUser -Identity "sp_setup" -ErrorAction Stop
        $useSpSetup = $true
    }
    catch {
        $useSpSetup = $false
    }

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing -and -not $ForceReRegister) {
        $existingPath = $existing.Actions[0].Arguments
        if ($existingPath -like "*$bootstrapPath*") {
            Write-Log "Scheduled task '$taskName' already registered — skipping."
            return
        }
        Write-Log "Scheduled task '$taskName' points to a different path — re-registering." -Level Debug
    }

    # Remove existing task before (re-)registering
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $action  = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bootstrapPath`""

    $trigger = New-ScheduledTaskTrigger -AtStartup

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    if ($useSpSetup) {
        Register-ScheduledTask `
            -TaskName  $taskName `
            -Action    $action `
            -Trigger   $trigger `
            -Settings  $settings `
            -User      $spSetupAccount `
            -Password  $adminPassword `
            -Description "SPSESetup bootstrap — continues provisioning after reboot (runs as $spSetupAccount)" `
            -Force | Out-Null

        # Elevate to Highest run level (not settable in the same call with -User/-Password)
        $task = Get-ScheduledTask -TaskName $taskName
        $task.Principal.RunLevel = 1  # 1 = Highest
        Set-ScheduledTask -InputObject $task -User $spSetupAccount -Password $adminPassword | Out-Null

        Write-Log "Scheduled task '$taskName' registered (runs as $spSetupAccount, RunLevel=Highest)."
    }
    else {
        $principal = New-ScheduledTaskPrincipal `
            -UserId "NT AUTHORITY\SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest

        Register-ScheduledTask `
            -TaskName  $taskName `
            -Action    $action `
            -Trigger   $trigger `
            -Principal $principal `
            -Settings  $settings `
            -Description "SPSESetup bootstrap — continues provisioning after reboot (SYSTEM — sp_setup not yet available)" `
            -Force | Out-Null

        Write-Log "Scheduled task '$taskName' registered (runs as SYSTEM — sp_setup account not yet created)."
    }
}

# ---------------------------------------------------------------------------
# Task removal
# ---------------------------------------------------------------------------
function Unregister-BootstrapTask {
    <# Remove the scheduled task after all phases complete. #>
    $taskName = $script:TaskName
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Log "Scheduled task '$taskName' unregistered."
    }
}

# ---------------------------------------------------------------------------
# Reboot request
# ---------------------------------------------------------------------------
function Request-Reboot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(5, 600)]
        [int]$DelaySeconds = 15
    )

    Write-Log "Reboot requested – system will restart in $DelaySeconds seconds"

    try {
        & shutdown.exe /r /t $DelaySeconds /f /d p:4:1 /c "SPSE Dev Box provisioning – scheduled reboot"
        Write-Log "Reboot command issued (shutdown /r /t $DelaySeconds /f)"
    }
    catch {
        Write-Log "Failed to issue reboot command: $_" -Level ERROR
        throw
    }

    return "reboot"
}
