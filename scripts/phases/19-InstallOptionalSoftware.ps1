#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 19 – Install optional developer software via winget.
.DESCRIPTION
    Reads scripts/config/winget-packages.json and installs each listed
    package using winget.  Packages that are already installed are
    skipped automatically by winget.

    This phase is best-effort: individual package failures are logged as
    warnings but do not abort the phase.  The phase always returns
    "success" so provisioning is never blocked by an optional tool.

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase19-InstallOptionalSoftware {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 19: Install Optional Software (winget) – START ====="

    # ------------------------------------------------------------------
    # 0. Locate / bootstrap winget
    #    On Windows Server 2025 the App Installer package that provides
    #    winget may not be pre-installed.  Attempt to find it, then fall
    #    back to installing it from GitHub.
    # ------------------------------------------------------------------
    $wingetExe = $null

    # Check common locations
    $candidates = @(
        "$env:LocalAppData\Microsoft\WindowsApps\winget.exe",
        "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe",
        "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe"
    )

    foreach ($pattern in $candidates) {
        $found = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $wingetExe = $found.FullName
            break
        }
    }

    # Also try PATH
    if (-not $wingetExe) {
        $wingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
    }

    # Attempt to install winget if not found
    if (-not $wingetExe) {
        Write-Log "winget not found — attempting to install via Add-AppxPackage..."
        try {
            # Download the latest msixbundle from GitHub
            $releasesUrl = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
            $previousPref = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                $release = Invoke-RestMethod -Uri $releasesUrl -UseBasicParsing -ErrorAction Stop
                $msixUrl = ($release.assets | Where-Object { $_.name -match '\.msixbundle$' } |
                    Select-Object -First 1).browser_download_url

                # winget requires the VCLibs dependency and Microsoft.UI.Xaml
                $vcLibsUrl = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
                $xamlUrl   = ($release.assets | Where-Object { $_.name -match 'Microsoft\.UI\.Xaml.*\.appx$' } |
                    Select-Object -First 1).browser_download_url

                $tempDir = Join-Path $env:TEMP "winget-install"
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                # Download dependencies
                $vcLibsPath = Join-Path $tempDir "VCLibs.appx"
                Invoke-WebRequest -Uri $vcLibsUrl -OutFile $vcLibsPath -UseBasicParsing -ErrorAction Stop

                if ($xamlUrl) {
                    $xamlPath = Join-Path $tempDir "UIXaml.appx"
                    Invoke-WebRequest -Uri $xamlUrl -OutFile $xamlPath -UseBasicParsing -ErrorAction Stop
                }

                $msixPath = Join-Path $tempDir "winget.msixbundle"
                Invoke-WebRequest -Uri $msixUrl -OutFile $msixPath -UseBasicParsing -ErrorAction Stop

                # Install
                Add-AppxPackage -Path $vcLibsPath -ErrorAction SilentlyContinue
                if ($xamlPath -and (Test-Path $xamlPath)) {
                    Add-AppxPackage -Path $xamlPath -ErrorAction SilentlyContinue
                }
                Add-AppxPackage -Path $msixPath -ErrorAction Stop

                # Re-resolve
                $wingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
                if (-not $wingetExe) {
                    $wingetExe = Get-Item "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" -ErrorAction SilentlyContinue |
                        Select-Object -First 1 | ForEach-Object { $_.FullName }
                }

                if ($wingetExe) {
                    Write-Log "winget installed successfully: $wingetExe"
                }
                else {
                    Write-Log "winget install appeared to succeed but executable not found" -Level WARN
                }
            }
            finally {
                $ProgressPreference = $previousPref
            }
        }
        catch {
            Write-Log "Failed to install winget: $_" -Level WARN
        }
    }

    if (-not $wingetExe) {
        Write-Log "winget is not available — skipping optional software installation" -Level WARN
        Write-Log "===== Phase 19: Install Optional Software (winget) – COMPLETE (skipped) ====="
        return "success"
    }

    Write-Log "Using winget: $wingetExe"

    # ------------------------------------------------------------------
    # 1. Accept source agreements non-interactively
    # ------------------------------------------------------------------
    try {
        & $wingetExe list --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    }
    catch {
        Write-Log "winget source agreement acceptance warning: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 2. Load package list from config
    # ------------------------------------------------------------------
    $configPath = Join-Path $PSScriptRoot "..\config\winget-packages.json"
    if (-not (Test-Path $configPath)) {
        # Also check the setup root location
        $configPath = "C:\SPSESetup\scripts\config\winget-packages.json"
    }

    if (-not (Test-Path $configPath)) {
        Write-Log "winget-packages.json not found — skipping optional software" -Level WARN
        Write-Log "===== Phase 19: Install Optional Software (winget) – COMPLETE (no config) ====="
        return "success"
    }

    try {
        $config = Get-Content -Path $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to parse winget-packages.json: $_" -Level WARN
        return "success"
    }

    $packages = $config.packages
    if (-not $packages -or $packages.Count -eq 0) {
        Write-Log "No packages defined in winget-packages.json — nothing to install"
        return "success"
    }

    Write-Log "Found $($packages.Count) packages to install"

    # ------------------------------------------------------------------
    # 3. Install each package
    # ------------------------------------------------------------------
    $installed = 0
    $skipped   = 0
    $failed    = 0

    foreach ($pkg in $packages) {
        $id = $pkg.PackageIdentifier
        if (-not $id) {
            Write-Log "Skipping package entry with no PackageIdentifier" -Level WARN
            $skipped++
            continue
        }

        Write-Log "Installing '$id'..."
        try {
            $wingetArgs = @(
                "install",
                "--id", $id,
                "--exact",
                "--silent",
                "--accept-package-agreements",
                "--accept-source-agreements",
                "--disable-interactivity"
            )

            # Pin to specific version if requested
            if ($pkg.Version) {
                $wingetArgs += @("--version", $pkg.Version)
            }

            $output = & $wingetExe @wingetArgs 2>&1 | Out-String

            if ($LASTEXITCODE -eq 0) {
                Write-Log "  '$id' installed successfully"
                $installed++
            }
            elseif ($output -match 'already installed' -or $LASTEXITCODE -eq -1978335135) {
                Write-Log "  '$id' is already installed — skipped" -Level DEBUG
                $skipped++
            }
            else {
                Write-Log "  '$id' install returned exit code $LASTEXITCODE" -Level WARN
                Write-Log "  Output: $($output.Trim())" -Level DEBUG
                $failed++
            }
        }
        catch {
            Write-Log "  '$id' install failed: $_" -Level WARN
            $failed++
        }
    }

    Write-Log "Optional software summary: $installed installed, $skipped skipped, $failed failed"

    Write-Log "===== Phase 19: Install Optional Software (winget) – COMPLETE ====="
    return "success"
}
