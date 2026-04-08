<#
.SYNOPSIS
    Launches the SPSE bootstrap from the provisioned scripts directory.
.DESCRIPTION
    Reads params.json (written by the VM Custom Script Extension at deploy
    time) and invokes bootstrap.ps1 with the required parameters.

    If the bootstrap script is not present (e.g., the CSE ran before blobs
    were uploaded), this script downloads scripts from Azure Blob Storage
    using azcopy with the VM's managed identity before proceeding.

    Run this script as Administrator from an elevated PowerShell prompt.
#>
Param (
    $paramsFile = $(Join-Path $PSScriptRoot 'params.json'),

    # Optional: replay specific phases regardless of their state.
    # Example: -ReplayPhases 7,10,18
    [int[]]$ReplayPhases = @()
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $paramsFile)) {
    throw "params.json not found in $PSScriptRoot"
}

$p = Get-Content $paramsFile -Raw | ConvertFrom-Json

# ── Always sync scripts from blob to ensure latest version ──────────────────
# The CSE may have placed an older copy of scripts during initial provisioning.
# Re-download from blob every time to pick up any updates.
Write-Host 'Syncing scripts from blob storage...' -ForegroundColor Cyan

# Locate azcopy (downloaded by the CSE)
$azcopy = $null
$searchPaths = @(
    "$env:TEMP\azcopy",
    "$env:SystemRoot\Temp\azcopy",
    'C:\Installs'
)
foreach ($sp in $searchPaths) {
    if (Test-Path $sp) {
        $found = Get-ChildItem -Path $sp -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { $azcopy = $found.FullName; break }
    }
}

if ($azcopy) {
    $env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
    $blobBaseUrl = $p.BlobBaseUrl
    if (-not $blobBaseUrl) {
        $blobBaseUrl = "https://$($p.StorageAccountName).blob.core.windows.net"
    }
    $srcScripts = "$blobBaseUrl/scripts/*"
    $destScripts = $PSScriptRoot

    Write-Host "  Source:      $srcScripts" -ForegroundColor DarkGray
    Write-Host "  Destination: $destScripts" -ForegroundColor DarkGray
    $out = & $azcopy copy $srcScripts $destScripts --recursive --overwrite=true --log-level=WARNING 2>&1 | Out-String
    Write-Host $out
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING: azcopy sync failed (exit $LASTEXITCODE). Continuing with local copy." -ForegroundColor Yellow
    } else {
        Write-Host 'Scripts synced successfully.' -ForegroundColor Green
    }
} else {
    Write-Host 'WARNING: azcopy not found — running with existing local scripts.' -ForegroundColor Yellow
}

$bootstrapScript = Join-Path $PSScriptRoot 'bootstrap.ps1'
if (-not (Test-Path $bootstrapScript)) {
    throw "bootstrap.ps1 not found in $PSScriptRoot. Ensure scripts have been uploaded to the 'scripts' blob container."
}

Write-Host '=== Starting SPSE Bootstrap ===' -ForegroundColor Cyan

$bootstrapArgs = @{
    IsoBlobUrl          = $p.IsoBlobUrl
    SqlIsoFileName      = $p.SqlIsoFileName
    SpIsoFileName       = $p.SpIsoFileName
    DomainAdminPassword = $p.DomainAdminPassword
    SpFarmPassphrase    = $p.SpFarmPassphrase
}

# Pass Exchange params if present (backward-compatible with older params.json)
if ($p.PSObject.Properties['EnableExchange']) {
    $bootstrapArgs['EnableExchange'] = $p.EnableExchange
}
if ($p.PSObject.Properties['ExchangeIsoFileName']) {
    $bootstrapArgs['ExchangeIsoFileName'] = $p.ExchangeIsoFileName
}

if ($ReplayPhases.Count -gt 0) {
    $bootstrapArgs['ReplayPhases'] = $ReplayPhases
}

& (Join-Path $PSScriptRoot 'bootstrap.ps1') @bootstrapArgs
