#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 11 – Create the SharePoint web application and root site collection.
.DESCRIPTION
    Provisions a web application on port 80, creates a root site collection
    using the modern Team Site (STS#3) template, warms up the site, and
    enables the developer dashboard for debugging convenience.

    Requires Common.ps1 to be dot-sourced first for Write-Log and
    Invoke-WithRetry.  Parameters are read from $script:Params.
#>

function Invoke-Phase11-CreateSPWebApp {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 11: Create SharePoint Web Application – START ====="

    # ------------------------------------------------------------------
    # 0. Load SharePoint snap-in
    # ------------------------------------------------------------------
    if (-not (Get-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
    }

    $domainPrefix = $script:Params.DomainNetBIOS
    $domainFqdn   = $script:Params.DomainName          # e.g. contoso.com
    $portalHost    = "portal.$domainFqdn"               # portal.contoso.com
    $portalUrl     = "http://$portalHost"
    $webAppName    = "SharePoint Portal"
    $appPoolName   = "SP_Portal_AppPool"
    $contentDbName = "SP_Content_Portal"

    # ------------------------------------------------------------------
    # 1. Create Web Application (idempotent)
    # ------------------------------------------------------------------
    $existingWebApp = Get-SPWebApplication -Identity $portalUrl -ErrorAction SilentlyContinue

    if ($existingWebApp) {
        Write-Log "Web application '$webAppName' already exists at $portalUrl – skipping creation"
    }
    else {
        Write-Log "Creating web application '$webAppName' at $portalUrl ..."

        # Retrieve the managed account – it must have been created in Phase 10
        $appPoolAccount = $null
        try {
            $appPoolAccount = Get-SPManagedAccount -Identity "$domainPrefix\sp_webapp" -ErrorAction Stop
        }
        catch {
            Write-Log "Managed account '$domainPrefix\sp_webapp' not found. Ensure Phase 10 completed." -Level ERROR
            throw "Prerequisite missing: managed account '$domainPrefix\sp_webapp'"
        }

        $authProvider = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication

        Invoke-WithRetry -OperationName "New-SPWebApplication" -MaxRetries 3 -DelaySeconds 30 -ScriptBlock {
            New-SPWebApplication -Name $webAppName `
                -Port 80 `
                -HostHeader $portalHost `
                -URL $portalUrl `
                -ApplicationPool $appPoolName `
                -ApplicationPoolAccount $appPoolAccount `
                -DatabaseName $contentDbName `
                -AuthenticationProvider $authProvider `
                -ErrorAction Stop
        }

        Write-Log "Web application '$webAppName' created"
    }

    # ------------------------------------------------------------------
    # 1b. Configure Object Cache accounts (Portal Super User / Reader)
    #     Without these, the event log fills with "cache not configured"
    #     warnings and page-load performance degrades.
    # ------------------------------------------------------------------
    $webApp = Get-SPWebApplication -Identity $portalUrl -ErrorAction SilentlyContinue
    if ($webApp) {
        $superUser   = "$domainPrefix\sp_supuser"
        $superReader = "$domainPrefix\sp_supreader"

        $currentSU = $webApp.Properties["portalsuperuseraccount"]
        $currentSR = $webApp.Properties["portalsuperreaderaccount"]

        if ($currentSU -eq $superUser -and $currentSR -eq $superReader) {
            Write-Log "Object Cache accounts already configured – skipping"
        }
        else {
            Write-Log "Configuring Object Cache accounts..."

            # Set the properties
            $webApp.Properties["portalsuperuseraccount"] = $superUser
            $webApp.Properties["portalsuperreaderaccount"] = $superReader
            $webApp.Update()

            # Grant user policies on the web application (skip if already present)
            $existingSU = $webApp.Policies | Where-Object { $_.UserName -eq $superUser }
            if (-not $existingSU) {
                $policy1 = $webApp.Policies.Add($superUser, "Super User (Object Cache)")
                $policy1.PolicyRoleBindings.Add(
                    $webApp.PolicyRoles.GetSpecialRole(
                        [Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullControl))
            }

            $existingSR = $webApp.Policies | Where-Object { $_.UserName -eq $superReader }
            if (-not $existingSR) {
                $policy2 = $webApp.Policies.Add($superReader, "Super Reader (Object Cache)")
                $policy2.PolicyRoleBindings.Add(
                    $webApp.PolicyRoles.GetSpecialRole(
                        [Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullRead))
            }

            $webApp.Update()
            Write-Log "Object Cache accounts configured (SuperUser: $superUser, SuperReader: $superReader)"
        }
    }

    # ------------------------------------------------------------------
    # 2. Create root site collection (idempotent)
    #    STS#3 = modern Team Site (no Microsoft 365 group).
    #    Falls back to STS#0 (classic Team Site) on older builds.
    # ------------------------------------------------------------------
    $existingSite = Get-SPSite -Identity $portalUrl -ErrorAction SilentlyContinue

    if ($existingSite) {
        Write-Log "Root site collection already exists at $portalUrl – skipping creation"
    }
    else {
        Write-Log "Creating root site collection at $portalUrl ..."

        $ownerAlias = "$domainPrefix\sp_setup"
        $siteTemplate = "STS#3"

        try {
            New-SPSite -Url $portalUrl `
                -OwnerAlias $ownerAlias `
                -Name "Contoso Portal" `
                -Template $siteTemplate `
                -ContentDatabase $contentDbName `
                -ErrorAction Stop | Out-Null

            Write-Log "Root site collection created (template: $siteTemplate)"
        }
        catch {
            # STS#3 may not be available on all SP builds; fall back to classic
            Write-Log "Template '$siteTemplate' failed ($_), retrying with STS#0..." -Level WARN
            New-SPSite -Url $portalUrl `
                -OwnerAlias $ownerAlias `
                -Name "Contoso Portal" `
                -Template "STS#0" `
                -ContentDatabase $contentDbName `
                -ErrorAction Stop | Out-Null

            Write-Log "Root site collection created (template: STS#0, classic fallback)"
        }
    }

    # ------------------------------------------------------------------
    # 3. Configure Alternate Access Mapping
    #    Ensure the default zone maps to the portal host header.
    # ------------------------------------------------------------------
    try {
        $aam = Get-SPAlternateURL -WebApplication $portalUrl -Zone Default -ErrorAction SilentlyContinue
        if (-not $aam) {
            New-SPAlternateURL -WebApplication $portalUrl `
                -Url $portalUrl -Zone Default -ErrorAction Stop | Out-Null
            Write-Log "Alternate access mapping added for Default zone"
        }
        else {
            Write-Log "Alternate access mapping already configured for Default zone" -Level DEBUG
        }
    }
    catch {
        Write-Log "Alternate access mapping configuration warning: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 4. Warm up the site
    #    First request to a new SP site triggers heavy compilation and can
    #    take up to 2 minutes.  Fire-and-forget; failures are non-fatal.
    # ------------------------------------------------------------------
    Write-Log "Warming up site at $portalUrl (this may take a minute)..."
    try {
        $previousPref = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $portalUrl `
                -UseDefaultCredentials `
                -TimeoutSec 120 `
                -UseBasicParsing `
                -ErrorAction Stop | Out-Null
            Write-Log "Site warm-up completed"
        }
        finally {
            $ProgressPreference = $previousPref
        }
    }
    catch {
        # Warm-up failure is non-fatal; the site may still need IIS to be
        # fully initialised or the host header may not resolve yet.
        Write-Log "Site warm-up failed (non-fatal): $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 5. Enable developer dashboard
    #    Extremely useful on dev boxes – shows SQL queries, timings, etc.
    # ------------------------------------------------------------------
    try {
        $contentService = [Microsoft.SharePoint.Administration.SPWebService]::ContentService
        $dashboard = $contentService.DeveloperDashboardSettings
        $currentLevel = $dashboard.DisplayLevel

        if ($currentLevel -ne [Microsoft.SharePoint.Administration.SPDeveloperDashboardLevel]::On) {
            $dashboard.DisplayLevel = [Microsoft.SharePoint.Administration.SPDeveloperDashboardLevel]::On
            $dashboard.Update()
            Write-Log "Developer dashboard enabled (was: $currentLevel)"
        }
        else {
            Write-Log "Developer dashboard already enabled" -Level DEBUG
        }
    }
    catch {
        Write-Log "Could not configure developer dashboard: $_" -Level WARN
    }

    Write-Log "===== Phase 11: Create SharePoint Web Application – COMPLETE ====="
    return "success"
}
