<#
.SYNOPSIS
    Upload provisioning scripts and ISOs to Azure Blob Storage.
.DESCRIPTION
    Uploads scripts/ to the 'scripts' blob container and isos/ to the
    'isos' blob container in the storage account created by the 'storage'
    AZD layer.  Run this after 'azd provision storage' and before
    'azd provision compute'.

    Automatically opens the storage account firewall during upload (sets
    default action to Allow) and restores it to Deny afterwards.
.EXAMPLE
    .\hooks\upload-scripts.ps1
.EXAMPLE
    .\hooks\upload-scripts.ps1 -StorageAccountName mystorageaccount
.EXAMPLE
    .\hooks\upload-scripts.ps1 -SkipIsos
#>
[CmdletBinding()]
param(
    [string]$StorageAccountName,
    [switch]$SkipIsos,
    [switch]$SkipScripts
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$scriptsDir = Join-Path $projectRoot "scripts"
$isosDir = Join-Path $projectRoot "isos"

# ── Resolve storage account name ────────────────────────────────────────────
if (-not $StorageAccountName) {
    Write-Host "Reading storage account name from AZD environment..." -ForegroundColor Cyan
    try {
        $envOutput = azd env get-values 2>$null
        $match = $envOutput | Select-String -Pattern '^storageAccountName="?([^"]+)"?$'
        if ($match) {
            $StorageAccountName = $match.Matches[0].Groups[1].Value
        }
    } catch {}

    if (-not $StorageAccountName) {
        $StorageAccountName = $env:storageAccountName
    }

    if (-not $StorageAccountName) {
        Write-Error "Could not determine storage account name. Run 'azd provision storage' first, or pass -StorageAccountName."
        exit 1
    }
}

Write-Host ""
Write-Host "=== Upload to Blob Storage ===" -ForegroundColor Green
Write-Host "Storage Account: $StorageAccountName" -ForegroundColor Yellow
Write-Host ""

# ── Ensure RBAC: Storage Blob Data Contributor ──────────────────────────────
# Required for OAuth uploads to blob. If the role is missing, assign it
# automatically and wait for propagation.
$requiredRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' # Storage Blob Data Contributor
$storageScope   = az storage account show -n $StorageAccountName --query id -o tsv 2>$null
if (-not $storageScope) {
    Write-Error "Storage account '$StorageAccountName' not found. Run 'azd provision storage' first."
    exit 1
}

$userId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $userId) {
    # Graph API may be blocked by Continuous Access Evaluation (CAE) policy.
    # Fall back to extracting the object ID from the ARM access token JWT.
    Write-Host "Graph API unavailable — extracting user ID from access token..." -ForegroundColor Yellow
    try {
        $token = az account get-access-token --query accessToken -o tsv 2>$null
        if ($token) {
            $payload = $token.Split('.')[1].Replace('-','+').Replace('_','/')
            $pad = 4 - ($payload.Length % 4)
            if ($pad -lt 4) { $payload += ('=' * $pad) }
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            $userId = $decoded.oid
            $script:UseObjectIdAssignment = $true
        }
    } catch {
        Write-Host "  Failed to extract user ID from token: $_" -ForegroundColor Yellow
    }
}
if ($userId) {
    Write-Host "Checking RBAC for current user on storage account..." -ForegroundColor Cyan
    $existingRole = az role assignment list `
        --assignee $userId `
        --role $requiredRoleId `
        --scope $storageScope `
        --query "[0].id" -o tsv 2>$null

    if ($existingRole) {
        Write-Host "  Storage Blob Data Contributor role is already assigned." -ForegroundColor Green
    } else {
        Write-Host "  Role not found — assigning Storage Blob Data Contributor..." -ForegroundColor Yellow
        if ($script:UseObjectIdAssignment) {
            az role assignment create --assignee-object-id $userId --assignee-principal-type User --role $requiredRoleId --scope $storageScope 2>&1 | Out-Null
        } else {
            az role assignment create --assignee $userId --role $requiredRoleId --scope $storageScope 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to assign RBAC role automatically. If uploads fail, ask a subscription Owner to grant you 'Storage Blob Data Contributor' on $StorageAccountName."
        } else {
            Write-Host "  Role assigned. Waiting for RBAC propagation (~30 s)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 30
            Write-Host "  Done." -ForegroundColor Green
        }
    }
} else {
    Write-Host "Could not determine signed-in user — skipping RBAC check." -ForegroundColor Yellow
    Write-Host "If uploads fail with 403, ensure you have 'Storage Blob Data Contributor' on $StorageAccountName." -ForegroundColor Yellow
}
Write-Host ""

# ── Get storage context for uploads ─────────────────────────────────────────
# NOTE: Uses Azure AD auth (--auth-mode login) because Azure Policy disables
# shared key access on the storage account.
Write-Host "Using Azure AD authentication (az login) for uploads..." -ForegroundColor Cyan

# ── Open storage firewall for upload ────────────────────────────────────────
$script:FirewallOpened = $false

function Open-StorageFirewall {
    param([string]$AccountName)

    Write-Host "Checking storage network rules..." -ForegroundColor Cyan
    $defaultAction = az storage account show -n $AccountName --query "networkRuleSet.defaultAction" -o tsv 2>$null
    if ($defaultAction -ne "Deny") {
        Write-Host "  Network default action is already Allow — no firewall changes needed." -ForegroundColor Green
        return $true
    }

    Write-Host "  Opening storage firewall (setting default action to Allow)..." -ForegroundColor Yellow
    az storage account update --name $AccountName --default-action Allow 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to update firewall. Check permissions." -ForegroundColor Red
        return $false
    }

    $script:FirewallOpened = $true

    # Verify via control-plane (no data-plane auth needed) then add a brief
    # propagation delay for the data-plane to catch up.
    Write-Host "  Verifying firewall change..." -ForegroundColor DarkGray
    $probeOk = $false
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 5
        Write-Host "    Probe $i/6..." -ForegroundColor DarkGray -NoNewline
        $currentAction = az storage account show -n $AccountName --query "networkRuleSet.defaultAction" -o tsv 2>$null
        if ($currentAction -eq 'Allow') {
            Write-Host " OK" -ForegroundColor Green
            $probeOk = $true
            break
        }
        Write-Host " not yet" -ForegroundColor Yellow
    }

    if (-not $probeOk) {
        Write-Host "  WARNING: Could not confirm firewall change, proceeding anyway." -ForegroundColor Yellow
    } else {
        # Data-plane can lag behind control-plane by a few seconds
        Write-Host "  Waiting 15 s for data-plane propagation..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }

    Write-Host "  Storage account firewall set to Allow." -ForegroundColor Green
    return $true
}

function Close-StorageFirewall {
    param([string]$AccountName)

    if ($script:FirewallOpened) {
        Write-Host "Restoring storage firewall (setting default action to Deny)..." -ForegroundColor Cyan
        az storage account update --name $AccountName --default-action Deny 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Firewall restored to Deny." -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Failed to restore firewall to Deny. Run manually:" -ForegroundColor Red
            Write-Host "    az storage account update --name $AccountName --default-action Deny" -ForegroundColor Yellow
        }
    }
}

$networkOk = Open-StorageFirewall -AccountName $StorageAccountName
if (-not $networkOk) {
    Write-Error "Cannot access storage account. See instructions above."
    exit 1
}
Write-Host ""

# ── Helper: upload a directory to a blob container ──────────────────────────
function Upload-ToContainer {
    param(
        [string]$SourceDir,
        [string]$ContainerName,
        [string]$Label
    )

    if (-not (Test-Path $SourceDir)) {
        Write-Host "  Directory not found: $SourceDir — skipping $Label." -ForegroundColor Yellow
        return $true
    }

    $fileCount = (Get-ChildItem $SourceDir -Recurse -File).Count
    if ($fileCount -eq 0) {
        Write-Host "  No files in $SourceDir — skipping $Label." -ForegroundColor Yellow
        return $true
    }

    $totalSize = (Get-ChildItem $SourceDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $sizeLabel = if ($totalSize -gt 1GB) { "{0:N2} GB" -f ($totalSize / 1GB) }
                 elseif ($totalSize -gt 1MB) { "{0:N1} MB" -f ($totalSize / 1MB) }
                 else { "{0:N0} KB" -f ($totalSize / 1KB) }

    Write-Host "Uploading $Label ($fileCount files, $sizeLabel) to container '$ContainerName' ..." -ForegroundColor Cyan

    Get-ChildItem $SourceDir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($SourceDir.Length + 1)
        $fSize = if ($_.Length -gt 1GB) { "{0:N2} GB" -f ($_.Length / 1GB) }
                 elseif ($_.Length -gt 1MB) { "{0:N0} MB" -f ($_.Length / 1MB) }
                 else { "{0:N0} KB" -f ($_.Length / 1KB) }
        Write-Host "  $rel ($fSize)" -ForegroundColor DarkGray
    }

    Write-Host "  Uploading to blob container..." -ForegroundColor DarkGray
    $output = az storage blob upload-batch `
        --account-name $StorageAccountName `
        --auth-mode login `
        --destination $ContainerName `
        --source $SourceDir `
        --overwrite `
        2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-Host "  FAILED (exit code $exitCode):" -ForegroundColor Red
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  Troubleshooting:" -ForegroundColor Yellow
        Write-Host "    1. Run 'az login' and verify your subscription" -ForegroundColor Yellow
        Write-Host "    2. Run 'az account show' to check active subscription" -ForegroundColor Yellow
        Write-Host "    3. Verify the container '$ContainerName' exists in the storage account" -ForegroundColor Yellow
        return $false
    }

    $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Host "  $Label uploaded successfully." -ForegroundColor Green
    return $true
}

# ── Upload scripts ──────────────────────────────────────────────────────────
$scriptsOk = $true
if (-not $SkipScripts) {
    $scriptsOk = Upload-ToContainer -SourceDir $scriptsDir -ContainerName "scripts" -Label "provisioning scripts"
    Write-Host ""
}

# ── Upload ISOs ─────────────────────────────────────────────────────────────
$isosOk = $true
if (-not $SkipIsos) {
    $isosOk = Upload-ToContainer -SourceDir $isosDir -ContainerName "isos" -Label "ISO images"
    Write-Host ""
}

# ── Cleanup: restore storage firewall ───────────────────────────────────────
Close-StorageFirewall -AccountName $StorageAccountName

# ── Summary ─────────────────────────────────────────────────────────────────
if ($scriptsOk -and $isosOk) {
    Write-Host "=== All uploads complete ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step:" -ForegroundColor Cyan
    Write-Host "  azd provision compute" -ForegroundColor White
    Write-Host ""
} else {
    Write-Error "One or more uploads failed. See errors above."
    exit 1
}
