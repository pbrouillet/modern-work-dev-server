#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 21 - Seed Active Directory user accounts and Exchange mailboxes.
.DESCRIPTION
    Creates a realistic set of AD user accounts across several departments,
    enables Exchange mailboxes for each, creates a pair of distribution
    groups, and grants the users access to the SharePoint portal site
    collection.

    Designed for dev/lab environments that need populated directories and
    mailboxes for testing search, people picker, address book, mail flow,
    and SharePoint people web parts.

    All accounts share the domain admin password for convenience.
    This phase is fully idempotent - existing objects are skipped.

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase21-SeedAccountsAndMailboxes {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 21: Seed Accounts & Mailboxes - START ====="

    $domainFqdn   = $script:Params.DomainName            # contoso.com
    $domainNB     = $script:Params.DomainNetBIOS          # CONTOSO
    $domainDN     = ($domainFqdn -split '\.' | ForEach-Object { "DC=$_" }) -join ','
    $password     = ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force
    $portalUrl    = "http://portal.$domainFqdn"

    # ------------------------------------------------------------------
    # 1. Load required modules
    # ------------------------------------------------------------------
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Log "Active Directory module loaded"

    # Load Exchange Management Shell
    $exchangeSnapin = "Microsoft.Exchange.Management.PowerShell.SnapIn"
    $exchangeScript = "C:\Program Files\Microsoft\Exchange Server\V15\bin\RemoteExchange.ps1"

    if (-not (Get-PSSnapin -Name $exchangeSnapin -ErrorAction SilentlyContinue)) {
        if (Get-PSSnapin -Name $exchangeSnapin -Registered -ErrorAction SilentlyContinue) {
            Add-PSSnapin $exchangeSnapin -ErrorAction Stop
        }
        elseif (Test-Path $exchangeScript) {
            . $exchangeScript
            Connect-ExchangeServer -auto -ErrorAction Stop
        }
        else {
            throw "Exchange Management Shell not found. Is Exchange installed?"
        }
    }
    Write-Log "Exchange Management Shell loaded"

    # Load SharePoint snap-in
    if (-not (Get-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------------
    # 2. Ensure People OU exists
    # ------------------------------------------------------------------
    $ouName = "People"
    $ouPath = "OU=$ouName,$domainDN"

    $existingOU = Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" `
                                           -SearchBase $domainDN `
                                           -ErrorAction SilentlyContinue
    if ($existingOU) {
        Write-Log "OU '$ouName' already exists"
    }
    else {
        New-ADOrganizationalUnit -Name $ouName `
                                 -Path $domainDN `
                                 -ProtectedFromAccidentalDeletion $false `
                                 -ErrorAction Stop
        Write-Log "Created OU: $ouPath"
    }

    # ------------------------------------------------------------------
    # 3. Define seed users
    # ------------------------------------------------------------------
    $seedUsers = @(
        # -- Executive ------------------------------------------------
        @{ First="Sarah";   Last="Chen";      Title="Chief Executive Officer";         Dept="Executive";     Sam="schen"      }
        @{ First="Marcus";  Last="Williams";   Title="Chief Technology Officer";        Dept="Executive";     Sam="mwilliams"  }
        @{ First="Elena";   Last="Rodriguez";  Title="Chief Financial Officer";         Dept="Executive";     Sam="erodriguez" }

        # -- Engineering ----------------------------------------------
        @{ First="James";   Last="Kowalski";   Title="VP of Engineering";              Dept="Engineering";   Sam="jkowalski"  }
        @{ First="Priya";   Last="Sharma";     Title="Senior Software Engineer";       Dept="Engineering";   Sam="psharma"    }
        @{ First="Derek";   Last="Yamamoto";   Title="Software Engineer";              Dept="Engineering";   Sam="dyamamoto"  }
        @{ First="Lisa";    Last="Andersen";   Title="Software Engineer";              Dept="Engineering";   Sam="landersen"  }
        @{ First="Kevin";   Last="Park";       Title="QA Lead";                        Dept="Engineering";   Sam="kpark"      }
        @{ First="Amara";   Last="Okafor";     Title="DevOps Engineer";                Dept="Engineering";   Sam="aokafor"    }

        # -- IT / Infrastructure --------------------------------------
        @{ First="Tom";     Last="Bradley";    Title="IT Director";                    Dept="IT";            Sam="tbradley"   }
        @{ First="Nina";    Last="Volkov";     Title="Systems Administrator";          Dept="IT";            Sam="nvolkov"    }
        @{ First="Carlos";  Last="Mendez";     Title="Network Engineer";               Dept="IT";            Sam="cmendez"    }
        @{ First="Rachel";  Last="Kim";        Title="Help Desk Analyst";              Dept="IT";            Sam="rkim"       }

        # -- Sales ----------------------------------------------------
        @{ First="Michael"; Last="Torres";     Title="VP of Sales";                    Dept="Sales";         Sam="mtorres"    }
        @{ First="Hannah";  Last="Graves";     Title="Account Executive";              Dept="Sales";         Sam="hgraves"    }
        @{ First="Brandon"; Last="Lee";        Title="Account Executive";              Dept="Sales";         Sam="blee"       }
        @{ First="Olivia";  Last="Murphy";     Title="Sales Development Rep";          Dept="Sales";         Sam="omurphy"    }

        # -- Marketing -----------------------------------------------
        @{ First="Jessica"; Last="Hartman";    Title="Marketing Director";             Dept="Marketing";     Sam="jhartman"   }
        @{ First="David";   Last="Nguyen";     Title="Content Strategist";             Dept="Marketing";     Sam="dnguyen"    }
        @{ First="Sophie";  Last="Lambert";    Title="Graphic Designer";               Dept="Marketing";     Sam="slambert"   }

        # -- Human Resources -----------------------------------------
        @{ First="Angela";  Last="Foster";     Title="HR Director";                    Dept="Human Resources"; Sam="afoster"  }
        @{ First="Ryan";    Last="Mitchell";   Title="Recruiter";                      Dept="Human Resources"; Sam="rmitchell"}

        # -- Finance -------------------------------------------------
        @{ First="Patricia";Last="Quinn";      Title="Controller";                     Dept="Finance";       Sam="pquinn"     }
        @{ First="Daniel";  Last="Reeves";     Title="Financial Analyst";              Dept="Finance";       Sam="dreeves"    }

        # -- Legal ---------------------------------------------------
        @{ First="Robert";  Last="Stanton";    Title="General Counsel";                Dept="Legal";         Sam="rstanton"   }
    )

    Write-Log "Defined $($seedUsers.Count) seed user accounts across departments"

    # ------------------------------------------------------------------
    # 4. Create AD user accounts
    # ------------------------------------------------------------------
    $createdUsers = @()

    foreach ($user in $seedUsers) {
        $sam  = $user.Sam
        $upn  = "$sam@$domainFqdn"
        $name = "$($user.First) $($user.Last)"

        $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "  AD user exists: $sam ($name) - skipping"
            $createdUsers += $sam
            continue
        }

        try {
            New-ADUser -SamAccountName $sam `
                       -UserPrincipalName $upn `
                       -Name $name `
                       -GivenName $user.First `
                       -Surname $user.Last `
                       -DisplayName $name `
                       -Title $user.Title `
                       -Department $user.Dept `
                       -Company "Contoso" `
                       -Office "Building A" `
                       -Path $ouPath `
                       -AccountPassword $password `
                       -PasswordNeverExpires $true `
                       -Enabled $true `
                       -ErrorAction Stop

            Write-Log "  Created AD user: $sam ($name) - $($user.Title), $($user.Dept)"
            $createdUsers += $sam
        }
        catch {
            Write-Log "  FAILED to create $sam : $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Log "AD user provisioning complete: $($createdUsers.Count) / $($seedUsers.Count)"

    # ------------------------------------------------------------------
    # 5. Enable Exchange mailboxes
    # ------------------------------------------------------------------
    Write-Log "Enabling Exchange mailboxes..."
    $mailboxCount = 0

    foreach ($sam in $createdUsers) {
        $existingMbx = Get-Mailbox -Identity $sam -ErrorAction SilentlyContinue
        if ($existingMbx) {
            Write-Log "  Mailbox exists: $sam - skipping"
            $mailboxCount++
            continue
        }

        try {
            Enable-Mailbox -Identity $sam -ErrorAction Stop | Out-Null
            Write-Log "  Enabled mailbox: $sam@$domainFqdn"
            $mailboxCount++
        }
        catch {
            Write-Log "  FAILED to enable mailbox for $sam : $($_.Exception.Message)" -Level WARN
        }
    }

    Write-Log "Mailbox provisioning complete: $mailboxCount / $($createdUsers.Count)"

    # ------------------------------------------------------------------
    # 6. Create distribution groups
    # ------------------------------------------------------------------
    Write-Log "Creating distribution groups..."

    $groups = @(
        @{
            Name    = "All Staff"
            Alias   = "allstaff"
            Members = $createdUsers       # everyone
        }
        @{
            Name    = "Engineering Team"
            Alias   = "engineering"
            Members = $seedUsers | Where-Object { $_.Dept -eq "Engineering" } | ForEach-Object { $_.Sam }
        }
        @{
            Name    = "Sales Team"
            Alias   = "sales"
            Members = $seedUsers | Where-Object { $_.Dept -eq "Sales" } | ForEach-Object { $_.Sam }
        }
        @{
            Name    = "Leadership"
            Alias   = "leadership"
            Members = $seedUsers | Where-Object { $_.Title -match "^(Chief|VP|Director)" } | ForEach-Object { $_.Sam }
        }
        @{
            Name    = "IT Department"
            Alias   = "itdept"
            Members = $seedUsers | Where-Object { $_.Dept -eq "IT" } | ForEach-Object { $_.Sam }
        }
    )

    foreach ($grp in $groups) {
        $existing = Get-DistributionGroup -Identity $grp.Alias -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "  Distribution group exists: $($grp.Name) - skipping"
            continue
        }

        try {
            New-DistributionGroup -Name $grp.Name `
                                  -Alias $grp.Alias `
                                  -OrganizationalUnit $ouPath `
                                  -ManagedBy "spadmin" `
                                  -ErrorAction Stop | Out-Null

            foreach ($member in $grp.Members) {
                Add-DistributionGroupMember -Identity $grp.Alias -Member $member -ErrorAction SilentlyContinue
            }

            Write-Log "  Created group: $($grp.Name) ($($grp.Alias)@$domainFqdn) - $($grp.Members.Count) members"
        }
        catch {
            Write-Log "  FAILED to create group $($grp.Name): $($_.Exception.Message)" -Level WARN
        }
    }

    # ------------------------------------------------------------------
    # 7. Create AD security groups for SharePoint
    # ------------------------------------------------------------------
    Write-Log "Creating SharePoint-ready security groups..."

    $spGroups = @(
        @{ Name = "SP_Portal_Members";      Desc = "SharePoint Portal Members";      Members = $createdUsers }
        @{ Name = "SP_Portal_Owners";        Desc = "SharePoint Portal Owners";        Members = @("spadmin", "schen", "mwilliams", "tbradley") }
    )

    foreach ($sg in $spGroups) {
        $existing = Get-ADGroup -Filter "Name -eq '$($sg.Name)'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "  AD group exists: $($sg.Name) - skipping"
            continue
        }

        try {
            New-ADGroup -Name $sg.Name `
                        -DisplayName $sg.Desc `
                        -GroupScope Global `
                        -GroupCategory Security `
                        -Path $ouPath `
                        -ErrorAction Stop

            foreach ($member in $sg.Members) {
                Add-ADGroupMember -Identity $sg.Name -Members $member -ErrorAction SilentlyContinue
            }

            Write-Log "  Created AD group: $($sg.Name) - $($sg.Members.Count) members"
        }
        catch {
            Write-Log "  FAILED to create AD group $($sg.Name): $($_.Exception.Message)" -Level WARN
        }
    }

    # ------------------------------------------------------------------
    # 8. Grant seed users access to the SharePoint portal
    # ------------------------------------------------------------------
    Write-Log "Granting SharePoint portal access..."

    try {
        $site = Get-SPSite -Identity $portalUrl -ErrorAction Stop
        $web  = $site.RootWeb

        # Add the Members group to the SP site
        $spMembersGroup = "$domainNB\SP_Portal_Members"
        $existingUser   = $web.SiteUsers | Where-Object { $_.LoginName -eq "i:0#.w|$spMembersGroup" -or $_.LoginName -eq $spMembersGroup }

        if (-not $existingUser) {
            $spGroup = $web.AssociatedMemberGroup
            if ($spGroup) {
                $web.EnsureUser($spMembersGroup) | Out-Null
                $spUser = $web.AllUsers | Where-Object { $_.LoginName -match "SP_Portal_Members" }
                if ($spUser) {
                    $spGroup.AddUser($spUser)
                    Write-Log "  Added $spMembersGroup to SP Members group"
                }
            }
            else {
                Write-Log "  No AssociatedMemberGroup on root web - granting via policy instead" -Level WARN
                $webApp = Get-SPWebApplication $portalUrl
                $policy = $webApp.Policies.Add($spMembersGroup, "Seed Users - Portal Members")
                $policy.PolicyRoleBindings.Add(
                    $webApp.PolicyRoles.GetSpecialRole(
                        [Microsoft.SharePoint.Administration.SPPolicyRoleType]::FullRead))
                $webApp.Update()
                Write-Log "  Added $spMembersGroup as FullRead via web app policy"
            }
        }
        else {
            Write-Log "  $spMembersGroup already has portal access - skipping"
        }

        # Add the Owners group
        $spOwnersGroup = "$domainNB\SP_Portal_Owners"
        $existingOwner = $web.SiteUsers | Where-Object { $_.LoginName -match "SP_Portal_Owners" }

        if (-not $existingOwner) {
            $ownerSpGroup = $web.AssociatedOwnerGroup
            if ($ownerSpGroup) {
                $web.EnsureUser($spOwnersGroup) | Out-Null
                $spOwnerUser = $web.AllUsers | Where-Object { $_.LoginName -match "SP_Portal_Owners" }
                if ($spOwnerUser) {
                    $ownerSpGroup.AddUser($spOwnerUser)
                    Write-Log "  Added $spOwnersGroup to SP Owners group"
                }
            }
        }
        else {
            Write-Log "  $spOwnersGroup already has portal access - skipping"
        }

        $web.Dispose()
        $site.Dispose()
    }
    catch {
        Write-Log "  SharePoint portal access configuration warning: $($_.Exception.Message)" -Level WARN
    }

    # ------------------------------------------------------------------
    # 9. Send welcome e-mail (populates mailboxes with initial content)
    # ------------------------------------------------------------------
    Write-Log "Sending welcome messages to populate mailboxes..."

    $senderAddress = "spadmin@$domainFqdn"

    $welcomeSubjects = @(
        @{ To = "allstaff@$domainFqdn";     Subject = "Welcome to Contoso";                     Body = "Welcome to Contoso! Your account and mailbox have been provisioned. You can access the company portal at http://portal.$domainFqdn and Outlook Web Access at https://$($env:COMPUTERNAME).$domainFqdn/owa." }
        @{ To = "engineering@$domainFqdn";   Subject = "Engineering Team - Dev Environment Ready"; Body = "The SharePoint and Exchange development environment is online. SharePoint Central Admin: http://$($env:COMPUTERNAME):22399/`nPortal: http://portal.$domainFqdn`nVisual Studio and SQL Server are installed on the server." }
        @{ To = "leadership@$domainFqdn";    Subject = "Q2 Planning Kickoff";                    Body = "Please review the attached Q2 roadmap before Friday's planning session. We'll cover budget allocation, headcount, and project priorities." }
        @{ To = "sales@$domainFqdn";         Subject = "New CRM Integration Available";          Body = "The new CRM integration is now live. Please log in to the portal to review your updated dashboards and pipeline reports." }
        @{ To = "itdept@$domainFqdn";        Subject = "Infrastructure Maintenance Window";      Body = "Scheduled maintenance this Saturday 2 AM - 6 AM. Exchange and SharePoint services will be briefly unavailable during patching." }
    )

    foreach ($msg in $welcomeSubjects) {
        try {
            Send-MailMessage -From $senderAddress `
                             -To $msg.To `
                             -Subject $msg.Subject `
                             -Body $msg.Body `
                             -SmtpServer "localhost" `
                             -ErrorAction Stop
            Write-Log "  Sent: '$($msg.Subject)' → $($msg.To)"
        }
        catch {
            Write-Log "  Mail send failed ($($msg.To)): $($_.Exception.Message)" -Level WARN
        }
    }

    # ------------------------------------------------------------------
    # 10. Summary
    # ------------------------------------------------------------------
    Write-Log ""
    Write-Log "-- Seed Data Summary ----------------------------------"
    Write-Log "  AD users created/verified : $($createdUsers.Count)"
    Write-Log "  Exchange mailboxes        : $mailboxCount"
    Write-Log "  Distribution groups       : $($groups.Count)"
    Write-Log "  AD security groups        : $($spGroups.Count)"
    Write-Log "  All passwords             : (same as DomainAdminPassword)"
    Write-Log "  Users OU                  : $ouPath"
    Write-Log "------------------------------------------------------"
    Write-Log ""

    Write-Log "===== Phase 21: Seed Accounts & Mailboxes - COMPLETE ====="
    return "success"
}
