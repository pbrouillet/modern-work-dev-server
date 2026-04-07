#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 14 – Install Windows features and prerequisites for Exchange Server SE.
.DESCRIPTION
    Installs the Windows Server roles/features required by the Exchange Server
    SE Mailbox role, plus UCMA 4.0 Runtime and Visual C++ redistributables.

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase14-InstallExchangePrereqs {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 14: Install Exchange Prerequisites – START ====="

    # ------------------------------------------------------------------
    # 1. Install required Windows features
    # ------------------------------------------------------------------
    $requiredFeatures = @(
        'NET-Framework-45-Features',
        'Server-Media-Foundation',
        'RPC-over-HTTP-proxy',
        'RSAT-Clustering',
        'RSAT-Clustering-CmdInterface',
        'RSAT-Clustering-Mgmt',
        'RSAT-Clustering-PowerShell',
        'WAS-Process-Model',
        'Web-Asp-Net45',
        'Web-Basic-Auth',
        'Web-Client-Auth',
        'Web-Digest-Auth',
        'Web-Dir-Browsing',
        'Web-Dyn-Compression',
        'Web-Http-Errors',
        'Web-Http-Logging',
        'Web-Http-Redirect',
        'Web-Http-Tracing',
        'Web-ISAPI-Ext',
        'Web-ISAPI-Filter',
        'Web-Lgcy-Mgmt-Console',
        'Web-Metabase',
        'Web-Mgmt-Console',
        'Web-Mgmt-Service',
        'Web-Net-Ext45',
        'Web-Request-Monitor',
        'Web-Server',
        'Web-Stat-Compression',
        'Web-Static-Content',
        'Web-Windows-Auth',
        'Web-WMI',
        'Windows-Identity-Foundation',
        'RSAT-ADDS'
    )

    # Check if all features are already installed
    $missing = @()
    foreach ($feature in $requiredFeatures) {
        $f = Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue
        if ($f -and $f.InstallState -ne 'Installed') {
            $missing += $feature
        }
    }

    if ($missing.Count -eq 0) {
        Write-Log "All required Windows features are already installed"
    }
    else {
        Write-Log "Installing $($missing.Count) Windows features: $($missing -join ', ')"
        try {
            $result = Install-WindowsFeature -Name $missing -ErrorAction Stop
            if ($result.RestartNeeded -eq 'Yes') {
                Write-Log "Windows features installed — reboot required"
                Write-Log "===== Phase 14: Install Exchange Prerequisites – REBOOT REQUIRED ====="
                return "reboot"
            }
            Write-Log "Windows features installed successfully (no reboot needed)"
        }
        catch {
            Write-Log "ERROR installing Windows features: $_" -Level Error
            throw
        }
    }

    # ------------------------------------------------------------------
    # 2. Install Visual C++ 2013 Redistributable (x64) if not present
    # ------------------------------------------------------------------
    $vc2013Installed = Get-ItemProperty "HKLM:\SOFTWARE\Classes\Installer\Dependencies\{050d4fc8-5d48-4b8f-8972-47c82c46020f}" -ErrorAction SilentlyContinue
    if (-not $vc2013Installed) {
        $vc2013Installed = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\12.0\VC\Runtimes\x64" -ErrorAction SilentlyContinue
    }

    if ($vc2013Installed) {
        Write-Log "Visual C++ 2013 Redistributable (x64) already installed — skipping"
    }
    else {
        Write-Log "Downloading Visual C++ 2013 Redistributable (x64)..."
        $vcRedistUrl  = "https://aka.ms/highdpimfc2013x64enu"
        $vcRedistPath = Join-Path $env:TEMP "vcredist_x64_2013.exe"
        try {
            Invoke-WebRequest -Uri $vcRedistUrl -OutFile $vcRedistPath -UseBasicParsing -ErrorAction Stop
            Write-Log "Installing Visual C++ 2013 Redistributable..."
            $proc = Start-Process -FilePath $vcRedistPath -ArgumentList "/install /quiet /norestart" -Wait -PassThru
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                throw "vcredist_x64_2013 exited with code $($proc.ExitCode)"
            }
            Write-Log "Visual C++ 2013 Redistributable installed (exit code: $($proc.ExitCode))"
        }
        catch {
            Write-Log "ERROR installing VC++ 2013 Redistributable: $_" -Level Error
            throw
        }
    }

    # ------------------------------------------------------------------
    # 3. Install UCMA 4.0 Runtime if not present
    # ------------------------------------------------------------------
    $ucmaInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\UCMA\{FE3B3F19-5F92-4B3B-8008-6F0C6CA619C5}" -ErrorAction SilentlyContinue
    if (-not $ucmaInstalled) {
        $ucmaInstalled = Get-WmiObject -Class Win32_Product -Filter "Name LIKE '%Unified Communications Managed API 4.0%'" -ErrorAction SilentlyContinue
    }

    if ($ucmaInstalled) {
        Write-Log "UCMA 4.0 Runtime already installed — skipping"
    }
    else {
        Write-Log "Downloading UCMA 4.0 Runtime..."
        $ucmaUrl  = "https://download.microsoft.com/download/2/C/4/2C47A5C1-A1F3-4843-B9FE-84C0032C61EC/UcmaRuntimeSetup.exe"
        $ucmaPath = Join-Path $env:TEMP "UcmaRuntimeSetup.exe"
        try {
            Invoke-WebRequest -Uri $ucmaUrl -OutFile $ucmaPath -UseBasicParsing -ErrorAction Stop
            Write-Log "Installing UCMA 4.0 Runtime..."
            $proc = Start-Process -FilePath $ucmaPath -ArgumentList "/quiet /norestart" -Wait -PassThru
            if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                throw "UcmaRuntimeSetup exited with code $($proc.ExitCode)"
            }
            Write-Log "UCMA 4.0 Runtime installed (exit code: $($proc.ExitCode))"
        }
        catch {
            Write-Log "ERROR installing UCMA 4.0 Runtime: $_" -Level Error
            throw
        }
    }

    Write-Log "===== Phase 14: Install Exchange Prerequisites – COMPLETED ====="
    return "reboot"
}
