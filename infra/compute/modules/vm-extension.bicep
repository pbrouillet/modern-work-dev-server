// ---------------------------------------------------------------------------
// Module: vm-extension.bicep
// Provisions a Custom Script Extension on the VM that downloads setup scripts
// from Azure Blob Storage to C:\Installs using azcopy with the VM's
// managed identity (no storage keys needed).  The user can then start the
// install manually via RDP.
// ---------------------------------------------------------------------------

@description('Azure region for the extension resource.')
param location string

@description('Name of the existing virtual machine to attach the extension to.')
param vmName string

@description('Name of the Azure Storage account that hosts the blob containers.')
param storageAccountName string

@description('File name of the SQL Server ISO in the isos container.')
param sqlIsoFileName string = 'enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso'

@description('File name of the SharePoint Server ISO in the isos container.')
param spIsoFileName string = 'en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso'

@secure()
@description('Password for the domain administrator and service accounts.')
param domainAdminPassword string

@secure()
@description('Passphrase used when creating or joining the SharePoint farm.')
param spFarmPassphrase string

@description('Whether to install Exchange Server SE on the VM.')
param enableExchange bool = false

@description('File name of the Exchange Server SE ISO in the isos container.')
param exchangeIsoFileName string = 'ExchangeServerSE-x64.iso'

@description('Tags to apply to the extension resource.')
param tags object = {}

@description('Force update tag to ensure the extension re-runs on each deployment.')
param forceUpdateTag string = utcNow()

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var storageSuffix = environment().suffixes.storage

// PowerShell provision script.  Uses azcopy with the VM managed identity to
// download scripts from the blob container to C:\Installs.
// The template uses __NAMED_TOKENS__ replaced at deploy time via chained
// replace() calls — the .ps1.tpml file reads as normal PowerShell.
var provisionScript = replace(replace(replace(replace(replace(replace(replace(replace(
  loadTextContent('./extensions-script.ps1.tpml'),
  '__STORAGE_ACCOUNT_NAME__', storageAccountName),
  '__SQL_ISO_FILENAME__',     sqlIsoFileName),
  '__SP_ISO_FILENAME__',      spIsoFileName),
  '__DOMAIN_ADMIN_PASSWORD__', domainAdminPassword),
  '__STORAGE_SUFFIX__',       storageSuffix),
  '__SP_FARM_PASSPHRASE__',   spFarmPassphrase),
  '__ENABLE_EXCHANGE__',      string(enableExchange)),
  '__EXCHANGE_ISO_FILENAME__', exchangeIsoFileName)

// Base64-encode the script so the commandToExecute one-liner is cmd.exe-safe.
// The wrapper decodes it to a temp .ps1 file and executes it.
var scriptB64 = base64(provisionScript)
var q = '\'' // single-quote character — avoids Bicep ''${ parse ambiguity

// ---------------------------------------------------------------------------
// Custom Script Extension
// ---------------------------------------------------------------------------

@description('Custom Script Extension that downloads scripts from Azure Blob Storage via azcopy (managed identity) to C:\\Installs for manual execution via RDP.')
resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  name: '${vmName}/CustomScriptExtension'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    forceUpdateTag: forceUpdateTag
    settings: {}
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Bypass -Command "$f=Join-Path $env:TEMP cse-provision.ps1;[IO.File]::WriteAllText($f,[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(${q}${scriptB64}${q})));& $f"'
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the Custom Script Extension.')
output extensionId string = cse.id
