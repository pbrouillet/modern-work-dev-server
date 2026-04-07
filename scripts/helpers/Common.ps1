#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Shared helper functions for the SPSE Dev Box provisioning system.
.DESCRIPTION
    Provides logging, state management, phase tracking, and retry logic
    used by all provisioning phase scripts.
#>

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------
$Global:SetupRoot = "C:\SPSESetup"
$Global:StateFile = Join-Path $Global:SetupRoot "state.json"
$Global:LogFile   = Join-Path $Global:SetupRoot "setup.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "ERROR" { Write-Host $entry -ForegroundColor Red }
        "WARN"  { Write-Host $entry -ForegroundColor Yellow }
        "DEBUG" { Write-Host $entry -ForegroundColor Gray }
        default { Write-Host $entry }
    }

    try {
        $entry | Out-File -FilePath $Global:LogFile -Append -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host "[$timestamp] [WARN] Unable to write to log file: $_" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Environment initialisation
# ---------------------------------------------------------------------------
function Initialize-SetupEnvironment {
    [CmdletBinding()]
    param()

    if (-not (Test-Path $Global:SetupRoot)) {
        New-Item -ItemType Directory -Path $Global:SetupRoot -Force | Out-Null
        Write-Log "Created setup root directory: $($Global:SetupRoot)"
    }

    if (-not (Test-Path $Global:LogFile)) {
        New-Item -ItemType File -Path $Global:LogFile -Force | Out-Null
        Write-Log "Initialised log file: $($Global:LogFile)"
    }

    Write-Log "Setup environment initialised (root: $($Global:SetupRoot))"
}

# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------
function Get-SetupState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if (Test-Path $Global:StateFile) {
        try {
            $json = Get-Content -Path $Global:StateFile -Raw -ErrorAction Stop
            $obj  = $json | ConvertFrom-Json -ErrorAction Stop

            # Convert PSCustomObject to hashtable for easier manipulation
            $attempts = @{}
            if ($obj.Attempts) {
                $obj.Attempts.PSObject.Properties | ForEach-Object {
                    $attempts[$_.Name] = [int]$_.Value
                }
            }

            $completedPhases = @()
            if ($obj.CompletedPhases) {
                $completedPhases = @($obj.CompletedPhases | ForEach-Object { [int]$_ })
            }

            return @{
                CurrentPhase    = [int]$obj.CurrentPhase
                CompletedPhases = $completedPhases
                StartTime       = $obj.StartTime
                LastPhaseTime   = $obj.LastPhaseTime
                Attempts        = $attempts
            }
        }
        catch {
            Write-Log "Failed to read state file, returning default state: $_" -Level WARN
        }
    }

    # Default state – no phases completed
    return @{
        CurrentPhase    = 0
        CompletedPhases = @()
        StartTime       = (Get-Date -Format "o")
        LastPhaseTime   = $null
        Attempts        = @{}
    }
}

function Set-SetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $Global:StateFile -Encoding UTF8 -Force -ErrorAction Stop
        Write-Log "State saved (CurrentPhase=$($State.CurrentPhase), Completed=[$($State.CompletedPhases -join ', ')])" -Level DEBUG
    }
    catch {
        Write-Log "Failed to write state file: $_" -Level ERROR
        throw
    }
}

# ---------------------------------------------------------------------------
# Phase tracking
# ---------------------------------------------------------------------------
function Complete-Phase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PhaseNumber
    )

    $state = Get-SetupState

    if ($state.CompletedPhases -notcontains $PhaseNumber) {
        $state.CompletedPhases += $PhaseNumber
    }

    $state.CurrentPhase  = $PhaseNumber + 1
    $state.LastPhaseTime = (Get-Date -Format "o")

    Set-SetupState -State $state

    Write-Log "Phase $PhaseNumber completed successfully"
}

function Test-PhaseCompleted {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [int]$PhaseNumber
    )

    $state = Get-SetupState
    return ($state.CompletedPhases -contains $PhaseNumber)
}

function Get-PhaseAttempts {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$PhaseNumber
    )

    $state = Get-SetupState
    $key   = $PhaseNumber.ToString()

    if ($state.Attempts.ContainsKey($key)) {
        return [int]$state.Attempts[$key]
    }

    return 0
}

function Add-PhaseAttempt {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$PhaseNumber
    )

    $state = Get-SetupState
    $key   = $PhaseNumber.ToString()

    if ($state.Attempts.ContainsKey($key)) {
        $state.Attempts[$key] = [int]$state.Attempts[$key] + 1
    }
    else {
        $state.Attempts[$key] = 1
    }

    $newCount = $state.Attempts[$key]
    Set-SetupState -State $state

    Write-Log "Phase $PhaseNumber attempt $newCount recorded" -Level DEBUG
    return $newCount
}

# ---------------------------------------------------------------------------
# Retry helper
# ---------------------------------------------------------------------------
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3,

        [ValidateRange(0, 600)]
        [int]$DelaySeconds = 30,

        [string]$OperationName = "Operation"
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Write-Log "$OperationName – attempt $attempt of $MaxRetries"
            $result = & $ScriptBlock
            Write-Log "$OperationName – succeeded on attempt $attempt"
            return $result
        }
        catch {
            Write-Log "$OperationName – attempt $attempt failed: $_" -Level WARN

            if ($attempt -ge $MaxRetries) {
                Write-Log "$OperationName – all $MaxRetries attempts exhausted" -Level ERROR
                throw
            }

            Write-Log "$OperationName – retrying in $DelaySeconds seconds..." -Level WARN
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}
