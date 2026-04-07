// --------------------------------------------------------------------------
// Network module – provisions NSG, VNet w/ subnet, and Public IP for a
// SharePoint SE dev VM.
// --------------------------------------------------------------------------

@description('Azure region for all networking resources.')
param location string = resourceGroup().location

@description('Name of the virtual network.')
param vnetName string = 'vnet-spse-dev'

@description('Address prefix for the virtual network.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Name of the subnet.')
param subnetName string = 'snet-default'

@description('Address prefix for the subnet.')
param subnetAddressPrefix string = '10.0.1.0/24'

@description('Name of the network security group.')
param nsgName string = 'nsg-spse-dev'

@description('Name of the public IP address.')
param publicIpName string = 'pip-spse-dev'

@description('Source address prefix allowed to connect via RDP (port 3389). Use a specific CIDR to restrict access.')
param rdpSourceAddressPrefix string = '*'

@description('DNS label to assign to the public IP (produces <label>.<region>.cloudapp.azure.com).')
param domainNameLabel string = ''

@description('Tags to apply to all networking resources.')
param tags object = {}

// --------------------------------------------------------------------------
// Network Security Group
// --------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-VNet'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-RDP-Client'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: rdpSourceAddressPrefix
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// Virtual Network with subnet
// --------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'snet-container-apps'
        properties: {
          addressPrefix: '10.0.4.0/23'
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

// --------------------------------------------------------------------------
// Public IP Address
// --------------------------------------------------------------------------
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: !empty(domainNameLabel) ? {
      domainNameLabel: domainNameLabel
    } : null
  }
}

// --------------------------------------------------------------------------
// Outputs
// --------------------------------------------------------------------------
@description('Resource ID of the subnet.')
output subnetId string = vnet.properties.subnets[0].id

@description('Resource ID of the public IP address.')
output publicIpId string = publicIp.id

@description('Resource ID of the network security group.')
output nsgId string = nsg.id

@description('Fully qualified domain name of the public IP (empty when no DNS label is set).')
output fqdn string = !empty(domainNameLabel) ? publicIp.properties.dnsSettings.fqdn : ''

@description('Resource ID of the Container Apps subnet.')
output containerAppsSubnetId string = vnet.properties.subnets[1].id
