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
    if (-not (Get-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
    }

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

        # Ensure the server role is Custom (not SingleServerFarm) so that
        # custom search topology operations are allowed.
        $localServer = Get-SPServer -Identity $env:COMPUTERNAME -ErrorAction SilentlyContinue
        if ($localServer -and $localServer.Role -ne "Custom") {
            Write-Log "Server role is '$($localServer.Role)' – changing to 'Custom'..."
            Set-SPServer -Identity $env:COMPUTERNAME -Role Custom -ErrorAction Stop
            Write-Log "Server role changed to 'Custom'"
        }
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
                -LocalServerRole "Custom"
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

        # Poll until the service is online (max ~5 min)
        $maxWaitSeconds = 300
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
    #    Set the search service process identity BEFORE starting the
    #    service instance.  Without this the Windows service
    #    "SharePoint Server Search 16" runs as Local Service, which
    #    lacks the permissions needed to complete provisioning.
    # ------------------------------------------------------------------
    $searchAppName = "Search Service Application"
    $searchPoolAccount = "$domainPrefix\sp_search"

    # 5a. Set Search service process identity (idempotent)
    $searchSvc = Get-SPEnterpriseSearchService
    if ($searchSvc.ProcessIdentity -ne $searchPoolAccount) {
        Write-Log "Setting Search service process identity to '$searchPoolAccount'..."
        $searchPassword = ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force
        Set-SPEnterpriseSearchService -Identity $searchSvc `
            -ServiceAccount $searchPoolAccount `
            -ServicePassword $searchPassword `
            -ErrorAction Stop
        Write-Log "Search service process identity set to '$searchPoolAccount'"
    }
    else {
        Write-Log "Search service process identity already set to '$searchPoolAccount' – skipping"
    }

    # 5b. Start Search service instance and wait for Online
    $searchSvcInstance = Get-SPServiceInstance -Server $env:COMPUTERNAME -ErrorAction SilentlyContinue |
        Where-Object { $_.TypeName -eq "SharePoint Server Search" }

    if ($searchSvcInstance -and $searchSvcInstance.Status -ne "Online") {
        Write-Log "Starting service instance 'SharePoint Server Search'..."
        try {
            Start-SPServiceInstance $searchSvcInstance -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log "Start-SPServiceInstance 'SharePoint Server Search' threw: $_ — will poll for status" -Level WARN
        }

        $maxWaitSeconds = 1200
        $elapsed = 0
        $pollInterval = 15

        while ($elapsed -lt $maxWaitSeconds) {
            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            $searchSvcInstance = Get-SPServiceInstance -Server $env:COMPUTERNAME |
                Where-Object { $_.TypeName -eq "SharePoint Server Search" }

            if ($searchSvcInstance.Status -eq "Online") {
                Write-Log "Service 'SharePoint Server Search' is now Online (waited ${elapsed}s)"
                break
            }

            Write-Log "Service 'SharePoint Server Search' status: $($searchSvcInstance.Status) – waiting... (${elapsed}s / ${maxWaitSeconds}s)" -Level DEBUG
        }

        if ($searchSvcInstance.Status -ne "Online") {
            Write-Log "Service 'SharePoint Server Search' did not come Online within ${maxWaitSeconds}s (status: $($searchSvcInstance.Status))" -Level WARN
        }
    }
    elseif ($searchSvcInstance) {
        Write-Log "Service 'SharePoint Server Search' is already Online – skipping"
    }

    # 5c. Create Search Service Application
    $existingSearchApp = Get-SPEnterpriseSearchServiceApplication -Identity $searchAppName -ErrorAction SilentlyContinue

    if ($existingSearchApp) {
        Write-Log "Search Service Application '$searchAppName' already exists – skipping creation"
    }
    else {
        Write-Log "Creating Search Service Application..."
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

    # ------------------------------------------------------------------
    # 11. Re-run Initialize-SPResourceSecurity
    #     After all service applications and managed accounts are
    #     provisioned, re-run this to ensure registry ACLs (e.g. the
    #     farm encryption key under HKLM\...\16.0\Secure\FarmAdmin)
    #     include the search and other service accounts.  Without this,
    #     the search service throws "Requested registry access is not
    #     allowed" when calling SPCredentialManager.GetMasterKey.
    # ------------------------------------------------------------------
    Write-Log "Re-running Initialize-SPResourceSecurity (post service-application provisioning)..."
    try {
        Initialize-SPResourceSecurity -ErrorAction Stop
        Write-Log "Initialize-SPResourceSecurity completed"
    }
    catch {
        Write-Log "Initialize-SPResourceSecurity warning: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 12. Grant search service account explicit registry access
    #     The search service process identity needs read access to the
    #     farm encryption key in the registry.  Initialize-SPResourceSecurity
    #     usually handles this, but on single-server farms it can miss
    #     the search account.  Grant it explicitly as a safety net.
    # ------------------------------------------------------------------
    try {
        $secureKeyPath = "HKLM:\SOFTWARE\Microsoft\Shared Tools\Web Server Extensions\16.0\Secure"
        if (Test-Path $secureKeyPath) {
            $acl = Get-Acl -Path $secureKeyPath
            $searchIdentity = "$domainPrefix\sp_search"
            $existingRule = $acl.Access | Where-Object {
                $_.IdentityReference.Value -eq $searchIdentity
            }
            if (-not $existingRule) {
                Write-Log "Granting '$searchIdentity' read access to farm Secure registry key..."
                $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                    $searchIdentity,
                    [System.Security.AccessControl.RegistryRights]::ReadKey,
                    [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
                $acl.AddAccessRule($rule)
                Set-Acl -Path $secureKeyPath -AclObject $acl
                Write-Log "Registry ACL updated for '$searchIdentity'"
            }
            else {
                Write-Log "Search account already has registry access to Secure key" -Level DEBUG
            }
        }
        else {
            Write-Log "Secure registry key not found at expected path – skipping" -Level WARN
        }
    }
    catch {
        Write-Log "Failed to grant search registry access: $_" -Level WARN
    }

    # ------------------------------------------------------------------
    # 13. Fix SP_Config database permissions for service accounts
    #     Service application pool accounts need the SPDataAccess role in
    #     SP_Config to execute stored procedures like proc_putObjectTVP.
    #     SharePoint normally provisions these automatically, but on
    #     single-server dev farms the auto-grant can fail silently.
    # ------------------------------------------------------------------
    Write-Log "Ensuring SP_Config database permissions for managed accounts..."
    try {
        $sqlcmdPath = $null
        $searchPaths = @(
            "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\*\Tools\Binn\SQLCMD.EXE"
            "C:\Program Files\Microsoft SQL Server\160\Tools\Binn\SQLCMD.EXE"
            "C:\Program Files\Microsoft SQL Server\150\Tools\Binn\SQLCMD.EXE"
        )
        foreach ($pattern in $searchPaths) {
            $found = Get-Item -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $sqlcmdPath = $found.FullName; break }
        }
        if (-not $sqlcmdPath) {
            $sqlcmdPath = (Get-Command sqlcmd.exe -ErrorAction SilentlyContinue).Source
        }

        if ($sqlcmdPath) {
            # Accounts that run service application pools and need SP_Config access
            $spConfigAccounts = @("sp_content", "sp_services", "sp_search", "sp_webapp", "sp_apps", "sp_cache")

            foreach ($acctName in $spConfigAccounts) {
                $fqName = "$domainPrefix\$acctName"
                $sql = @"
USE [SP_Config];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$fqName')
    CREATE USER [$fqName] FOR LOGIN [$fqName];
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'SPDataAccess' AND type = 'R')
    ALTER ROLE [SPDataAccess] ADD MEMBER [$fqName];
"@
                $result = & $sqlcmdPath -S "." -E -b -Q $sql 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "SP_Config permission grant for '$fqName' returned exit code $LASTEXITCODE" -Level WARN
                }
                else {
                    Write-Log "SP_Config permissions ensured for '$fqName'" -Level DEBUG
                }
            }
            Write-Log "SP_Config database permissions verified for all service accounts"
        }
        else {
            Write-Log "sqlcmd.exe not found – skipping SP_Config permission fixup" -Level WARN
        }
    }
    catch {
        Write-Log "Failed to fix SP_Config permissions: $_" -Level WARN
    }

    Write-Log "===== Phase 10: Configure SharePoint Farm – COMPLETE ====="
    return "success"
}
