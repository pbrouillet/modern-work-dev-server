#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 16 – Post-install Exchange configuration, test mailbox, and desktop shortcuts.
.DESCRIPTION
    Configures Exchange virtual directory URLs, creates an accepted domain for
    the AD domain, creates a test mailbox, and adds desktop shortcuts for the
    Exchange Admin Center (EAC) and Outlook Web Access (OWA).

    Requires Common.ps1 to be dot-sourced first for Write-Log.
    Parameters are read from $script:Params.
#>

function Invoke-Phase16-ConfigureExchange {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Write-Log "===== Phase 16: Configure Exchange – START ====="

    $serverName  = $env:COMPUTERNAME
    $domainFqdn  = $script:Params.DomainName
    $internalUrl = "https://$serverName.$domainFqdn"

    # ------------------------------------------------------------------
    # 1. Load Exchange Management Shell
    # ------------------------------------------------------------------
    $exchangeSnapin = "Microsoft.Exchange.Management.PowerShell.SnapIn"
    $exchangeScript = "C:\Program Files\Microsoft\Exchange Server\V15\bin\RemoteExchange.ps1"

    if (-not (Get-PSSnapin -Name $exchangeSnapin -ErrorAction SilentlyContinue)) {
        if (Get-PSSnapin -Name $exchangeSnapin -Registered -ErrorAction SilentlyContinue) {
            Write-Log "Loading Exchange Management snap-in..."
            Add-PSSnapin $exchangeSnapin -ErrorAction Stop
        }
        elseif (Test-Path $exchangeScript) {
            Write-Log "Loading Exchange Management Shell via RemoteExchange.ps1..."
            . $exchangeScript
            Connect-ExchangeServer -auto -ErrorAction Stop
        }
        else {
            throw "Exchange Management Shell not found. Is Exchange installed?"
        }
    }
    Write-Log "Exchange Management Shell loaded"

    # ------------------------------------------------------------------
    # 2. Configure virtual directory URLs
    # ------------------------------------------------------------------
    Write-Log "Configuring Exchange virtual directory URLs..."

    try {
        # OWA
        Get-OwaVirtualDirectory -Server $serverName -ErrorAction SilentlyContinue |
            Set-OwaVirtualDirectory -InternalUrl "$internalUrl/owa" -ExternalUrl $null -ErrorAction Stop
        Write-Log "OWA virtual directory configured"

        # ECP (Exchange Admin Center)
        Get-EcpVirtualDirectory -Server $serverName -ErrorAction SilentlyContinue |
            Set-EcpVirtualDirectory -InternalUrl "$internalUrl/ecp" -ExternalUrl $null -ErrorAction Stop
        Write-Log "ECP virtual directory configured"

        # EWS
        Get-WebServicesVirtualDirectory -Server $serverName -ErrorAction SilentlyContinue |
            Set-WebServicesVirtualDirectory -InternalUrl "$internalUrl/EWS/Exchange.asmx" -ExternalUrl $null -ErrorAction Stop
        Write-Log "EWS virtual directory configured"

        # ActiveSync
        Get-ActiveSyncVirtualDirectory -Server $serverName -ErrorAction SilentlyContinue |
            Set-ActiveSyncVirtualDirectory -InternalUrl "$internalUrl/Microsoft-Server-ActiveSync" -ExternalUrl $null -ErrorAction Stop
        Write-Log "ActiveSync virtual directory configured"

        # OAB
        Get-OabVirtualDirectory -Server $serverName -ErrorAction SilentlyContinue |
            Set-OabVirtualDirectory -InternalUrl "$internalUrl/OAB" -ExternalUrl $null -ErrorAction Stop
        Write-Log "OAB virtual directory configured"

        # MAPI
        Get-MapiVirtualDirectory -Server $serverName -ErrorAction SilentlyContinue |
            Set-MapiVirtualDirectory -InternalUrl "$internalUrl/mapi" -ExternalUrl $null -ErrorAction Stop
        Write-Log "MAPI virtual directory configured"
    }
    catch {
        Write-Log "WARNING: Failed to configure some virtual directories: $_" -Level Warn
    }

    # ------------------------------------------------------------------
    # 3. Create accepted domain (if not already present)
    # ------------------------------------------------------------------
    Write-Log "Checking accepted domain for $domainFqdn..."
    $existingDomain = Get-AcceptedDomain -ErrorAction SilentlyContinue |
        Where-Object { $_.DomainName -eq $domainFqdn }

    if ($existingDomain) {
        Write-Log "Accepted domain '$domainFqdn' already exists — skipping"
    }
    else {
        try {
            New-AcceptedDomain -Name $domainFqdn -DomainName $domainFqdn -DomainType Authoritative -ErrorAction Stop
            Write-Log "Accepted domain '$domainFqdn' created"
        }
        catch {
            Write-Log "WARNING: Failed to create accepted domain: $_" -Level Warn
        }
    }

    # ------------------------------------------------------------------
    # 4. Create test mailbox
    # ------------------------------------------------------------------
    $testUser    = "testuser"
    $testMailbox = "$testUser@$domainFqdn"

    Write-Log "Checking for test mailbox $testMailbox..."
    $existing = Get-Mailbox -Identity $testUser -ErrorAction SilentlyContinue

    if ($existing) {
        Write-Log "Test mailbox '$testMailbox' already exists — skipping"
    }
    else {
        try {
            $secPassword = ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force
            New-Mailbox -Name "Test User" `
                -Alias $testUser `
                -UserPrincipalName $testMailbox `
                -Password $secPassword `
                -FirstName "Test" `
                -LastName "User" `
                -ErrorAction Stop
            Write-Log "Test mailbox '$testMailbox' created"
        }
        catch {
            Write-Log "WARNING: Failed to create test mailbox: $_" -Level Warn
        }
    }

    # ------------------------------------------------------------------
    # 5. Enable mailbox for domain admin (Administrator)
    # ------------------------------------------------------------------
    $adminMailbox = Get-Mailbox -Identity "Administrator" -ErrorAction SilentlyContinue
    if ($adminMailbox) {
        Write-Log "Administrator mailbox already exists — skipping"
    }
    else {
        try {
            Enable-Mailbox -Identity "Administrator" -ErrorAction Stop
            Write-Log "Administrator mailbox enabled"
        }
        catch {
            Write-Log "WARNING: Failed to enable Administrator mailbox: $_" -Level Warn
        }
    }

    # ------------------------------------------------------------------
    # 6. Create desktop shortcuts for EAC and OWA
    # ------------------------------------------------------------------
    Write-Log "Creating Exchange desktop shortcuts..."

    $desktop = "C:\Users\Public\Desktop"
    if (-not (Test-Path $desktop)) {
        New-Item -ItemType Directory -Path $desktop -Force | Out-Null
    }

    # Exchange Admin Center
    $eacPath = Join-Path $desktop "Exchange Admin Center.url"
    if (-not (Test-Path $eacPath)) {
        try {
            @(
                "[InternetShortcut]"
                "URL=https://localhost/ecp"
            ) | Set-Content -Path $eacPath -Encoding ASCII -Force
            Write-Log "Created URL shortcut: Exchange Admin Center"
        }
        catch {
            Write-Log "Failed to create EAC shortcut: $_" -Level Warn
        }
    }
    else {
        Write-Log "EAC shortcut already exists — skipping" -Level DEBUG
    }

    # Outlook Web Access
    $owaPath = Join-Path $desktop "Outlook Web Access.url"
    if (-not (Test-Path $owaPath)) {
        try {
            @(
                "[InternetShortcut]"
                "URL=https://localhost/owa"
            ) | Set-Content -Path $owaPath -Encoding ASCII -Force
            Write-Log "Created URL shortcut: Outlook Web Access"
        }
        catch {
            Write-Log "Failed to create OWA shortcut: $_" -Level Warn
        }
    }
    else {
        Write-Log "OWA shortcut already exists — skipping" -Level DEBUG
    }

    # ------------------------------------------------------------------
    # 7. Add Exchange URLs to Local Intranet zone
    # ------------------------------------------------------------------
    $zonesRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
    $serverFqdn = "$serverName.$domainFqdn"

    foreach ($host_ in @($serverFqdn, "localhost")) {
        $zonePath = Join-Path $zonesRoot $host_
        try {
            if (-not (Test-Path $zonePath)) {
                New-Item -Path $zonePath -Force | Out-Null
            }
            Set-ItemProperty -Path $zonePath -Name "https" -Value 1 -Type DWord -Force
            Write-Log "Added '$host_' (https) to Local Intranet zone"
        }
        catch {
            Write-Log "Failed to add '$host_' to intranet zone: $_" -Level Warn
        }
    }

    Write-Log "===== Phase 16: Configure Exchange – COMPLETED ====="
    return "success"
}
