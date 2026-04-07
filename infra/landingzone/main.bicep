targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Layer: networking
// Creates VNet, NSG, Public IP, ACR, Log Analytics, App Insights, and the
// Container Apps Environment.  CAE VNet infrastructure takes 15-20 min to
// warm up on first deploy — running it in this early layer avoids ARM
// timeout issues in the compute layer.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Environment name used for naming convention.')
param environmentName string

@description('Source IP CIDR allowed for RDP (port 3389).')
param rdpSourceAddressPrefix string = '*'

@description('Tags to apply to all resources.')
param tags object = {
  project: 'MW-SharePoint-SE'
  environment: environmentName
}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var vmName = 'vm-spse-${environmentName}'
var vnetName = 'vnet-spse-${environmentName}'
var nsgName = 'nsg-spse-${environmentName}'
var publicIpName = 'pip-spse-${environmentName}'

// ACR names must be globally unique, alphanumeric, 5-50 chars
var acrName = 'acrspse${uniqueString(resourceGroup().id, environmentName)}'
var caeName = 'cae-spse-${environmentName}'
var lawName = 'law-spse-${environmentName}'
var appInsightsName = 'appi-spse-${environmentName}'

// ---------------------------------------------------------------------------
// Module: Network (VNet, NSG, Public IP)
// ---------------------------------------------------------------------------

module network '../compute/modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    vnetName: vnetName
    nsgName: nsgName
    publicIpName: publicIpName
    domainNameLabel: vmName
    rdpSourceAddressPrefix: rdpSourceAddressPrefix
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Azure Container Registry
// ---------------------------------------------------------------------------

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// ---------------------------------------------------------------------------

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Application Insights
// ---------------------------------------------------------------------------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

// ---------------------------------------------------------------------------
// Container Apps Environment (VNet-integrated — slow to provision)
// ---------------------------------------------------------------------------

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: caeName
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      internal: false
      infrastructureSubnetId: network.outputs.containerAppsSubnetId
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        workloadProfileType: 'Consumption'
        name: 'Consumption'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs — consumed by compute layer via azd env
// ---------------------------------------------------------------------------

// Network outputs
@description('Resource ID of the VM subnet.')
output subnetId string = network.outputs.subnetId

@description('Resource ID of the public IP address.')
output publicIpId string = network.outputs.publicIpId

@description('Resource ID of the network security group.')
output nsgId string = network.outputs.nsgId

@description('Fully qualified domain name of the public IP.')
output fqdn string = network.outputs.fqdn

@description('Resource ID of the Container Apps subnet.')
output containerAppsSubnetId string = network.outputs.containerAppsSubnetId

// ACR outputs
@description('ACR login server URL.')
output acrLoginServer string = acr.properties.loginServer

@description('ACR resource name.')
output acrName string = acr.name

// CAE outputs
@description('Container Apps Environment resource ID.')
output caeId string = cae.id

// Observability outputs
@description('Application Insights connection string.')
output appInsightsConnectionString string = appInsights.properties.ConnectionString

@description('Application Insights resource name.')
output appInsightsName string = appInsights.name

// Naming outputs needed by compute layer
@description('VNet name.')
output vnetName string = vnetName

@description('Public IP resource name.')
output publicIpName string = publicIpName

@description('Azure Container Registry login server (azd convention).')
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer

// CAE name for CLI-based Container App creation
@description('Container Apps Environment name.')
output caeName string = caeName
