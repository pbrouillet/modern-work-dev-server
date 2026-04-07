targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the AZD environment, used for tagging and naming.')
param environmentName string

var suffix = uniqueString(resourceGroup().id)
var storageAccountName = 'stspse${suffix}'
var tags = {
  project: 'MW-SPSE'
  environment: environmentName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    // Network ACLs: Start open so the upload-scripts hook can push blobs.
    // The compute layer adds the VNet rule, then postprovision.ps1 sets Deny.
    // IMPORTANT: Do NOT set Deny here — re-deploying this layer alone would
    // wipe the VNet rule added by the compute layer, locking the VM out.
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource scriptsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'scripts'
  properties: {
    publicAccess: 'None'
  }
}

resource isosContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'isos'
  properties: {
    publicAccess: 'None'
  }
}

@description('The deployed storage account name.')
output storageAccountName string = storageAccount.name

@description('The primary blob endpoint URL.')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

@description('The resource group containing the storage account.')
output storageResourceGroup string = resourceGroup().name

@description('Name of the blob container for provisioning scripts.')
output scriptsContainerName string = scriptsContainer.name

@description('Name of the blob container for ISO images.')
output isosContainerName string = isosContainer.name
