#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 12 – Download and silently install Visual Studio 2026 Enterprise.
.DESCRIPTION
    Downloads the VS bootstrapper from blob storage (preferred) or the
    public Microsoft CDN, then performs a quiet installation with workloads
    for Office/SharePoint, .NET desktop, and ASP.NET web development.

    Exit codes:
        0    – success
        3010 – success, reboot required
        5007 – product already installed (treated as success)

    Installation typically takes 30–60 minutes.  If the bootstrapper URL is
    unreachable, the script creates a desktop shortcut with manual-install
    instructions so provisioning can continue.

    Requires Common.ps1 to be dot-sourced first for Write-Log and
    Invoke-WithRetry.  Parameters are read from $script:Params.
#>

function Invoke-Phase12-InstallVS2026 {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 12: Install Visual Studio 2026 – START ====="

    $installersDir    = "F:\Installers"
    $bootstrapperPath = Join-Path $installersDir "vs_enterprise.exe"

    # ------------------------------------------------------------------
    # 0. Skip if Visual Studio is already installed
    #    Check for devenv.exe in the standard install locations.
    # ------------------------------------------------------------------
    $vsInstallPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2026\Enterprise\Common7\IDE\devenv.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2026\Enterprise\Common7\IDE\devenv.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2026\Preview\Common7\IDE\devenv.exe"
    )

    foreach ($vsPath in $vsInstallPaths) {
        if (Test-Path $vsPath) {
            Write-Log "Visual Studio already installed at '$vsPath' – skipping"
            return "success"
        }
    }

    # Also check via vswhere if available
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $existing = & $vswhere -latest -property installationPath 2>$null
        if ($existing -and (Test-Path (Join-Path $existing "Common7\IDE\devenv.exe"))) {
            Write-Log "Visual Studio already installed at '$existing' (detected via vswhere) – skipping"
            return "success"
        }
    }

    # ------------------------------------------------------------------
    # 1. Ensure installers directory exists
    # ------------------------------------------------------------------
    if (-not (Test-Path $installersDir)) {
        New-Item -ItemType Directory -Path $installersDir -Force | Out-Null
        Write-Log "Created installers directory: $installersDir"
    }

    # ------------------------------------------------------------------
    # 2. Download the VS bootstrapper
    #    Prefer blob storage (may contain a pre-cached offline layout);
    #    fall back to the public CDN.
    # ------------------------------------------------------------------
    $downloaded = $false

    # --- 2a. Try blob storage ---
    if ($script:Params.IsoBlobUrl) {
        $blobBootstrapperUrl = "$($script:Params.IsoBlobUrl)/vs_enterprise.exe"

        Write-Log "Attempting to download VS bootstrapper from blob: $blobBootstrapperUrl"
        try {
            $azcopyExe = Get-ChildItem -Path "$env:TEMP\azcopy" -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $azcopyExe) {
                $azcopyExe = Get-ChildItem -Path 'C:\Installs' -Recurse -Filter 'azcopy.exe' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if ($azcopyExe) {
                $env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
                $out = & $azcopyExe.FullName copy $blobBootstrapperUrl $bootstrapperPath --log-level=WARNING 2>&1 | Out-String
                Write-Log $out
                if ($LASTEXITCODE -eq 0 -and (Test-Path $bootstrapperPath)) {
                    $downloaded = $true
                    Write-Log "VS bootstrapper downloaded from blob storage"
                } else {
                    Write-Log "VS bootstrapper download from blob failed — will try CDN" -Level WARN
                }
            } else {
                Write-Log "azcopy not found — skipping blob download, will try CDN" -Level WARN
            }
        }
        catch {
            Write-Log "Blob download failed: $_ — will try CDN" -Level WARN
            if (Test-Path $bootstrapperPath) {
                Remove-Item $bootstrapperPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # --- 2b. Try Microsoft CDN ---
    if (-not $downloaded) {
        # Channel 18 = VS 2026 (hypothetical). Attempt release first, then preview.
        $cdnUrls = @(
            "https://aka.ms/vs/18/release/vs_enterprise.exe",
            "https://aka.ms/vs/18/pre/vs_enterprise.exe"
        )

        foreach ($cdnUrl in $cdnUrls) {
            Write-Log "Attempting CDN download: $cdnUrl"
            try {
                $previousPref = $ProgressPreference
                $ProgressPreference = 'SilentlyContinue'
                try {
                    Invoke-WebRequest -Uri $cdnUrl -OutFile $bootstrapperPath `
                        -UseBasicParsing -ErrorAction Stop
                }
                finally {
                    $ProgressPreference = $previousPref
                }

                if (Test-Path $bootstrapperPath) {
                    $downloaded = $true
                    Write-Log "VS bootstrapper downloaded from CDN: $cdnUrl"
                    break
                }
            }
            catch {
                Write-Log "CDN download failed for $cdnUrl`: $_" -Level WARN
                if (Test-Path $bootstrapperPath) {
                    Remove-Item $bootstrapperPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # --- 2c. Bootstrapper unavailable – create manual-install shortcut ---
    if (-not $downloaded) {
        Write-Log "Could not download VS bootstrapper from any source" -Level WARN

        $desktop = "C:\Users\Public\Desktop"
        $shortcutPath = Join-Path $desktop "Install Visual Studio 2026.url"

        try {
            @(
                "[InternetShortcut]"
                "URL=https://visualstudio.microsoft.com/downloads/"
            ) | Set-Content -Path $shortcutPath -Encoding ASCII -Force

            Write-Log "Created desktop shortcut for manual VS download at '$shortcutPath'"
        }
        catch {
            Write-Log "Failed to create manual-install shortcut: $_" -Level WARN
        }

        Write-Log "Continuing provisioning without VS installation" -Level WARN
        return "success"
    }

    # ------------------------------------------------------------------
    # 3. Run the silent installation
    # ------------------------------------------------------------------
    $workloads = @(
        "--add", "Microsoft.VisualStudio.Workload.Office",            # Office/SharePoint development
        "--add", "Microsoft.VisualStudio.Workload.ManagedDesktop",    # .NET desktop development
        "--add", "Microsoft.VisualStudio.Workload.NetWeb",            # ASP.NET and web development
        "--add", "Microsoft.Component.NetFX.Native",                  # .NET Native
        "--add", "Microsoft.VisualStudio.Component.SharePoint.Tools"  # SharePoint project templates
    )

    $installArgs = @(
        "--quiet",
        "--norestart",
        "--wait",
        "--includeRecommended"
    ) + $workloads

    Write-Log "Starting VS 2026 installation (this may take 30-60 minutes)..."
    Write-Log "Workloads: Office, ManagedDesktop, NetWeb, NetFX.Native, SharePoint.Tools" -Level DEBUG

    try {
        $process = Start-Process -FilePath $bootstrapperPath `
            -ArgumentList $installArgs `
            -Wait -PassThru -ErrorAction Stop

        $exitCode = $process.ExitCode
        Write-Log "VS installer exited with code $exitCode"
    }
    catch {
        Write-Log "Failed to launch VS installer: $_" -Level ERROR
        throw
    }

    # ------------------------------------------------------------------
    # 4. Evaluate exit code
    # ------------------------------------------------------------------
    switch ($exitCode) {
        0 {
            Write-Log "Visual Studio 2026 installed successfully"
            Write-Log "===== Phase 12: Install Visual Studio 2026 – COMPLETE ====="
            return "success"
        }
        3010 {
            Write-Log "Visual Studio 2026 installed – reboot required (exit code 3010)"
            Write-Log "===== Phase 12: Install Visual Studio 2026 – COMPLETE (reboot) ====="
            return "reboot"
        }
        5007 {
            # Already installed or partially installed
            Write-Log "Visual Studio 2026 already installed (exit code 5007)" -Level WARN
            Write-Log "===== Phase 12: Install Visual Studio 2026 – COMPLETE ====="
            return "success"
        }
        default {
            # Non-zero, non-reboot exit codes indicate failure
            $msg = "VS installer returned unexpected exit code $exitCode"
            Write-Log $msg -Level ERROR
            throw $msg
        }
    }
}
