function Invoke-Phase02-DownloadISOs {
    <#
    .SYNOPSIS
        Downloads SQL Server and SharePoint SE ISOs from Azure Blob Storage.
    .DESCRIPTION
        Uses azcopy with the VM's managed identity to download ISO files from
        the 'isos' blob container into F:\Installers.
        Validates that downloaded files exceed 100 MB as a sanity check.
    #>

    Write-Log "Phase 02 - DownloadISOs: Starting ISO download from blob storage"

    $minimumSizeBytes = 100MB
    $isoBlobUrl = $script:Params.IsoBlobUrl

    if (-not $isoBlobUrl) {
        Write-Log "ERROR: IsoBlobUrl not set in params. Check CSE provisioning." -Level Error
        throw "IsoBlobUrl not configured in params.json"
    }
    if ($isoBlobUrl -notmatch '^https://') {
        Write-Log "ERROR: IsoBlobUrl '$isoBlobUrl' is not a valid blob URL. Expected format: https://<account>.blob.core.windows.net/isos" -Level Error
        throw "IsoBlobUrl '$isoBlobUrl' is not a valid blob URL. Expected format: https://<account>.blob.core.windows.net/isos"
    }

    # ── Ensure azcopy is available ──────────────────────────────────────
    $azcopy = $null
    # Search user temp, SYSTEM temp (CSE runs as SYSTEM), and C:\Installs
    $searchPaths = @(
        "$env:TEMP\azcopy",
        "$env:SystemRoot\Temp\azcopy",
        'C:\Installs'
    )
    foreach ($searchPath in $searchPaths) {
        if (Test-Path $searchPath) {
            $found = Get-ChildItem -Path $searchPath -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { $azcopy = $found.FullName; break }
        }
    }
    # Last resort: download azcopy ourselves
    if (-not $azcopy) {
        Write-Log "azcopy not found in known locations — downloading..."
        $azDir = Join-Path $env:TEMP 'azcopy'
        New-Item -ItemType Directory -Path $azDir -Force | Out-Null
        $zipPath = Join-Path $env:TEMP 'azcopy.zip'
        Invoke-WebRequest -Uri 'https://aka.ms/downloadazcopy-v10-windows' -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $azDir -Force
        $found = Get-ChildItem -Path $azDir -Recurse -Filter 'azcopy.exe' | Select-Object -First 1
        if ($found) { $azcopy = $found.FullName }
    }
    if (-not $azcopy) {
        throw "azcopy.exe not found and could not be downloaded."
    }
    Write-Log "Using azcopy at: $azcopy"
    $env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'

    # ── Helper: download a single ISO via azcopy ────────────────────────
    function _Download-Iso {
        param([string]$FileName, [string]$DestPath, [string]$Label)

        if ((Test-Path $DestPath) -and (Get-Item $DestPath).Length -gt $minimumSizeBytes) {
            Write-Log "$Label already exists and passes size check: $DestPath"
            return
        }

        if (Test-Path $DestPath) {
            Write-Log "$Label exists but is undersized — re-downloading"
            Remove-Item -Path $DestPath -Force -ErrorAction Stop
        }

        $srcUrl = "$isoBlobUrl/$FileName"
        Write-Log "Downloading $Label : $srcUrl -> $DestPath"
        $out = & $azcopy copy $srcUrl $DestPath --log-level=WARNING 2>&1 | Out-String
        Write-Log $out
        if ($LASTEXITCODE -ne 0) {
            throw "azcopy failed to download $Label (exit code $LASTEXITCODE)"
        }
        Write-Log "$Label download completed"
    }

    # ── 1. Download SQL Server ISO ──────────────────────────────────────
    $sqlIsoPath = "F:\Installers\$($script:Params.SqlIsoFileName)"
    try {
        _Download-Iso -FileName $script:Params.SqlIsoFileName -DestPath $sqlIsoPath -Label "SQL Server ISO"
    }
    catch {
        Write-Log "ERROR downloading SQL Server ISO: $_" -Level Error
        throw
    }

    # ── 2. Download SharePoint SE ISO ───────────────────────────────────
    $spIsoPath = "F:\Installers\$($script:Params.SpIsoFileName)"
    try {
        _Download-Iso -FileName $script:Params.SpIsoFileName -DestPath $spIsoPath -Label "SharePoint SE ISO"
    }
    catch {
        Write-Log "ERROR downloading SharePoint SE ISO: $_" -Level Error
        throw
    }

    # ── 3. Conditionally download Exchange SE ISO ───────────────────────
    if ($script:Params.EnableExchange -eq 'True') {
        $exIsoPath = "F:\Installers\$($script:Params.ExchangeIsoFileName)"
        try {
            _Download-Iso -FileName $script:Params.ExchangeIsoFileName -DestPath $exIsoPath -Label "Exchange SE ISO"
        }
        catch {
            Write-Log "ERROR downloading Exchange SE ISO: $_" -Level Error
            throw
        }
    }

    # ── 4. Verify files exist and pass size check ───────────────────────
    $isoFiles = @(
        @{ Path = $sqlIsoPath;  Label = "SQL Server ISO" },
        @{ Path = $spIsoPath;   Label = "SharePoint SE ISO" }
    )

    if ($script:Params.EnableExchange -eq 'True') {
        $isoFiles += @{ Path = $exIsoPath; Label = "Exchange SE ISO" }
    }

    foreach ($iso in $isoFiles) {
        if (-not (Test-Path $iso.Path)) {
            $msg = "$($iso.Label) not found at $($iso.Path) after download"
            Write-Log "ERROR: $msg" -Level Error
            throw $msg
        }

        $fileSize = (Get-Item $iso.Path).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 1)

        if ($fileSize -le $minimumSizeBytes) {
            $msg = "$($iso.Label) is only ${fileSizeMB} MB — expected > $([math]::Round($minimumSizeBytes / 1MB)) MB"
            Write-Log "ERROR: $msg" -Level Error
            throw $msg
        }

        Write-Log "$($iso.Label) verified: ${fileSizeMB} MB at $($iso.Path)"
    }

    Write-Log "Phase 02 - DownloadISOs: Completed successfully"
    return "success"
}
