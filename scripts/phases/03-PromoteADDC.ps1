function Invoke-Phase03-PromoteADDC {
    <#
    .SYNOPSIS
        Promotes the server to an Active Directory Domain Controller.
    .DESCRIPTION
        Installs AD DS and DNS features, then creates a new AD forest.
        Returns "reboot" so the orchestrator handles the mandatory post-promotion restart.
    #>

    Write-Log "Phase 03 - PromoteADDC: Starting AD DS promotion"

    # ── 1. Install required Windows features ────────────────────────────────
    $requiredFeatures = @('AD-Domain-Services', 'DNS', 'RSAT-AD-Tools', 'RSAT-DNS-Server')

    try {
        foreach ($feature in $requiredFeatures) {
            $featureState = Get-WindowsFeature -Name $feature -ErrorAction Stop

            if ($featureState.Installed) {
                Write-Log "Windows feature already installed: $feature"
            }
            else {
                Write-Log "Installing Windows feature: $feature"
                $result = Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction Stop

                if ($result.Success) {
                    Write-Log "Successfully installed: $feature"
                }
                else {
                    throw "Install-WindowsFeature reported failure for $feature"
                }
            }
        }
    }
    catch {
        Write-Log "ERROR installing Windows features: $_" -Level Error
        throw
    }

    # ── 2. Check if already a domain controller (idempotent re-run) ─────────
    try {
        Import-Module ADDSDeployment -ErrorAction Stop
        Write-Log "ADDSDeployment module imported"
    }
    catch {
        Write-Log "ERROR importing ADDSDeployment module: $_" -Level Error
        throw
    }

    try {
        $adDomain = Get-ADDomain -ErrorAction SilentlyContinue
        if ($adDomain -and $adDomain.DNSRoot -eq $script:Params.DomainName) {
            Write-Log "Server is already a DC for domain $($script:Params.DomainName) — skipping promotion"
            Write-Log "Phase 03 - PromoteADDC: Already promoted, no reboot needed"
            return "success"
        }
    }
    catch {
        # Get-ADDomain fails when not yet a DC — expected on first run
        Write-Log "Server is not yet a domain controller — proceeding with promotion"
    }

    # ── 3. Install AD DS Forest ─────────────────────────────────────────────
    try {
        $safeModePassword = ConvertTo-SecureString $script:Params.DomainAdminPassword -AsPlainText -Force

        Write-Log "Promoting to AD DS forest: $($script:Params.DomainName) (NetBIOS: $($script:Params.DomainNetBIOS))"
        Write-Log "Forest/Domain functional level: WinThreshold (Windows Server 2016)"

        Install-ADDSForest -DomainName $script:Params.DomainName `
                           -DomainNetBIOSName $script:Params.DomainNetBIOS `
                           -ForestMode "WinThreshold" `
                           -DomainMode "WinThreshold" `
                           -InstallDns:$true `
                           -SafeModeAdministratorPassword $safeModePassword `
                           -NoRebootOnCompletion:$true `
                           -Force:$true `
                           -Confirm:$false `
                           -ErrorAction Stop

        Write-Log "AD DS Forest installation completed — reboot required"
    }
    catch {
        Write-Log "ERROR during AD DS Forest installation: $_" -Level Error
        throw
    }

    # Mark phase complete BEFORE requesting reboot — DC promo may auto-reboot
    Write-Log "Phase 03 - PromoteADDC: Completed, requesting reboot"
    return "reboot"
}
