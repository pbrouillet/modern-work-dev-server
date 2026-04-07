<#
.SYNOPSIS
    Re-secure the storage account after provisioning.
.DESCRIPTION
    After 'azd provision' (or 'azd up') completes, this hook sets the storage
    account network firewall back to Deny.  The VNet rule configured during
    the compute layer deployment ensures the VM subnet retains access to
    blob storage.
#>

$ErrorActionPreference = 'Stop'

# ── Resolve storage account name from AZD environment ───────────────────────
$StorageAccountName = $null
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
    Write-Host "Could not determine storage account name — skipping firewall lock-down." -ForegroundColor Yellow
    exit 0
}

# ── Resolve environment name ─────────────────────────────────────────────────
$EnvironmentName = $null
try {
    $envMatch = $envOutput | Select-String -Pattern '^AZURE_ENV_NAME="?([^"]+)"?$'
    if ($envMatch) {
        $EnvironmentName = $envMatch.Matches[0].Groups[1].Value
    }
} catch {}
if (-not $EnvironmentName) { $EnvironmentName = $env:AZURE_ENV_NAME }

$ResourceGroup = $null
try {
    $rgMatch = $envOutput | Select-String -Pattern '^AZURE_RESOURCE_GROUP="?([^"]+)"?$'
    if ($rgMatch) {
        $ResourceGroup = $rgMatch.Matches[0].Groups[1].Value
    }
} catch {}
if (-not $ResourceGroup) { $ResourceGroup = $env:AZURE_RESOURCE_GROUP }

# ── Ensure VNet rule exists before setting Deny ─────────────────────────────
Write-Host ""
Write-Host "=== Post-Provision: Securing Storage Account ===" -ForegroundColor Green
Write-Host "Storage Account: $StorageAccountName" -ForegroundColor Yellow
Write-Host ""

if ($EnvironmentName -and $ResourceGroup) {
    $vnetName   = "vnet-spse-$EnvironmentName"
    $subnetName = 'snet-default'
    $subnetId   = az network vnet subnet show -g $ResourceGroup --vnet-name $vnetName -n $subnetName --query id -o tsv 2>$null
    if ($subnetId) {
        Write-Host "Ensuring VNet rule for $vnetName/$subnetName ..." -ForegroundColor Cyan
        az storage account network-rule add --account-name $StorageAccountName --subnet $subnetId 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "VNet rule confirmed." -ForegroundColor Green
        } else {
            Write-Host "WARNING: Failed to add VNet rule. VM may lose blob access." -ForegroundColor Yellow
        }
    } else {
        Write-Host "WARNING: Could not resolve subnet ID for $vnetName/$subnetName — skipping VNet rule." -ForegroundColor Yellow
    }
} else {
    Write-Host "WARNING: Could not determine environment/resource-group — skipping VNet rule enforcement." -ForegroundColor Yellow
}

# ── Set default action to Deny ──────────────────────────────────────────────
$currentAction = az storage account show -n $StorageAccountName --query "networkRuleSet.defaultAction" -o tsv 2>$null
if ($currentAction -eq 'Deny') {
    Write-Host "Storage firewall is already set to Deny — nothing to do." -ForegroundColor Green
    exit 0
}

Write-Host "Setting storage firewall default action to Deny..." -ForegroundColor Cyan
az storage account update --name $StorageAccountName --default-action Deny 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Storage firewall secured (default action = Deny)." -ForegroundColor Green
    Write-Host "The VM subnet retains access via the configured VNet service-endpoint rule." -ForegroundColor DarkGray
} else {
    Write-Host "WARNING: Failed to set firewall to Deny. Run manually:" -ForegroundColor Red
    Write-Host "  az storage account update --name $StorageAccountName --default-action Deny" -ForegroundColor Yellow
}
