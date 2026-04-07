#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Downloads files from Azure Blob Storage with retry and hash verification.
.DESCRIPTION
    Uses BITS transfer as the primary download method with Invoke-WebRequest as
    a fallback.  Supports optional SHA256 hash verification and configurable
    retry logic.  Requires Common.ps1 to be dot-sourced first for Write-Log.
#>

function Download-FromBlob {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$BlobBaseUrl,

        [Parameter(Mandatory)]
        [string]$FileName,

        [string]$SasToken = "",

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [string]$ExpectedHash = "",

        [ValidateRange(1, 10)]
        [int]$MaxRetries = 3
    )

    # If no SAS token, acquire a bearer token from the VM's managed identity (IMDS)
    $bearerToken = $null
    if (-not $SasToken) {
        try {
            $tokenResponse = Invoke-RestMethod `
                -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/' `
                -Headers @{ Metadata = 'true' } `
                -UseBasicParsing `
                -ErrorAction Stop
            $bearerToken = $tokenResponse.access_token
            Write-Log "Acquired managed identity bearer token for storage access"
        } catch {
            Write-Log "WARNING: Failed to acquire managed identity token: $_" -Level WARN
            Write-Log "Falling back to anonymous access (SAS token not provided)" -Level WARN
        }
    }

    $fullUrl = if ($SasToken) { "$BlobBaseUrl/$FileName$SasToken" } else { "$BlobBaseUrl/$FileName" }
    # Log the URL without the SAS token to avoid leaking secrets
    $safeUrl = "$BlobBaseUrl/$FileName"

    Write-Log "Starting download: $safeUrl -> $DestinationPath"

    # Ensure destination directory exists
    $destDir = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Write-Log "Created destination directory: $destDir"
    }

    # Remove partial/previous download
    if (Test-Path $DestinationPath) {
        Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        Write-Log "Removed existing file at destination" -Level DEBUG
    }

    $attempt = 0
    $downloaded = $false

    while (-not $downloaded -and $attempt -lt $MaxRetries) {
        $attempt++
        Write-Log "Download attempt $attempt of $MaxRetries for $FileName"

        # --- Primary: BITS Transfer (only works with SAS token URLs, not bearer tokens) ---
        if (-not $bearerToken) {
            try {
                Write-Log "Trying BITS transfer..." -Level DEBUG
                Import-Module BitsTransfer -ErrorAction Stop

                Start-BitsTransfer -Source $fullUrl `
                                   -Destination $DestinationPath `
                                   -DisplayName "SPSE Download: $FileName" `
                                   -Description "Downloading $FileName from Azure Blob Storage" `
                                   -ErrorAction Stop

                if (Test-Path $DestinationPath) {
                    $downloaded = $true
                    Write-Log "BITS transfer completed for $FileName"
                }
                else {
                    Write-Log "BITS transfer reported success but file not found at $DestinationPath" -Level WARN
                }
            }
            catch {
                Write-Log "BITS transfer failed: $_" -Level WARN

                # Clean up partial BITS download
                if (Test-Path $DestinationPath) {
                    Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # --- Fallback / Primary for bearer token: Invoke-WebRequest ---
        if (-not $downloaded) {
            try {
                Write-Log "Downloading via Invoke-WebRequest..." -Level DEBUG

                # Suppress progress bar for dramatically faster downloads
                $previousProgressPref = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'

                try {
                    $webParams = @{
                        Uri             = $fullUrl
                        OutFile         = $DestinationPath
                        UseBasicParsing = $true
                        ErrorAction     = 'Stop'
                    }
                    if ($bearerToken) {
                        $webParams.Headers = @{
                            Authorization    = "Bearer $bearerToken"
                            'x-ms-version'   = '2020-04-08'
                            'x-ms-blob-type' = 'BlockBlob'
                        }
                    }
                    Invoke-WebRequest @webParams
                }
                finally {
                    $ProgressPreference = $previousProgressPref
                }

                if (Test-Path $DestinationPath) {
                    $downloaded = $true
                    Write-Log "Invoke-WebRequest download completed for $FileName"
                }
                else {
                    Write-Log "Invoke-WebRequest reported success but file not found at $DestinationPath" -Level WARN
                }
            }
            catch {
                Write-Log "Invoke-WebRequest failed: $_" -Level WARN

                # Clean up partial download
                if (Test-Path $DestinationPath) {
                    Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $downloaded -and $attempt -lt $MaxRetries) {
            $backoff = 30 * $attempt
            Write-Log "Waiting $backoff seconds before retry..." -Level WARN
            Start-Sleep -Seconds $backoff
        }
    }

    if (-not $downloaded) {
        $msg = "Failed to download $FileName after $MaxRetries attempts"
        Write-Log $msg -Level ERROR
        throw $msg
    }

    # --- Hash verification ---
    if ($ExpectedHash -and $ExpectedHash.Length -gt 0) {
        Write-Log "Verifying SHA256 hash for $FileName..."

        try {
            $actualHash = (Get-FileHash -Path $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash

            if ($actualHash -ne $ExpectedHash.ToUpper()) {
                Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
                $msg = "Hash mismatch for $FileName – expected $ExpectedHash, got $actualHash"
                Write-Log $msg -Level ERROR
                throw $msg
            }

            Write-Log "Hash verification passed for $FileName"
        }
        catch [System.IO.IOException] {
            $msg = "Unable to compute hash for $FileName`: $_"
            Write-Log $msg -Level ERROR
            throw $msg
        }
    }
    else {
        Write-Log "No expected hash provided – skipping verification" -Level DEBUG
    }

    $fileSize = (Get-Item $DestinationPath).Length
    $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
    Write-Log "Download complete: $FileName ($fileSizeMB MB)"

    return $true
}
