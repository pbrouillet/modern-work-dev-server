#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 13 – Final developer-experience configuration and cleanup.
.DESCRIPTION
    Applies quality-of-life settings for the SPSE dev box:
      * Disables IE Enhanced Security Configuration
      * Creates desktop shortcuts for Central Admin, Portal, VS, SSMS
      * Adds the portal host to the Local Intranet zone
      * Sets PowerShell execution policy to RemoteSigned
      * Disables Windows Firewall for the Domain profile (dev convenience)
      * Configures Windows Explorer to show file extensions
      * Writes a human-readable setup-summary.txt

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase13-FinalConfig {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 13: Final Configuration – START ====="

    $domainFqdn = $script:Params.DomainName
    $portalHost  = "portal.$domainFqdn"

    # ------------------------------------------------------------------
    # 1. Disable IE Enhanced Security Configuration
    #    ESC blocks virtually every web page and is a constant annoyance
    #    on development servers.
    # ------------------------------------------------------------------
    Write-Log "Disabling IE Enhanced Security Configuration..."

    $escAdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
    $escUserKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"

    try {
        if (Test-Path $escAdminKey) {
            $current = (Get-ItemProperty -Path $escAdminKey -Name "IsInstalled" -ErrorAction SilentlyContinue).IsInstalled
            if ($current -ne 0) {
                Set-ItemProperty -Path $escAdminKey -Name "IsInstalled" -Value 0 -ErrorAction Stop
                Write-Log "IE ESC disabled for Administrators"
            }
            else {
                Write-Log "IE ESC already disabled for Administrators" -Level DEBUG
            }
        }

        if (Test-Path $escUserKey) {
            $current = (Get-ItemProperty -Path $escUserKey -Name "IsInstalled" -ErrorAction SilentlyContinue).IsInstalled
            if ($current -ne 0) {
                Set-ItemProperty -Path $escUserKey -Name "IsInstalled" -Value 0 -ErrorAction Stop
                Write-Log "IE ESC disabled for Users"
            }
            else {
                Write-Log "IE ESC already disabled for Users" -Level DEBUG
            }
        }
    }
    catch {
        Write-Log "Failed to disable IE ESC: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 2. Create desktop shortcuts
    # ------------------------------------------------------------------
    Write-Log "Creating desktop shortcuts..."

    $desktop = "C:\Users\Public\Desktop"
    if (-not (Test-Path $desktop)) {
        New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    }

    # Helper – create a .lnk shortcut via WScript.Shell
    function New-DesktopShortcut {
        param(
            [string]$Name,
            [string]$TargetPath,
            [string]$Arguments = "",
            [string]$IconLocation = "",
            [string]$Description = ""
        )

        $lnkPath = Join-Path $desktop "$Name.lnk"
        if (Test-Path $lnkPath) {
            Write-Log "Shortcut '$Name' already exists – skipping" -Level DEBUG
            return
        }

        try {
            $ws = New-Object -ComObject WScript.Shell
            $sc = $ws.CreateShortcut($lnkPath)
            $sc.TargetPath = $TargetPath
            if ($Arguments)    { $sc.Arguments    = $Arguments }
            if ($IconLocation) { $sc.IconLocation  = $IconLocation }
            if ($Description)  { $sc.Description   = $Description }
            $sc.Save()
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
            Write-Log "Created shortcut: $Name"
        }
        catch {
            Write-Log "Failed to create shortcut '$Name': $_" -Level WARN
        }
    }

    # --- URL shortcuts (simpler .url files) ---
    function New-UrlShortcut {
        param(
            [string]$Name,
            [string]$Url
        )

        $urlPath = Join-Path $desktop "$Name.url"
        if (Test-Path $urlPath) {
            Write-Log "URL shortcut '$Name' already exists – skipping" -Level DEBUG
            return
        }

        try {
            @(
                "[InternetShortcut]"
                "URL=$Url"
            ) | Set-Content -Path $urlPath -Encoding ASCII -Force
            Write-Log "Created URL shortcut: $Name"
        }
        catch {
            Write-Log "Failed to create URL shortcut '$Name': $_" -Level WARN
        }
    }

    # Central Administration
    New-UrlShortcut -Name "SP Central Administration" -Url "http://localhost:9999"

    # SharePoint Portal
    New-UrlShortcut -Name "SharePoint Portal" -Url "http://$portalHost"

    # Visual Studio 2026 – find devenv.exe
    $devenvCandidates = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2026\Enterprise\Common7\IDE\devenv.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2026\Enterprise\Common7\IDE\devenv.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2026\Preview\Common7\IDE\devenv.exe"
    )
    $devenvPath = $devenvCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($devenvPath) {
        New-DesktopShortcut -Name "Visual Studio 2026" `
            -TargetPath $devenvPath `
            -Description "Visual Studio 2026 Enterprise"
    }
    else {
        Write-Log "devenv.exe not found – skipping Visual Studio shortcut" -Level WARN
    }

    # SQL Server Management Studio
    $ssmsCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server Management Studio 19\Common7\IDE\ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server\160\Tools\Binn\SSMS\ssms.exe",
        "${env:ProgramFiles(x86)}\Microsoft SQL Server\150\Tools\Binn\SSMS\ssms.exe"
    )
    $ssmsPath = $ssmsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($ssmsPath) {
        New-DesktopShortcut -Name "SQL Server Management Studio" `
            -TargetPath $ssmsPath `
            -Description "SQL Server Management Studio"
    }
    else {
        Write-Log "SSMS not found – skipping SSMS shortcut" -Level WARN
    }

    # ------------------------------------------------------------------
    # 3. Add portal to Local Intranet zone (zone 1)
    #    This avoids credential prompts in IE/Edge for the portal URL.
    # ------------------------------------------------------------------
    Write-Log "Adding '$portalHost' to Local Intranet zone..."

    $zonesRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
    $portalZonePath = Join-Path $zonesRoot $portalHost

    try {
        if (-not (Test-Path $portalZonePath)) {
            New-Item -Path $portalZonePath -Force | Out-Null
        }
        # Zone 1 = Local Intranet; apply to http and https
        Set-ItemProperty -Path $portalZonePath -Name "http"  -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $portalZonePath -Name "https" -Value 1 -Type DWord -Force
        Write-Log "Portal added to Local Intranet zone"
    }
    catch {
        Write-Log "Failed to configure intranet zone for portal: $_" -Level WARN
    }

    # Also add localhost for Central Admin
    $localhostZonePath = Join-Path $zonesRoot "localhost"
    try {
        if (-not (Test-Path $localhostZonePath)) {
            New-Item -Path $localhostZonePath -Force | Out-Null
        }
        Set-ItemProperty -Path $localhostZonePath -Name "http"  -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $localhostZonePath -Name "https" -Value 1 -Type DWord -Force
        Write-Log "localhost added to Local Intranet zone (for Central Admin)"
    }
    catch {
        Write-Log "Failed to configure intranet zone for localhost: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 4. Set PowerShell execution policy
    # ------------------------------------------------------------------
    try {
        $currentPolicy = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue
        if ($currentPolicy -ne "RemoteSigned") {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction Stop
            Write-Log "Execution policy set to RemoteSigned (was: $currentPolicy)"
        }
        else {
            Write-Log "Execution policy already RemoteSigned" -Level DEBUG
        }
    }
    catch {
        Write-Log "Failed to set execution policy: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 5. Disable Windows Firewall for Domain profile
    #    On a dev box this removes friction; production should never do this.
    # ------------------------------------------------------------------
    try {
        $domainProfile = Get-NetFirewallProfile -Profile Domain -ErrorAction SilentlyContinue
        if ($domainProfile -and $domainProfile.Enabled) {
            Set-NetFirewallProfile -Profile Domain -Enabled False -ErrorAction Stop
            Write-Log "Windows Firewall disabled for Domain profile (dev convenience)"
        }
        else {
            Write-Log "Domain firewall profile already disabled" -Level DEBUG
        }
    }
    catch {
        Write-Log "Failed to disable domain firewall: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 6. Configure Windows Explorer – show file extensions
    # ------------------------------------------------------------------
    $explorerAdvancedKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    try {
        if (Test-Path $explorerAdvancedKey) {
            $hideExt = (Get-ItemProperty -Path $explorerAdvancedKey -Name "HideFileExt" -ErrorAction SilentlyContinue).HideFileExt
            if ($hideExt -ne 0) {
                Set-ItemProperty -Path $explorerAdvancedKey -Name "HideFileExt" -Value 0 -ErrorAction Stop
                Write-Log "Windows Explorer: file extensions now visible"
            }
            else {
                Write-Log "Windows Explorer: file extensions already visible" -Level DEBUG
            }

            # Also show hidden files (useful for dev)
            Set-ItemProperty -Path $explorerAdvancedKey -Name "Hidden" -Value 1 -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "Failed to configure Explorer settings: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 7. Write setup completion summary
    # ------------------------------------------------------------------
    Write-Log "Writing setup summary..."

    $summaryPath = "C:\SPSESetup\setup-summary.txt"
    try {
        $state = $null
        try { $state = Get-SetupState -ErrorAction SilentlyContinue } catch {}

        $startTime    = if ($state -and $state.StartTime)    { $state.StartTime }    else { "Unknown" }
        $endTime      = Get-Date -Format "o"
        $durationText = "Unknown"

        if ($state -and $state.StartTime) {
            try {
                $start    = [datetime]::Parse($state.StartTime)
                $duration = (Get-Date) - $start
                $durationText = "{0}h {1}m {2}s" -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
            }
            catch { }
        }

        $completedPhases = if ($state -and $state.CompletedPhases) {
            ($state.CompletedPhases | Sort-Object) -join ", "
        }
        else { "Unknown" }

        $summaryLines = @(
            "================================================================="
            "  SPSE Dev Box Setup Summary"
            "================================================================="
            ""
            "Start Time  : $startTime"
            "End Time    : $endTime"
            "Duration    : $durationText"
            "Phases Done : $completedPhases"
            ""
            "--- URLs ---"
            "Central Administration : http://localhost:9999"
            "SharePoint Portal     : http://$portalHost"
            ""
            "--- Service Accounts ---"
            "Farm Account          : $($script:Params.DomainNetBIOS)\sp_farm"
            "Services Account      : $($script:Params.DomainNetBIOS)\sp_services"
            "Web App Pool Account  : $($script:Params.DomainNetBIOS)\sp_webapp"
            "Search Account        : $($script:Params.DomainNetBIOS)\sp_search"
            "User Profile Account  : $($script:Params.DomainNetBIOS)\sp_content"
            "App Management Account: $($script:Params.DomainNetBIOS)\sp_apps"
            "Cache Account         : $($script:Params.DomainNetBIOS)\sp_cache"
            "Super User Account    : $($script:Params.DomainNetBIOS)\sp_supuser"
            "Super Reader Account  : $($script:Params.DomainNetBIOS)\sp_supreader"
            "Setup Account         : $($script:Params.DomainNetBIOS)\sp_setup"
            ""
            "--- SQL Server ---"
            "Instance              : $env:COMPUTERNAME (default instance)"
            "Config DB             : SP_Config"
            "Admin Content DB      : SP_Admin_Content"
            "Portal Content DB     : SP_Content_Portal"
            "Search Admin DB       : SP_Search_AdminDB"
            "Managed Metadata DB   : SP_ManagedMetadata"
            "User Profile DB       : SP_UserProfile"
            "App Management DB     : SP_AppManagement"
            "Subscription DB       : SP_SubscriptionSettings"
            ""
            "--- Notes ---"
            "- IE Enhanced Security Configuration is DISABLED."
            "- Domain firewall profile is DISABLED (dev convenience)."
            "- PowerShell execution policy is RemoteSigned."
            "- Developer Dashboard is enabled in SharePoint."
            "- Setup logs: C:\SPSESetup\setup.log"
            ""
            "================================================================="
        )

        $summaryDir = Split-Path $summaryPath -Parent
        if (-not (Test-Path $summaryDir)) {
            New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
        }

        $summaryLines | Set-Content -Path $summaryPath -Encoding UTF8 -Force
        Write-Log "Setup summary written to $summaryPath"
    }
    catch {
        Write-Log "Failed to write setup summary: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 8. Clean up temporary files (preserve logs and state)
    # ------------------------------------------------------------------
    Write-Log "Cleaning up temporary files..."

    $tempPatterns = @(
        "C:\SPSESetup\*.tmp",
        "C:\SPSESetup\*.partial"
    )

    foreach ($pattern in $tempPatterns) {
        $tempFiles = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        foreach ($f in $tempFiles) {
            try {
                Remove-Item -Path $f.FullName -Force -ErrorAction Stop
                Write-Log "Removed temp file: $($f.Name)" -Level DEBUG
            }
            catch {
                Write-Log "Could not remove temp file '$($f.Name)': $_" -Level WARN
            }
        }
    }

    # Intentionally NOT deleting ISOs or installers – the user may need them.
    Write-Log "ISO and installer files preserved in D:\Installers (delete manually if not needed)"

    Write-Log "===== Phase 13: Final Configuration – COMPLETE ====="
    return "success"
}
