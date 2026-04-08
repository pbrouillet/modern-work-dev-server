<#
.SYNOPSIS
    Sync files to/from Azure Blob Storage using azcopy with managed identity.
.DESCRIPTION
    Uses azcopy with the VM's system-assigned managed identity to copy files
    between blob containers and local folders.

    Dot-source this file then call Sync-FromBlob / Sync-ToBlob.

.EXAMPLE
    . C:\Installs\helpers\Sync-AzureShare.ps1

    # Pull latest scripts from the blob container to C:\SyncedBlobs\scripts
    Sync-FromBlob

    # Push local changes back
    Sync-ToBlob -Container scripts -LocalPath C:\Installs
#>

# ---------------------------------------------------------------------------
# Configuration — reads from params.json dropped by the CSE, or uses defaults
# ---------------------------------------------------------------------------

$_paramsFile = 'C:\Installs\params.json'
if (Test-Path $_paramsFile) {
    $_p = Get-Content $_paramsFile -Raw | ConvertFrom-Json
    $_StorageAccount = $_p.StorageAccountName
    $_BlobBaseUrl    = $_p.BlobBaseUrl
} else {
    $_StorageAccount = $env:AZURE_STORAGE_ACCOUNT
    $_BlobBaseUrl    = $null
    if (-not $_StorageAccount) {
        Write-Warning "No params.json found and AZURE_STORAGE_ACCOUNT not set.  Pass -StorageAccount explicitly."
    }
}

# ---------------------------------------------------------------------------
# Ensure azcopy is available
# ---------------------------------------------------------------------------

function _Ensure-Azcopy {
    # Check if already on PATH
    $existing = Get-Command azcopy -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }

    # Check the CSE download location
    $cseAzcopy = Get-ChildItem -Path "$env:TEMP\azcopy" -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cseAzcopy) { return $cseAzcopy.FullName }

    # Check C:\Installs
    $installsAzcopy = Get-ChildItem -Path 'C:\Installs' -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($installsAzcopy) { return $installsAzcopy.FullName }

    # Download fresh copy
    Write-Host "Downloading azcopy..." -ForegroundColor Cyan
    $azDir   = Join-Path $env:TEMP 'azcopy'
    $zipPath = Join-Path $env:TEMP 'azcopy.zip'
    New-Item -ItemType Directory -Path $azDir -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://aka.ms/downloadazcopy-v10-windows' -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $azDir -Force
    $dl = Get-ChildItem -Path $azDir -Recurse -Filter 'azcopy.exe' | Select-Object -First 1
    if (-not $dl) { throw "Failed to download azcopy" }
    return $dl.FullName
}

# ---------------------------------------------------------------------------
# Login helper — avoids repeated device-code prompts
# ---------------------------------------------------------------------------

function _Ensure-AzcopyLogin {
    param(
        [string]$AzcopyPath,
        [switch]$UseDeviceCode
    )

    if ($UseDeviceCode) {
        # Check whether azcopy already has a valid cached token
        $status = & $AzcopyPath login status 2>&1 | Out-String
        if ($status -match 'logged in') {
            Write-Host "azcopy already authenticated — skipping device-code flow." -ForegroundColor Green
        } else {
            Write-Host "Starting device-code login..." -ForegroundColor Cyan
            & $AzcopyPath login --login-type=DEVICE 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { throw "azcopy device-code login failed (exit $LASTEXITCODE)." }
        }
        # Clear the env var so azcopy uses the cached token instead of
        # starting a new auto-login flow on every copy command.
        Remove-Item Env:\AZCOPY_AUTO_LOGIN_TYPE -ErrorAction SilentlyContinue
    } else {
        $env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
    }
}

# ---------------------------------------------------------------------------
# Sync-FromBlob
# ---------------------------------------------------------------------------

function Sync-FromBlob {
    <#
    .SYNOPSIS
        Download files from a blob container to a local folder.
    .PARAMETER Container
        Name of the blob container (default: scripts).
    .PARAMETER LocalPath
        Local folder to download into (default: C:\SyncedBlobs\<container>).
    .PARAMETER StorageAccount
        Override the storage account name.
    .PARAMETER UseDeviceCode
        Use device-code login instead of managed identity.
    .PARAMETER Force
        Overwrite local files even if they are newer than the source.
    #>
    [CmdletBinding()]
    param(
        [string]$Container = 'scripts',
        [string]$LocalPath,
        [string]$StorageAccount = $_StorageAccount,
        [switch]$UseDeviceCode,
        [switch]$Force
    )

    if (-not $StorageAccount) { throw "StorageAccount is required. Set AZURE_STORAGE_ACCOUNT or pass -StorageAccount." }
    if (-not $LocalPath) { $LocalPath = "C:\SyncedBlobs\$Container" }

    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null

    $azcopy = _Ensure-Azcopy
    _Ensure-AzcopyLogin -AzcopyPath $azcopy -UseDeviceCode:$UseDeviceCode

    $overwrite = if ($Force) { 'true' } else { 'ifSourceNewer' }
    $src = "https://$StorageAccount.blob.core.windows.net/$Container/*"

    Write-Host "Downloading  $src  ->  $LocalPath" -ForegroundColor Cyan
    & $azcopy copy $src $LocalPath --recursive --overwrite=$overwrite --log-level=WARNING 2>&1 | Write-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Done. Files are at: $LocalPath" -ForegroundColor Green
    } else {
        Write-Warning "azcopy finished with exit code $LASTEXITCODE"
    }
}

# ---------------------------------------------------------------------------
# Sync-ToBlob
# ---------------------------------------------------------------------------

function Sync-ToBlob {
    <#
    .SYNOPSIS
        Upload local files to a blob container.
    .PARAMETER Container
        Name of the blob container (default: scripts).
    .PARAMETER LocalPath
        Local folder to upload from (default: C:\SyncedBlobs\<container>).
    .PARAMETER StorageAccount
        Override the storage account name.
    .PARAMETER UseDeviceCode
        Use device-code login instead of managed identity.
    .PARAMETER Force
        Overwrite remote files even if they are newer than the local copy.
    #>
    [CmdletBinding()]
    param(
        [string]$Container = 'scripts',
        [string]$LocalPath,
        [string]$StorageAccount = $_StorageAccount,
        [switch]$UseDeviceCode,
        [switch]$Force
    )

    if (-not $StorageAccount) { throw "StorageAccount is required. Set AZURE_STORAGE_ACCOUNT or pass -StorageAccount." }
    if (-not $LocalPath) { $LocalPath = "C:\SyncedBlobs\$Container" }
    if (-not (Test-Path $LocalPath)) { throw "Local path not found: $LocalPath" }

    $azcopy = _Ensure-Azcopy
    _Ensure-AzcopyLogin -AzcopyPath $azcopy -UseDeviceCode:$UseDeviceCode

    $overwrite = if ($Force) { 'true' } else { 'ifSourceNewer' }
    $dest = "https://$StorageAccount.blob.core.windows.net/$Container"

    Write-Host "Uploading  $LocalPath  ->  $dest" -ForegroundColor Cyan
    & $azcopy copy "$LocalPath/*" $dest --recursive --overwrite=$overwrite --log-level=WARNING 2>&1 | Write-Host
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Upload complete." -ForegroundColor Green
    } else {
        Write-Warning "azcopy finished with exit code $LASTEXITCODE"
    }
}

Write-Host "Blob sync helper loaded. Commands:" -ForegroundColor Green
Write-Host "  Sync-FromBlob  [-Container scripts|isos]  — download blob -> local" -ForegroundColor Gray
Write-Host "  Sync-ToBlob    [-Container scripts|isos]  — upload local -> blob" -ForegroundColor Gray
