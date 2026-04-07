#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 10 – Configure the SharePoint Server farm (equivalent to PSConfig).
.DESCRIPTION
    Creates the configuration and admin-content databases, initialises the farm,
    registers managed accounts, starts core service instances, and provisions
    the Search and Managed Metadata service applications.

    This phase MUST run under an account that has:
      * Local administrator rights
      * SQL Server dbcreator / securityadmin (or sysadmin) on the local instance
      * SharePoint Shell Admin access

    The scheduled task typically runs as SYSTEM, which satisfies these after
    the prerequisite install phases complete.

    Requires Common.ps1 to be dot-sourced first for Write-Log and
    Invoke-WithRetry.  Parameters are read from $script:Params.
#>

function Invoke-Phase10-ConfigureSPFarm {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 10: Configure SharePoint Farm – START ====="

    # ------------------------------------------------------------------
    # 0. Load the SharePoint snap-in
    # ------------------------------------------------------------------
    Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------
    # Helper – build domain-qualified account name
    # ------------------------------------------------------------------
    $domainPrefix = $script:Params.DomainNetBIOS

    # ------------------------------------------------------------------
    # 1. Create configuration database (idempotent)
    # ------------------------------------------------------------------
    try {
        $existingFarm = Get-SPFarm -ErrorAction SilentlyContinue
    }
    catch {
        $existingFarm = $null
    }

    if ($existingFarm) {
        Write-Log "SharePoint farm already exists (ID: $($existingFarm.Id)) – skipping database creation"
    }
    else {
        Write-Log "Creating SharePoint configuration database..."

        $farmPassphrase = ConvertTo-SecureString $script:Params.SpFarmPassphrase -AsPlainText -Force
        $farmCredential = New-Object System.Management.Automation.PSCredential(
            "$domainPrefix\sp_farm",
            (ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force)
        )

        Invoke-WithRetry -OperationName "New-SPConfigurationDatabase" -MaxRetries 3 -DelaySeconds 30 -ScriptBlock {
            New-SPConfigurationDatabase `
                -DatabaseName "SP_Config" `
                -DatabaseServer $env:COMPUTERNAME `
                -AdministrationContentDatabaseName "SP_Admin_Content" `
                -Passphrase $farmPassphrase `
                -FarmCredentials $farmCredential `
                -LocalServerRole "SingleServerFarm"
        }

        Write-Log "Configuration database created successfully"
    }

    # ------------------------------------------------------------------
    # 2. Initialise the farm
    #    Each step is individually idempotent within SharePoint.
    # ------------------------------------------------------------------
    Write-Log "Installing help collections..."
    try { Install-SPHelpCollection -All -ErrorAction Stop }
    catch { Write-Log "Install-SPHelpCollection warning: $_" -Level WARN }

    Write-Log "Initialising resource security..."
    try { Initialize-SPResourceSecurity -ErrorAction Stop }
    catch { Write-Log "Initialize-SPResourceSecurity warning: $_" -Level WARN }

    Write-Log "Installing services..."
    try { Install-SPService -ErrorAction Stop }
    catch { Write-Log "Install-SPService warning: $_" -Level WARN }

    Write-Log "Installing features..."
    try { Install-SPFeature -AllExistingFeatures -ErrorAction Stop }
    catch { Write-Log "Install-SPFeature warning: $_" -Level WARN }

    # Central Administration – only create if not already running
    $caWebApp = Get-SPWebApplication -IncludeCentralAdministration -ErrorAction SilentlyContinue |
        Where-Object { $_.IsAdministrationWebApplication }
    if ($caWebApp) {
        Write-Log "Central Administration already exists at $($caWebApp.Url) – skipping"
    }
    else {
        Write-Log "Creating Central Administration on port 9999..."
        try {
            New-SPCentralAdministration -Port 9999 -WindowsAuthProvider "NTLM" -ErrorAction Stop
            Write-Log "Central Administration created"
        }
        catch {
            Write-Log "New-SPCentralAdministration error: $_" -Level ERROR
            throw
        }
    }

    Write-Log "Installing application content..."
    try { Install-SPApplicationContent -ErrorAction Stop }
    catch { Write-Log "Install-SPApplicationContent warning: $_" -Level WARN }

    # ------------------------------------------------------------------
    # 3. Create managed accounts
    #    Only create each account if it is not already registered.
    # ------------------------------------------------------------------
    $managedAccounts = @("sp_services", "sp_webapp", "sp_search", "sp_content", "sp_cache", "sp_apps")

    foreach ($acctName in $managedAccounts) {
        $fqName = "$domainPrefix\$acctName"
        $existing = Get-SPManagedAccount -Identity $fqName -ErrorAction SilentlyContinue

        if ($existing) {
            Write-Log "Managed account '$fqName' already registered – skipping"
            continue
        }

        Write-Log "Registering managed account '$fqName'..."
        try {
            $cred = New-Object System.Management.Automation.PSCredential(
                $fqName,
                (ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force)
            )
            New-SPManagedAccount -Credential $cred -ErrorAction Stop | Out-Null
            Write-Log "Managed account '$fqName' registered"
        }
        catch {
            Write-Log "Failed to register managed account '$fqName': $_" -Level ERROR
            throw
        }
    }

    # ------------------------------------------------------------------
    # 4. Start service instances
    #    Wait for each service to reach "Online" status.
    # ------------------------------------------------------------------
    $serviceTypesToStart = @(
        "SharePoint Server Search",
        "Managed Metadata Web Service",
        "User Profile Service",
        "App Management Service"
    )

    foreach ($typeName in $serviceTypesToStart) {
        $svc = Get-SPServiceInstance -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue |
            Where-Object { $_.TypeName -eq $typeName }

        if (-not $svc) {
            Write-Log "Service instance '$typeName' not found on this server" -Level WARN
            continue
        }

        if ($svc.Status -eq "Online") {
            Write-Log "Service '$typeName' is already Online – skipping"
            continue
        }

        Write-Log "Starting service instance '$typeName'..."
        try {
            Start-SPServiceInstance $svc -ErrorAction Stop | Out-Null
        }
        catch {
            # Start-SPServiceInstance can throw timeout for long-starting
            # services (e.g., Search).  The service may still be provisioning
            # in the background — log the error and fall through to the
            # polling loop which will wait for it to come online.
            Write-Log "Start-SPServiceInstance '$typeName' threw: $_ — will poll for status" -Level WARN
        }

        # Poll until the service is online (max ~5 min, 20 min for Search)
        $maxWaitSeconds = if ($typeName -like '*Search*') { 1200 } else { 300 }
        $maxWaitSeconds = [int]$maxWaitSeconds
        $elapsed = 0
        $pollInterval = 15

        while ($elapsed -lt $maxWaitSeconds) {
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            # Re-fetch status
            $svc = Get-SPServiceInstance -Server $env:COMPUTERNAME |
                Where-Object { $_.TypeName -eq $typeName }

            if ($svc.Status -eq "Online") {
                Write-Log "Service '$typeName' is now Online (waited ${elapsed}s)"
                break
            }

            Write-Log "Service '$typeName' status: $($svc.Status) – waiting... (${elapsed}s / ${maxWaitSeconds}s)" -Level DEBUG
        }

        if ($svc.Status -ne "Online") {
            Write-Log "Service '$typeName' did not come Online within ${maxWaitSeconds}s (status: $($svc.Status))" -Level WARN
        }
    }

    # ------------------------------------------------------------------
    # 5. Search Service Application
    #    Guard against re-creation if the app already exists.
    # ------------------------------------------------------------------
    $searchAppName = "Search Service Application"
    $existingSearchApp = Get-SPEnterpriseSearchServiceApplication -Identity $searchAppName -ErrorAction SilentlyContinue

    if ($existingSearchApp) {
        Write-Log "Search Service Application '$searchAppName' already exists – skipping creation"
    }
    else {
        Write-Log "Creating Search Service Application..."

        $searchPoolAccount = "$domainPrefix\sp_search"
        $searchAppPool = Get-SPServiceApplicationPool -Identity "SearchServiceAppPool" -ErrorAction SilentlyContinue
        if (-not $searchAppPool) {
            $searchAppPool = New-SPServiceApplicationPool -Name "SearchServiceAppPool" `
                -Account $searchPoolAccount -ErrorAction Stop
            Write-Log "Created application pool 'SearchServiceAppPool'"
        }

        $searchApp = New-SPEnterpriseSearchServiceApplication -Name $searchAppName `
            -DatabaseName "SP_Search_AdminDB" `
            -ApplicationPool $searchAppPool `
            -ErrorAction Stop

        New-SPEnterpriseSearchServiceApplicationProxy -Name "$searchAppName Proxy" `
            -SearchApplication $searchApp `
            -ErrorAction Stop | Out-Null

        Write-Log "Search Service Application created – configuring topology..."

        # --- Search topology for single-server farm ---
        $searchInstance = Get-SPEnterpriseSearchServiceInstance -Local

        # Ensure the search service instance is online before topology setup
        if ($searchInstance.Status -ne "Online") {
            Write-Log "Starting local search service instance..."
            Start-SPEnterpriseSearchServiceInstance -Identity $searchInstance -ErrorAction Stop

            $maxWait = 300; $waited = 0
            while ($waited -lt $maxWait -and $searchInstance.Status -ne "Online") {
                Start-Sleep -Seconds 15
                $waited += 15
                $searchInstance = Get-SPEnterpriseSearchServiceInstance -Local
                Write-Log "Search service instance status: $($searchInstance.Status) (${waited}s)" -Level DEBUG
            }
        }

        $topology = $searchApp | New-SPEnterpriseSearchTopology

        New-SPEnterpriseSearchAdminComponent `
            -SearchTopology $topology -SearchServiceInstance $searchInstance | Out-Null
        New-SPEnterpriseSearchContentProcessingComponent `
            -SearchTopology $topology -SearchServiceInstance $searchInstance | Out-Null
        New-SPEnterpriseSearchAnalyticsProcessingComponent `
            -SearchTopology $topology -SearchServiceInstance $searchInstance | Out-Null
        New-SPEnterpriseSearchCrawlComponent `
            -SearchTopology $topology -SearchServiceInstance $searchInstance | Out-Null

        # Use a dedicated index location on the data drive
        $indexLocation = "F:\SPSearchIndex"
        if (-not (Test-Path $indexLocation)) {
            New-Item -ItemType Directory -Path $indexLocation -Force | Out-Null
        }
        New-SPEnterpriseSearchIndexComponent `
            -SearchTopology $topology -SearchServiceInstance $searchInstance `
            -IndexLocation $indexLocation | Out-Null
        New-SPEnterpriseSearchQueryProcessingComponent `
            -SearchTopology $topology -SearchServiceInstance $searchInstance | Out-Null

        $topology | Set-SPEnterpriseSearchTopology
        Write-Log "Search topology activated"
    }

    # ------------------------------------------------------------------
    # 6. Managed Metadata Service Application
    # ------------------------------------------------------------------
    $mmsAppName = "Managed Metadata Service"
    $existingMms = Get-SPServiceApplication | Where-Object { $_.Name -eq $mmsAppName }

    if ($existingMms) {
        Write-Log "Managed Metadata Service '$mmsAppName' already exists – skipping creation"
    }
    else {
        Write-Log "Creating Managed Metadata Service Application..."

        $mmsPoolAccount = "$domainPrefix\sp_services"
        $mmsAppPool = Get-SPServiceApplicationPool -Identity "MMSServiceAppPool" -ErrorAction SilentlyContinue
        if (-not $mmsAppPool) {
            $mmsAppPool = New-SPServiceApplicationPool -Name "MMSServiceAppPool" `
                -Account $mmsPoolAccount -ErrorAction Stop
            Write-Log "Created application pool 'MMSServiceAppPool'"
        }

        $mmsApp = New-SPMetadataServiceApplication -Name $mmsAppName `
            -DatabaseName "SP_ManagedMetadata" `
            -ApplicationPool $mmsAppPool `
            -SyndicationErrorReportEnabled `
            -ErrorAction Stop

        New-SPMetadataServiceApplicationProxy -Name "$mmsAppName Proxy" `
            -ServiceApplication $mmsApp `
            -DefaultProxyGroup `
            -ContentTypePushdownEnabled `
            -DefaultKeywordTaxonomy `
            -DefaultSiteCollectionTaxonomy `
            -ErrorAction Stop | Out-Null

        Write-Log "Managed Metadata Service Application created"
    }

    # ------------------------------------------------------------------
    # 7. User Profile Service Application
    # ------------------------------------------------------------------
    $upaAppName = "User Profile Service Application"
    $existingUpa = Get-SPServiceApplication | Where-Object { $_.Name -eq $upaAppName }

    if ($existingUpa) {
        Write-Log "User Profile Service '$upaAppName' already exists – skipping creation"
    }
    else {
        Write-Log "Creating User Profile Service Application..."

        $upaPoolAccount = "$domainPrefix\sp_content"
        $upaAppPool = Get-SPServiceApplicationPool -Identity "UPAServiceAppPool" -ErrorAction SilentlyContinue
        if (-not $upaAppPool) {
            $upaAppPool = New-SPServiceApplicationPool -Name "UPAServiceAppPool" `
                -Account $upaPoolAccount -ErrorAction Stop
            Write-Log "Created application pool 'UPAServiceAppPool'"
        }

        $upaApp = New-SPProfileServiceApplication -Name $upaAppName `
            -ApplicationPool $upaAppPool `
            -ProfileDBName "SP_UserProfile" `
            -SocialDBName "SP_UserProfile_Social" `
            -ProfileSyncDBName "SP_UserProfile_Sync" `
            -ErrorAction Stop

        New-SPProfileServiceApplicationProxy -Name "$upaAppName Proxy" `
            -ServiceApplication $upaApp `
            -DefaultProxyGroup `
            -ErrorAction Stop | Out-Null

        Write-Log "User Profile Service Application created"
    }

    # ------------------------------------------------------------------
    # 8. Subscription Settings Service Application
    #    Must be provisioned before App Management Service.
    # ------------------------------------------------------------------
    $subsAppName = "Microsoft SharePoint Foundation Subscription Settings Service Application"
    $existingSubs = Get-SPServiceApplication | Where-Object { $_.Name -eq $subsAppName }

    if ($existingSubs) {
        Write-Log "Subscription Settings Service '$subsAppName' already exists – skipping creation"
    }
    else {
        Write-Log "Creating Subscription Settings Service Application..."

        $appMgmtPoolAccount = "$domainPrefix\sp_apps"
        $appMgmtAppPool = Get-SPServiceApplicationPool -Identity "AppMgmtServiceAppPool" -ErrorAction SilentlyContinue
        if (-not $appMgmtAppPool) {
            $appMgmtAppPool = New-SPServiceApplicationPool -Name "AppMgmtServiceAppPool" `
                -Account $appMgmtPoolAccount -ErrorAction Stop
            Write-Log "Created application pool 'AppMgmtServiceAppPool'"
        }

        $subsApp = New-SPSubscriptionSettingsServiceApplication `
            -ApplicationPool $appMgmtAppPool `
            -Name $subsAppName `
            -DatabaseName "SP_SubscriptionSettings" `
            -ErrorAction Stop

        New-SPSubscriptionSettingsServiceApplicationProxy `
            -ServiceApplication $subsApp `
            -ErrorAction Stop | Out-Null

        Write-Log "Subscription Settings Service Application created"
    }

    # ------------------------------------------------------------------
    # 9. App Management Service Application
    # ------------------------------------------------------------------
    $appMgmtAppName = "App Management Service"
    $existingAppMgmt = Get-SPServiceApplication | Where-Object { $_.Name -eq $appMgmtAppName }

    if ($existingAppMgmt) {
        Write-Log "App Management Service '$appMgmtAppName' already exists – skipping creation"
    }
    else {
        Write-Log "Creating App Management Service Application..."

        # Reuse the same app pool created for Subscription Settings
        $appMgmtAppPool = Get-SPServiceApplicationPool -Identity "AppMgmtServiceAppPool" -ErrorAction SilentlyContinue
        if (-not $appMgmtAppPool) {
            $appMgmtPoolAccount = "$domainPrefix\sp_apps"
            $appMgmtAppPool = New-SPServiceApplicationPool -Name "AppMgmtServiceAppPool" `
                -Account $appMgmtPoolAccount -ErrorAction Stop
            Write-Log "Created application pool 'AppMgmtServiceAppPool'"
        }

        $appMgmtApp = New-SPAppManagementServiceApplication `
            -ApplicationPool $appMgmtAppPool `
            -Name $appMgmtAppName `
            -DatabaseName "SP_AppManagement" `
            -ErrorAction Stop

        New-SPAppManagementServiceApplicationProxy `
            -ServiceApplication $appMgmtApp `
            -Name "$appMgmtAppName Proxy" `
            -ErrorAction Stop | Out-Null

        Write-Log "App Management Service Application created"
    }

    # ------------------------------------------------------------------
    # 10. Distributed Cache – switch to dedicated managed account
    #     By default AppFabric runs as the farm account; best practice is
    #     a dedicated account so cache restarts don't require farm creds.
    # ------------------------------------------------------------------
    try {
        $cacheAccount = "$domainPrefix\sp_cache"
        $cacheManagedAcct = Get-SPManagedAccount -Identity $cacheAccount -ErrorAction Stop
        $cacheInstance = Get-SPServiceInstance -Server $env:COMPUTERNAME |
            Where-Object { $_.TypeName -eq "Distributed Cache" }

        if ($cacheInstance -and $cacheInstance.Status -eq "Online") {
            $currentAcct = (Get-SPServiceInstance -Server $env:COMPUTERNAME |
                Where-Object { $_.TypeName -eq "Distributed Cache" }).Service.ProcessIdentity.Username

            if ($currentAcct -eq $cacheAccount) {
                Write-Log "Distributed Cache already running as '$cacheAccount' – skipping"
            }
            else {
                Write-Log "Switching Distributed Cache from '$currentAcct' to '$cacheAccount'..."
                $cacheInstance.Service.ProcessIdentity.CurrentIdentityType = "SpecificUser"
                $cacheInstance.Service.ProcessIdentity.ManagedAccount = $cacheManagedAcct
                $cacheInstance.Service.ProcessIdentity.Update()
                $cacheInstance.Service.ProcessIdentity.Deploy()
                Write-Log "Distributed Cache now running as '$cacheAccount'"
            }
        }
        else {
            Write-Log "Distributed Cache service instance not found or not Online – skipping account switch" -Level WARN
        }
    }
    catch {
        Write-Log "Failed to switch Distributed Cache account: $_" -Level WARN
    }

    Write-Log "===== Phase 10: Configure SharePoint Farm – COMPLETE ====="
    return "success"
}
