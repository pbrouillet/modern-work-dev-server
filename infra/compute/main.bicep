targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Layer: compute
// Creates VM and RBAC.  Landing-zone infrastructure (VNet, ACR, CAE, LAW,
// App Insights, Container App) is created by the landingzone layer.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Environment name used for naming convention.')
param environmentName string

@description('Size of the virtual machine.')
param vmSize string = 'Standard_D8ds_v5'

@description('Administrator username for the VM.')
param adminUsername string = 'spadmin'

@secure()
@description('Administrator password for the VM.')
param adminPassword string

@secure()
@description('SharePoint farm passphrase.')
param spFarmPassphrase string

@description('Name of the storage account created by the storage layer.')
param storageAccountName string

@description('SQL Server ISO file name in the isos container.')
param sqlIsoFileName string = 'enu_sql_server_2022_enterprise_edition_x64_dvd_aa36de9e.iso'

@description('SharePoint Server ISO file name in the isos container.')
param spIsoFileName string = 'en-us_sharepoint_server_subscription_edition_x64_dvd_43bcf201.iso'

@description('Deploy Exchange Server SE on the VM.')
param enableExchange bool = false

@description('Exchange Server SE ISO file name in the isos container.')
param exchangeIsoFileName string = 'ExchangeServerSE-x64.iso'

// utcNow() can only be used in a parameter default value
@description('Deployment timestamp used for SAS token expiry calculation. Do not supply manually.')
param deploymentTime string = utcNow()

// ---------------------------------------------------------------------------
// Parameters from landingzone layer
// ---------------------------------------------------------------------------

@description('Resource ID of the VM subnet (from landingzone layer).')
param subnetId string

@description('Resource ID of the public IP address (from landingzone layer).')
param publicIpId string

@description('VNet name (from landingzone layer).')
param vnetName string

@description('Public IP resource name (from landingzone layer).')
param publicIpName string

@description('Fully qualified domain name of the public IP (from landingzone layer).')
param fqdn string

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var vmName = 'vm-spse-${environmentName}'
var nicName = 'nic-spse-${environmentName}'

var tags = {
  project: 'MW-SharePoint-SE'
  environment: environmentName
}

// ---------------------------------------------------------------------------
// Storage account (created by the storage layer, updated here to allow the
// compute subnet through the firewall via VNet service-endpoint rule).
// defaultAction is Allow during deployment so the CSE can access blobs.
// The postprovision hook re-secures to Deny once the VNet rule is active.
// NOTE: allowSharedKeyAccess is NOT set — Azure Policy controls it.
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: []
      virtualNetworkRules: [
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'snet-default')
          action: 'Allow'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: Grant the VM's managed identity "Storage Blob Data Contributor"
// so the CSE can use azcopy with managed identity to read/write blobs.
// ---------------------------------------------------------------------------

var storageBlobDataContributorId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource blobDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vmName, storageBlobDataContributorId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorId)
    principalId: vm.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Module: VM
// ---------------------------------------------------------------------------

module vm 'modules/vm.bicep' = {
  name: 'deploy-vm'
  params: {
    location: location
    vmName: vmName
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: subnetId
    publicIpId: publicIpId
    nicName: nicName
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Module: VM Extension
// ---------------------------------------------------------------------------

// Disabled during dev
module vmExtension 'modules/vm-extension.bicep' = {
  name: 'deploy-vmext'
  dependsOn: [blobDataContributorRole]
  params: {
    location: location
    vmName: vm.outputs.vmName
    storageAccountName: storageAccountName
    sqlIsoFileName: sqlIsoFileName
    spIsoFileName: spIsoFileName
    domainAdminPassword: adminPassword
    spFarmPassphrase: spFarmPassphrase
    enableExchange: enableExchange
    exchangeIsoFileName: exchangeIsoFileName
    forceUpdateTag: deploymentTime
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Public IP reference for outputs (created by the landingzone layer)
// ---------------------------------------------------------------------------

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' existing = {
  name: publicIpName
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Public IP address of the VM.')
output vmPublicIpAddress string = publicIp.properties.ipAddress

@description('Fully qualified domain name of the VM.')
output vmFqdn string = fqdn

@description('Name of the virtual machine.')
output vmName string = vm.outputs.vmName

@description('RDP command to connect to the VM.')
output rdpCommand string = 'mstsc /v:${fqdn}'

@description('Setup instructions — RDP into the VM and run the launcher script.')
output setupInstructions string = 'RDP into the VM and run C:\\Installs\\Start-Setup.ps1 as Administrator'

@description('SharePoint Central Administration URL.')
output centralAdminUrl string = 'http://${vm.outputs.vmName}:9999'

@description('SharePoint portal URL (add to local hosts file).')
output portalUrl string = 'http://portal.contoso.com (add ${publicIp.properties.ipAddress} portal.contoso.com to hosts file)'

@description('Exchange Admin Center URL (only when enableExchange is true).')
output exchangeAdminUrl string = enableExchange ? 'https://${vm.outputs.vmName}/ecp' : 'N/A (Exchange not enabled)'

@description('Outlook Web Access URL (only when enableExchange is true).')
output outlookWebUrl string = enableExchange ? 'https://${vm.outputs.vmName}/owa' : 'N/A (Exchange not enabled)'
