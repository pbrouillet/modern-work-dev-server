function Invoke-Phase05-CreateServiceAccounts {
    <#
    .SYNOPSIS
        Creates Active Directory service accounts for SQL Server and SharePoint.
    .DESCRIPTION
        Waits for AD DS readiness, creates a ServiceAccounts OU, provisions all
        required service accounts, and adds sp_setup to local Administrators.
    #>

    Write-Log "Phase 05 - CreateServiceAccounts: Starting service account provisioning"

    # ── Helper: Build distinguished-name path from DNS domain name ──────────
    $domainDN = ($script:Params.DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','
    $ouPath = "OU=ServiceAccounts,$domainDN"
    $password = ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force

    # ── 1. Wait for AD DS to be fully operational ───────────────────────────
    try {
        Write-Log "Waiting for AD DS to become fully operational"
        Invoke-WithRetry -ScriptBlock {
            $domain = Get-ADDomain -ErrorAction Stop
            Write-Log "AD DS is operational: $($domain.DNSRoot)"
        } -OperationName "AD DS availability"
    }
    catch {
        Write-Log "ERROR waiting for AD DS: $_" -Level Error
        throw
    }

    # ── 2. Create OU for service accounts ───────────────────────────────────
    try {
        $existingOU = Get-ADOrganizationalUnit -Filter "Name -eq 'ServiceAccounts'" `
                                                -SearchBase $domainDN `
                                                -ErrorAction SilentlyContinue

        if ($existingOU) {
            Write-Log "Organizational Unit already exists: $ouPath"
        }
        else {
            Write-Log "Creating Organizational Unit: $ouPath"
            New-ADOrganizationalUnit -Name "ServiceAccounts" `
                                     -Path $domainDN `
                                     -ProtectedFromAccidentalDeletion $false `
                                     -ErrorAction Stop
            Write-Log "Organizational Unit created successfully"
        }
    }
    catch {
        Write-Log "ERROR creating Organizational Unit: $_" -Level Error
        throw
    }

    # ── 3. Define service accounts ──────────────────────────────────────────
    $accounts = @(
        @{ Name = "sp_setup";     DisplayName = "SP Setup Admin" }
        @{ Name = "sp_farm";      DisplayName = "SP Farm Account" }
        @{ Name = "sp_services";  DisplayName = "SP Service Apps" }
        @{ Name = "sp_webapp";    DisplayName = "SP Web App Pool" }
        @{ Name = "sp_search";    DisplayName = "SP Search Service" }
        @{ Name = "sp_content";   DisplayName = "SP User Profile Service" }
        @{ Name = "sp_cache";     DisplayName = "SP Cache Service" }
        @{ Name = "sp_apps";      DisplayName = "SP App Management" }
        @{ Name = "sp_supuser";   DisplayName = "SP Super User" }
        @{ Name = "sp_supreader"; DisplayName = "SP Super Reader" }
        @{ Name = "sql_svc";      DisplayName = "SQL Server Service" }
        @{ Name = "sql_agent";    DisplayName = "SQL Server Agent" }
    )

    # ── 4. Create each service account ──────────────────────────────────────
    foreach ($acct in $accounts) {
        try {
            $existingUser = Get-ADUser -Filter "SamAccountName -eq '$($acct.Name)'" -ErrorAction SilentlyContinue

            if ($existingUser) {
                Write-Log "Service account already exists: $($acct.Name) ($($acct.DisplayName))"
                continue
            }

            Write-Log "Creating service account: $($acct.Name) ($($acct.DisplayName))"
            New-ADUser -Name $acct.DisplayName `
                       -SamAccountName $acct.Name `
                       -UserPrincipalName "$($acct.Name)@$($script:Params.DomainName)" `
                       -DisplayName $acct.DisplayName `
                       -Path $ouPath `
                       -AccountPassword $password `
                       -PasswordNeverExpires $true `
                       -CannotChangePassword $false `
                       -Enabled $true `
                       -ErrorAction Stop

            Write-Log "Service account created: $($acct.Name)"
        }
        catch {
            Write-Log "ERROR creating service account $($acct.Name): $_" -Level Error
            throw
        }
    }

    # ── 5. Add sp_setup to local Administrators ─────────────────────────────
    # On a domain controller the local SAM is disabled, so Get-LocalGroupMember
    # / Add-LocalGroupMember fail. Use 'net localgroup' which works on both DCs
    # and member servers.
    try {
        $spSetupIdentity = "$($script:Params.DomainNetBIOS)\sp_setup"
        $members = net localgroup Administrators 2>&1 | Out-String

        if ($members -match [regex]::Escape($spSetupIdentity)) {
            Write-Log "sp_setup is already a member of local Administrators"
        }
        else {
            Write-Log "Adding $spSetupIdentity to local Administrators group"
            net localgroup Administrators $spSetupIdentity /add

            if ($LASTEXITCODE -ne 0) { throw "net localgroup /add failed with exit code $LASTEXITCODE" }
            Write-Log "$spSetupIdentity added to local Administrators"
        }
    }
    catch {
        Write-Log "WARNING adding sp_setup to Administrators: $_" -Level Warn
    }

    Write-Log "Phase 05 - CreateServiceAccounts: Completed successfully"
    return "success"
}
