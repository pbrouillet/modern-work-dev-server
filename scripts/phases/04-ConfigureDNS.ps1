function Invoke-Phase04-ConfigureDNS {
    <#
    .SYNOPSIS
        Configures DNS forwarders and creates A records after DC promotion.
    .DESCRIPTION
        Sets Azure internal DNS and Google DNS as forwarders, creates a DNS A record
        for the SharePoint portal (portal.<domain> -> 127.0.0.1), and verifies resolution.
    #>

    Write-Log "Phase 04 - ConfigureDNS: Starting DNS configuration"

    # ── 1. Wait for DNS service to be running ───────────────────────────────
    try {
        Write-Log "Waiting for DNS service to become available"
        Invoke-WithRetry -ScriptBlock {
            $dnsService = Get-Service -Name DNS -ErrorAction Stop
            if ($dnsService.Status -ne 'Running') {
                throw "DNS service is in state '$($dnsService.Status)', waiting for 'Running'"
            }
            Write-Log "DNS service is running"
        } -OperationName "DNS service availability"
    }
    catch {
        Write-Log "ERROR waiting for DNS service: $_" -Level Error
        throw
    }

    # ── 2. Set DNS forwarders ───────────────────────────────────────────────
    # 168.63.129.16 = Azure's internal DNS resolver (required for Azure VM name resolution)
    # 8.8.8.8       = Google Public DNS (fallback)
    try {
        $forwarders = @("168.63.129.16", "8.8.8.8")

        $currentForwarders = (Get-DnsServerForwarder -ErrorAction SilentlyContinue).IPAddress.IPAddressToString
        $forwardersMatch = $true
        foreach ($fwd in $forwarders) {
            if ($currentForwarders -notcontains $fwd) {
                $forwardersMatch = $false
                break
            }
        }

        if ($forwardersMatch -and $currentForwarders) {
            Write-Log "DNS forwarders already configured: $($currentForwarders -join ', ')"
        }
        else {
            Write-Log "Setting DNS forwarders: $($forwarders -join ', ')"
            Set-DnsServerForwarder -IPAddress $forwarders -PassThru -ErrorAction Stop | Out-Null
            Write-Log "DNS forwarders configured successfully"
        }
    }
    catch {
        Write-Log "ERROR configuring DNS forwarders: $_" -Level Error
        throw
    }

    # ── 3. Add DNS A record for SharePoint portal ──────────────────────────
    try {
        $zoneName = $script:Params.DomainName
        $hostName = "portal"
        $ipAddress = "127.0.0.1"
        $fqdn = "${hostName}.${zoneName}"

        $existingRecord = Get-DnsServerResourceRecord -ZoneName $zoneName `
                                                       -Name $hostName `
                                                       -RRType A `
                                                       -ErrorAction SilentlyContinue

        if ($existingRecord) {
            Write-Log "DNS A record already exists: $fqdn -> $($existingRecord.RecordData.IPv4Address)"
        }
        else {
            Write-Log "Creating DNS A record: $fqdn -> $ipAddress"
            Add-DnsServerResourceRecordA -ZoneName $zoneName `
                                          -Name $hostName `
                                          -IPv4Address $ipAddress `
                                          -ErrorAction Stop
            Write-Log "DNS A record created successfully"
        }
    }
    catch {
        Write-Log "ERROR creating DNS A record: $_" -Level Error
        throw
    }

    # ── 4. Verify DNS resolution ────────────────────────────────────────────
    try {
        Write-Log "Verifying DNS resolution for $($script:Params.DomainName)"
        Invoke-WithRetry -ScriptBlock {
            $result = Resolve-DnsName -Name $script:Params.DomainName -ErrorAction Stop
            if (-not $result) {
                throw "Resolve-DnsName returned no results"
            }
            Write-Log "DNS resolution verified: $($result[0].Name) -> $($result[0].IPAddress)"
        } -OperationName "DNS resolution verification"
    }
    catch {
        Write-Log "ERROR verifying DNS resolution: $_" -Level Error
        throw
    }

    Write-Log "Phase 04 - ConfigureDNS: Completed successfully"
    return "success"
}
