param(
    [switch]$Force
)

<#
.SYNOPSIS
    Create/update the rdp-bridge Container App and build its image via ACR Tasks.
.DESCRIPTION
    1. Creates the Container App via CLI if it doesn't exist (avoids ARM timeout).
    2. Builds the rdp-bridge Docker image remotely on ACR (no local Docker needed).
    3. Assigns RBAC roles (AcrPull, VM Contributor, Reader).
    4. Updates the Container App with the real image, env vars, and secrets.

    Uses a source-hash cache (stored in azd env) to skip the ACR build when
    rdp-bridge source files haven't changed. Pass -Force to rebuild regardless.
#>

$ErrorActionPreference = 'Stop'

# ── Resolve values from azd env ─────────────────────────────────────────────
$envOutput = azd env get-values 2>$null

function Get-EnvValue([string]$key) {
    $match = $envOutput | Select-String -Pattern "^${key}=`"?([^`"]+)`"?$"
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return [System.Environment]::GetEnvironmentVariable($key)
}

$AcrName   = Get-EnvValue 'acrName'
$AcrServer = Get-EnvValue 'acrLoginServer'
$EnvName   = Get-EnvValue 'AZURE_ENV_NAME'
$RG        = Get-EnvValue 'AZURE_RESOURCE_GROUP'
$CaeName   = Get-EnvValue 'caeName'
$AppInsightsCS = Get-EnvValue 'appInsightsConnectionString'
$BridgeUser = Get-EnvValue 'bridgeAuthUsername'
$BridgePass = Get-EnvValue 'bridgeAuthPassword'
$SubId     = (az account show --query id -o tsv 2>$null)

if (-not $AcrName -or -not $RG -or -not $EnvName) {
    Write-Error "Missing required azd env values (acrName, AZURE_RESOURCE_GROUP, AZURE_ENV_NAME)."
    exit 1
}

$caName   = "ca-rdpbridge-$EnvName"
$imageTag = "rdp-bridge:latest"
$fullImage = "$AcrServer/$imageTag"

Write-Host ""
Write-Host "=== RDP Bridge: Build & Deploy ===" -ForegroundColor Green
Write-Host "Registry     : $AcrName" -ForegroundColor Yellow
Write-Host "Container App: $caName" -ForegroundColor Yellow
Write-Host ""

# ── Step 1: Create Container App if it doesn't exist ────────────────────────
$caExists = az containerapp show --name $caName --resource-group $RG --query "properties.provisioningState" -o tsv 2>$null
if (-not $caExists -or $caExists -eq 'Failed') {
    if ($caExists -eq 'Failed') {
        Write-Host "Deleting failed Container App..." -ForegroundColor Yellow
        az containerapp delete --name $caName --resource-group $RG --yes 2>&1 | Out-Null
    }
    Write-Host "Creating Container App $caName (this may take a few minutes)..." -ForegroundColor Cyan
    az containerapp create `
        --name $caName `
        --resource-group $RG `
        --environment $CaeName `
        --image "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest" `
        --target-port 8080 `
        --ingress external `
        --min-replicas 0 `
        --max-replicas 2 `
        --cpu 0.5 `
        --memory 1Gi `
        --system-assigned `
        --tags "azd-service-name=rdp-bridge" `
        2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create Container App $caName"
        exit 1
    }
    Write-Host "Container App created." -ForegroundColor Green
} else {
    Write-Host "Container App $caName already exists (state: $caExists)." -ForegroundColor Green
}

# ── Step 2: Assign RBAC roles ───────────────────────────────────────────────
$principalId = az containerapp show --name $caName --resource-group $RG --query "identity.principalId" -o tsv 2>$null
if ($principalId) {
    Write-Host "Assigning RBAC roles to $caName managed identity..." -ForegroundColor Cyan

    # AcrPull
    $acrId = az acr show --name $AcrName --query id -o tsv 2>$null
    az role assignment create --role "AcrPull" --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope $acrId 2>&1 | Out-Null

    # VM Contributor (resource group scope)
    az role assignment create --role "Virtual Machine Contributor" --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope "/subscriptions/$SubId/resourceGroups/$RG" 2>&1 | Out-Null

    # Reader (resource group scope)
    az role assignment create --role "Reader" --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --scope "/subscriptions/$SubId/resourceGroups/$RG" 2>&1 | Out-Null

    Write-Host "RBAC roles assigned." -ForegroundColor Green
}

# ── Step 3: Build image on ACR (with source-hash cache) ─────────────────────
$contextPath = Join-Path $PSScriptRoot ".." "rdp-bridge"

# Compute composite SHA256 of all build-input files
$buildInputs = @(
    Get-Item "$contextPath/Dockerfile"
    Get-Item "$contextPath/Cargo.toml"
    Get-Item "$contextPath/Cargo.lock"
    Get-ChildItem "$contextPath/src" -Recurse -File
) | Sort-Object { $_.FullName.Substring($contextPath.Length) }

$hashParts = $buildInputs | ForEach-Object {
    $rel = $_.FullName.Substring($contextPath.Length)
    $h   = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    "${rel}:${h}"
}
$composite  = ($hashParts -join "`n")
$sha        = [System.Security.Cryptography.SHA256]::Create()
$bytes      = [System.Text.Encoding]::UTF8.GetBytes($composite)
$sourceHash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
$sha.Dispose()

$cachedHash = Get-EnvValue 'rdpBridgeSourceHash'
$needsBuild = $true

if ($Force) {
    Write-Host "Force flag set — will rebuild." -ForegroundColor Yellow
} elseif (-not $cachedHash -or $cachedHash -ne $sourceHash) {
    Write-Host "Source hash changed — will rebuild." -ForegroundColor Yellow
} else {
    # Hash matches — verify the image actually exists in ACR
    $existingTag = az acr repository show-tags --name $AcrName --repository rdp-bridge --query "[?@=='latest']" -o tsv 2>$null
    if ($existingTag) {
        Write-Host "Source unchanged and image exists in ACR — skipping build." -ForegroundColor Green
        $needsBuild = $false
    } else {
        Write-Host "Source unchanged but image missing from ACR — will rebuild." -ForegroundColor Yellow
    }
}

if ($needsBuild) {
    Write-Host "Building image $imageTag on ACR..." -ForegroundColor Cyan

    az acr build `
        --registry $AcrName `
        --image $imageTag `
        --file "$contextPath/Dockerfile" `
        $contextPath

    if ($LASTEXITCODE -ne 0) {
        Write-Error "ACR build failed"
        exit 1
    }
    Write-Host "Image built and pushed." -ForegroundColor Green

    # Cache the source hash for next run
    azd env set rdpBridgeSourceHash $sourceHash 2>$null
}

# ── Step 4: Configure ACR registry on Container App ─────────────────────────
Write-Host "Configuring ACR registry on Container App..." -ForegroundColor Cyan
az containerapp registry set `
    --name $caName `
    --resource-group $RG `
    --server $AcrServer `
    --identity system `
    2>&1 | Out-Null

# ── Step 5: Update Container App with real image and env vars ───────────────
Write-Host "Updating Container App to $fullImage..." -ForegroundColor Cyan

# Build env var arguments as an array to avoid empty-value issues
$envVars = @(
    "RDP_BRIDGE_IN_AZURE=true",
    "AZURE_SUBSCRIPTION_ID=$SubId",
    "AZURE_RESOURCE_GROUP=$RG",
    "RDP_TARGET_PORT=3389",
    "RUST_LOG=rdp_bridge=info",
    "OTEL_SERVICE_NAME=rdp-bridge"
)
if ($AppInsightsCS) { $envVars += "APPLICATIONINSIGHTS_CONNECTION_STRING=$AppInsightsCS" }
if ($BridgeUser)    { $envVars += "AUTH_USERNAME=$BridgeUser" }
if ($BridgePass)    { $envVars += "AUTH_PASSWORD=$BridgePass" }

az containerapp update `
    --name $caName `
    --resource-group $RG `
    --image $fullImage `
    --min-replicas 0 `
    --set-env-vars @envVars `
    2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    $bridgeFqdn = az containerapp show --name $caName --resource-group $RG --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
    Write-Host ""
    Write-Host "RDP Bridge deployed: https://$bridgeFqdn" -ForegroundColor Green
    azd env set bridgeFqdn $bridgeFqdn 2>$null
} else {
    Write-Host "WARNING: Container App update failed. Check Azure portal." -ForegroundColor Yellow
}
