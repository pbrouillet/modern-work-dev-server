<#
.SYNOPSIS
    Create storage account, blob containers, and upload provisioning assets.
.DESCRIPTION
    Runs before any Bicep layer.  Creates the storage account and blob
    containers via az CLI, assigns RBAC, uploads scripts/ and ISOs to blob,
    and persists the storage account name into azd env variables so the
    compute Bicep layer can consume it via ${storageAccountName}.

    This eliminates the race condition where the VM Custom Script Extension
    runs before blobs are uploaded.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Resolve azd environment values
# ─────────────────────────────────────────────────────────────────────────────
$envOutput = azd env get-values 2>$null

function Get-EnvValue([string]$key) {
    if ($envOutput) {
        $match = $envOutput | Select-String -Pattern "^${key}=`"?([^`"]+)`"?$"
        if ($match) { return $match.Matches[0].Groups[1].Value }
    }
    return [System.Environment]::GetEnvironmentVariable($key)
}

$EnvironmentName = Get-EnvValue 'AZURE_ENV_NAME'
$Location        = Get-EnvValue 'AZURE_LOCATION'
$SubscriptionId  = Get-EnvValue 'AZURE_SUBSCRIPTION_ID'

if (-not $EnvironmentName) { throw "AZURE_ENV_NAME not set. Run 'azd init' first." }
if (-not $Location)        { throw "AZURE_LOCATION not set. Run 'azd env set AZURE_LOCATION <region>'." }

$ResourceGroup = Get-EnvValue 'AZURE_RESOURCE_GROUP'
if (-not $ResourceGroup) { $ResourceGroup = "rg-$EnvironmentName" }

Write-Host ""
Write-Host "=== Preprovision: Storage Account Setup ===" -ForegroundColor Green
Write-Host "  Environment:    $EnvironmentName" -ForegroundColor Yellow
Write-Host "  Location:       $Location" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Yellow
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. Ensure resource group exists
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Ensuring resource group '$ResourceGroup' exists..." -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --tags project=MW-SPSE environment=$EnvironmentName -o none 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create resource group '$ResourceGroup'"
}
Write-Host "  Resource group ready." -ForegroundColor Green

# Persist so AZD and subsequent layers know which RG to use
azd env set AZURE_RESOURCE_GROUP $ResourceGroup 2>$null

# ─────────────────────────────────────────────────────────────────────────────
# 2. Compute storage account name (must match Bicep's uniqueString)
# ─────────────────────────────────────────────────────────────────────────────
$StorageAccountName = Get-EnvValue 'storageAccountName'

if (-not $StorageAccountName) {
    Write-Host "Computing storage account name via uniqueString()..." -ForegroundColor Cyan

    # Deploy a zero-resource ARM template to evaluate uniqueString server-side.
    # This guarantees the exact same output as Bicep's uniqueString(resourceGroup().id).
    $templateFile = Join-Path $env:TEMP 'eval-uniquestring.json'
    @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [],
  "outputs": {
    "suffix": {
      "type": "string",
      "value": "[uniqueString(resourceGroup().id)]"
    }
  }
}
'@ | Set-Content -Path $templateFile -Encoding UTF8

    $suffix = az deployment group create `
        --resource-group $ResourceGroup `
        --template-file $templateFile `
        --name 'eval-uniquestring' `
        --query 'properties.outputs.suffix.value' `
        -o tsv 2>&1

    Remove-Item $templateFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or -not $suffix) {
        throw "Failed to evaluate uniqueString for storage account name: $suffix"
    }

    $StorageAccountName = "stspse$suffix"
    Write-Host "  Computed: $StorageAccountName" -ForegroundColor Green
} else {
    Write-Host "  Using existing: $StorageAccountName" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Create storage account (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Creating storage account '$StorageAccountName'..." -ForegroundColor Cyan

$existing = az storage account show -n $StorageAccountName -g $ResourceGroup --query name -o tsv 2>$null
if ($existing) {
    Write-Host "  Storage account already exists — skipping create." -ForegroundColor Green
} else {
    az storage account create `
        --name $StorageAccountName `
        --resource-group $ResourceGroup `
        --location $Location `
        --kind StorageV2 `
        --sku Standard_LRS `
        --allow-blob-public-access false `
        --public-network-access Enabled `
        --default-action Allow `
        --tags project=MW-SPSE environment=$EnvironmentName `
        -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create storage account '$StorageAccountName'"
    }
    Write-Host "  Storage account created." -ForegroundColor Green
}

# Ensure firewall is open for uploads (may have been set to Deny on a prior run)
$currentAction = az storage account show -n $StorageAccountName -g $ResourceGroup --query "networkRuleSet.defaultAction" -o tsv 2>$null
if ($currentAction -eq 'Deny') {
    Write-Host "  Opening storage firewall for uploads..." -ForegroundColor Yellow
    az storage account update --name $StorageAccountName -g $ResourceGroup --default-action Allow -o none 2>&1
    # Wait for propagation
    Start-Sleep -Seconds 15
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Ensure current user has Storage Blob Data Contributor RBAC
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Checking Storage Blob Data Contributor RBAC..." -ForegroundColor Cyan

$storageScope = az storage account show -n $StorageAccountName -g $ResourceGroup --query id -o tsv 2>$null
$requiredRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

# Get user OID from access token JWT (avoids Graph API / CAE issues)
$userId = $null
try {
    $token = az account get-access-token --query accessToken -o tsv 2>$null
    if ($token) {
        $payload = $token.Split('.')[1].Replace('-','+').Replace('_','/')
        $pad = 4 - ($payload.Length % 4)
        if ($pad -lt 4) { $payload += ('=' * $pad) }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $userId = $decoded.oid
    }
} catch {
    # Fall through — will be handled below
}

if (-not $userId) {
    throw "Could not determine user ID from access token. Run 'az login' and retry."
}

$existingRole = az role assignment list --assignee $userId --role $requiredRoleId --scope $storageScope --query "[0].id" -o tsv 2>$null
if ($existingRole) {
    Write-Host "  RBAC already assigned." -ForegroundColor Green
} else {
    Write-Host "  Assigning Storage Blob Data Contributor..." -ForegroundColor Yellow
    az role assignment create --assignee-object-id $userId --assignee-principal-type User --role $requiredRoleId --scope $storageScope -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to assign Storage Blob Data Contributor RBAC on '$StorageAccountName'. Check permissions (Owner or User Access Administrator required)."
    }
    Write-Host "  Role assigned. Waiting 30s for propagation..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 30
    Write-Host "  Done." -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. Create blob containers (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Ensuring blob containers exist..." -ForegroundColor Cyan

foreach ($container in @('scripts', 'isos')) {
    az storage container create `
        --name $container `
        --account-name $StorageAccountName `
        --auth-mode login `
        --public-access off `
        -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create blob container '$container'. RBAC may not have propagated — wait a minute and retry."
    }
    Write-Host "  Container '$container' ready." -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Persist outputs to azd env
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "Persisting storage outputs to azd env..." -ForegroundColor Cyan

azd env set storageAccountName $StorageAccountName 2>$null
azd env set blobEndpoint "https://$StorageAccountName.blob.core.windows.net/" 2>$null
azd env set storageResourceGroup $ResourceGroup 2>$null
azd env set scriptsContainerName scripts 2>$null
azd env set isosContainerName isos 2>$null

Write-Host "  storageAccountName=$StorageAccountName" -ForegroundColor DarkGray
Write-Host "  Outputs persisted." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# 7. Upload scripts and ISOs
# ─────────────────────────────────────────────────────────────────────────────
$projectRoot = Split-Path $PSScriptRoot -Parent
$uploadScript = Join-Path $PSScriptRoot 'upload-scripts.ps1'

if (Test-Path $uploadScript) {
    Write-Host ""
    Write-Host "Uploading provisioning assets to blob storage..." -ForegroundColor Cyan
    & $uploadScript -StorageAccountName $StorageAccountName
    if ($LASTEXITCODE -ne 0) {
        throw "upload-scripts.ps1 failed. Scripts may not be available in blob storage."
    }
} else {
    Write-Warning "upload-scripts.ps1 not found at $uploadScript — skipping upload."
}

Write-Host ""
Write-Host "=== Preprovision: Storage Setup Complete ===" -ForegroundColor Green
Write-Host ""
