function Invoke-Phase01-InitDisks {
    <#
    .SYNOPSIS
        Initializes the raw data disk (LUN 0) attached by Bicep and creates required directories.
    .DESCRIPTION
        Formats the raw disk as GPT/NTFS with 64K allocation units (SQL Server requirement),
        assigns drive letter D:, and creates standard directory layout.
    #>

    Write-Log "Phase 01 - InitDisks: Starting disk initialization"

    # ── 1. Locate the raw disk ──────────────────────────────────────────────
    try {
        $rawDisks = Get-Disk | Where-Object PartitionStyle -eq 'RAW'

        if (-not $rawDisks) {
            # Check if D: already exists (idempotent re-run)
            if (Test-Path "F:\") {
                Write-Log "Drive F: already exists — disk was previously initialized"
            }
            else {
                throw "No RAW disks found and F: drive does not exist. Ensure the data disk is attached."
            }
        }
        else {
            $dataDisk = $rawDisks | Select-Object -First 1
            Write-Log "Found RAW disk: Disk $($dataDisk.Number), Size $([math]::Round($dataDisk.Size / 1GB, 1)) GB"

            # ── 2. Initialize as GPT ────────────────────────────────────────
            Write-Log "Initializing disk $($dataDisk.Number) as GPT"
            Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT -ErrorAction Stop

            # ── 3. Create partition using full disk ──────────────────────────
            Write-Log "Creating partition on disk $($dataDisk.Number)"
            $partition = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -DriveLetter F -ErrorAction Stop

            # ── 4. Format as NTFS with 64K allocation unit size ──────────────
            Write-Log "Formatting partition as NTFS with 64KB allocation unit size"
            Format-Volume -Partition $partition `
                          -FileSystem NTFS `
                          -AllocationUnitSize 65536 `
                          -NewFileSystemLabel "Data" `
                          -Confirm:$false `
                          -ErrorAction Stop | Out-Null

            Write-Log "Disk $($dataDisk.Number) initialized and formatted as F:"
        }
    }
    catch {
        Write-Log "ERROR initializing disk: $_" -Level Error
        throw
    }

    # ── 5. Create required directories ──────────────────────────────────────
    $directories = @(
        "F:\SQLData",
        "F:\SQLLogs",
        "F:\SQLTempDB",
        "F:\SPSearchIndex",
        "F:\Installers",
        "C:\SPSESetup"
    )

    foreach ($dir in $directories) {
        try {
            if (Test-Path $dir) {
                Write-Log "Directory already exists: $dir"
            }
            else {
                New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Log "Created directory: $dir"
            }
        }
        catch {
            Write-Log "ERROR creating directory ${dir}: $_" -Level Error
            throw
        }
    }

    Write-Log "Phase 01 - InitDisks: Completed successfully"
    return "success"
}
